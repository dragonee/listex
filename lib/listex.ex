defmodule Listex do
  @moduledoc """
  One process per list, for simple concurrent editing.

  A list is spawned from a plain Elixir list and lives in its own process.
  Editors send it operations; it applies them one at a time, in arrival order,
  and tells subscribers what happened. Items keep the id they were given for as
  long as they exist, so an editor can hold on to an id and refer to it later
  even if the list has been reordered underneath it.

      {:ok, list} = Listex.new(["milk", "eggs"])
      {:ok, _snapshot} = Listex.subscribe(list, :updates)

      {:ok, id} = Listex.insert(list, "bread")
      :ok = Listex.move(list, id, :start)
      {:ok, _item} = Listex.update(list, id, "sourdough")
      :ok = Listex.delete(list, id)

      Listex.contents(list)
      #=> ["milk", "eggs"]

  ## Content

  An item's content is any Elixir term — a string, a map, a struct, a tuple, a
  binary, `nil`. `Listex` never looks inside it, never compares it and never
  serialises it; it only ever hands it back to you. Order and identity are the
  library's business, meaning is yours.

      Listex.new([
        "a string",
        %{"title" => "a map", "done" => false},
        {:whatever, :you, :like}
      ])

  The one term with a second meaning is `Listex.Item` itself: a `%Listex.Item{}`
  in the list you spawn from is taken as an item with an id you have chosen,
  which is how you restore a list without losing the ids it already had. Wrap it
  (in a tuple, say) if you really want one as content.

  ## Conflict policy

  Arrival order wins. There is no operational transform and no merge: whichever
  operation reaches the process second is the one that ends up in the list.
  Two editors renaming the same item both get `{:ok, item}`; the list holds the
  second one's text. An operation naming an item that is already gone gets
  `{:error, :not_found}` — its author lost, and the event stream (or a fresh
  `snapshot/1`) tells them why.

  ## Operations

    * `insert/3` — add content, optionally `after:` a given id
    * `update/3` — replace an item's content
    * `move/3` — put an item after another id (or `:start` / `:end`)
    * `delete/2` — remove an item
    * `start_editing/4` — tell the *other* subscribers someone is editing an
      item. Changes nothing, bumps no version; a hint for the UI, nothing more.

  ## Subscribers

    * `subscribe(list, :full)` — receives `{:listex, list_id, %Listex.Snapshot{}}`
      after every change. Simplest thing to render.
    * `subscribe(list, :updates)` — receives `{:listex, list_id, %Listex.Event{}}`,
      one per change. Consecutive `:version` numbers; a gap means a message was
      missed and the list should be re-read.

  Both kinds receive `%Listex.Event{type: :editing}` (it has no snapshot to
  fold into) and `{:listex, list_id, {:closed, :idle}}` when the process shuts
  down. Subscribers are monitored, so a subscriber that dies is dropped.

  ## Lifetime

  A list process exits after five minutes without a client message
  (configurable with `:idle_timeout`). State is in memory only: when the
  process goes, so does the list. Reopen it from storage with `new/2` or
  `open/2` and the contents you have.
  """

  alias Listex.{ID, Item, List, Registry, Snapshot}

  @type list_ref :: ID.t() | pid() | GenServer.name()
  @type error :: {:error, :not_found | :anchor_not_found | :id_taken | :no_list}

  @call_timeout 5_000

  # ---------------------------------------------------------------- lifecycle

  @doc """
  Spawns a list process from `contents`, a plain list of terms.

  Each term becomes an item with a fresh id, whatever the term is — string,
  map, struct, tuple, `nil`. Pass `Listex.Item` structs instead when you are
  restoring a list and want to keep the ids it already had; duplicate ids are
  refused.

  ## Options

    * `:id` — the list id; generated when absent
    * `:idle_timeout` — ms of inactivity before shutdown (default: 5 minutes,
      `:infinity` to disable)

  Returns the list id, which is what you pass to every other function here.

      {:ok, list} = Listex.new(["a", "b"], idle_timeout: :timer.minutes(30))
  """
  @spec new([term() | Item.t()], keyword()) :: {:ok, ID.t()} | {:error, term()}
  def new(contents \\ [], opts \\ []) when is_list(contents) and is_list(opts) do
    id = Keyword.get_lazy(opts, :id, &ID.new/0)
    opts = opts |> Keyword.put(:id, id) |> Keyword.put(:contents, contents)

    case DynamicSupervisor.start_child(Listex.Supervisor, {List, opts}) do
      {:ok, _pid} -> {:ok, id}
      {:error, {:already_started, _pid}} -> {:error, :already_started}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the pid holding `list_id`, spawning it from `contents` if it has died
  or never existed.

  The natural companion to the idle timeout: an editor coming back after lunch
  reopens the list from storage without caring whether the process outlived it.
  """
  @spec open(ID.t(), [term() | Item.t()], keyword()) :: {:ok, pid()} | {:error, term()}
  def open(list_id, contents \\ [], opts \\ []) when is_binary(list_id) do
    case whereis(list_id) do
      nil ->
        case new(contents, Keyword.put(opts, :id, list_id)) do
          {:ok, ^list_id} -> {:ok, whereis(list_id)}
          # Lost a race with another opener; theirs is just as good.
          {:error, :already_started} -> {:ok, whereis(list_id)}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc "Shuts a list down now, without waiting for the idle timeout."
  @spec stop(list_ref()) :: :ok
  def stop(list) do
    case pid(list) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    # It beat us to it.
    :exit, {:noproc, _} -> :ok
  end

  @doc "The pid holding `list_id`, or `nil`."
  @spec whereis(ID.t()) :: pid() | nil
  defdelegate whereis(list_id), to: Registry

  @doc "Whether a process is currently holding this list."
  @spec alive?(list_ref()) :: boolean()
  def alive?(list), do: pid(list) != nil

  @doc "Ids of every list held in a process on this node."
  @spec list_ids() :: [ID.t()]
  defdelegate list_ids(), to: Registry

  # ---------------------------------------------------------------- operations

  @doc """
  Inserts `content` and returns its stable id.

  ## Options

    * `:after` — `:end` (default), `:start`, or the id to insert behind. An id
      that is no longer there gives `{:error, :anchor_not_found}`.
    * `:id` — use this id instead of a generated one, for a client that
      minted the id itself. `{:error, :id_taken}` if it is already in use.
  """
  @spec insert(list_ref(), term(), keyword()) :: {:ok, ID.t()} | error()
  def insert(list, content, opts \\ []) do
    call(list, {:op, {:insert, content, opts}})
  end

  @doc """
  Replaces the content of `item_id` and returns the updated item.

  The item's `:rev` goes up by one. No compare-and-swap: a caller working from
  a stale copy still wins if it arrives last.
  """
  @spec update(list_ref(), ID.t(), term()) :: {:ok, Item.t()} | error()
  def update(list, item_id, content) do
    call(list, {:op, {:update, item_id, content}})
  end

  @doc """
  Moves `item_id` to sit directly after `anchor`, which may be another item's
  id, `:start` or `:end`.

  Moving an item after itself does nothing and tells nobody.
  """
  @spec move(list_ref(), ID.t(), ID.t() | :start | :end) :: :ok | error()
  def move(list, item_id, anchor) do
    call(list, {:op, {:move, item_id, anchor}})
  end

  @doc "Removes `item_id`. Its id is never reused."
  @spec delete(list_ref(), ID.t()) :: :ok | error()
  def delete(list, item_id) do
    call(list, {:op, {:delete, item_id}})
  end

  @doc """
  Announces that someone has started editing `item_id`.

  A no-op as far as the list is concerned: nothing changes, the version stays
  put, and the announcement is not replayed to anyone who subscribes later. It
  goes to every *other* subscriber — both kinds — as
  `%Listex.Event{type: :editing, id: item_id, data: data, by: pid}`, so a UI can
  show that a row is busy.

  `data` is any term you want to carry along (a user id, a cursor position, a
  `:done` marker of your own devising). Pass `by:` to attribute the signal to a
  pid other than the caller; that pid is the one excluded from the broadcast.
  """
  @spec start_editing(list_ref(), ID.t(), term(), keyword()) :: :ok | error()
  def start_editing(list, item_id, data \\ nil, opts \\ []) do
    by = Keyword.get(opts, :by, self())
    call(list, {:editing, item_id, data, by})
  end

  @doc """
  Sends an operation without waiting for the result.

  Same ordering guarantee, no round trip, no error reporting — a rejected
  operation is dropped silently and the event stream is your feedback. Pass
  `id:` on an insert if you need to know the id up front.

      Listex.cast(list, {:insert, "bread", id: my_id})
      Listex.cast(list, {:update, my_id, "sourdough"})
      Listex.cast(list, {:move, my_id, :start})
      Listex.cast(list, {:delete, my_id})
  """
  @spec cast(
          list_ref(),
          {:insert, term(), keyword()}
          | {:update, ID.t(), term()}
          | {:move, ID.t(), ID.t() | :start | :end}
          | {:delete, ID.t()}
        ) :: :ok
  def cast(list, op) do
    op =
      case op do
        {:insert, content} -> {:insert, content, []}
        other -> other
      end

    GenServer.cast(server(list), {:op, op})
  end

  # ---------------------------------------------------------------- reads

  @doc "The whole list, with its version."
  @spec snapshot(list_ref()) :: Snapshot.t() | error()
  def snapshot(list), do: call(list, :snapshot)

  @doc "The items, in order."
  @spec items(list_ref()) :: [Item.t()] | error()
  def items(list) do
    with %Snapshot{items: items} <- snapshot(list), do: items
  end

  @doc "The contents, in order, without ids."
  @spec contents(list_ref()) :: [term()] | error()
  def contents(list) do
    with %Snapshot{} = snapshot <- snapshot(list), do: Snapshot.contents(snapshot)
  end

  # ---------------------------------------------------------------- subscriptions

  @doc """
  Subscribes a process to a list and returns the current snapshot as a baseline.

  `mode` is `:updates` (default) for one `%Listex.Event{}` per change, or
  `:full` for a `%Listex.Snapshot{}` after every change — a `:full` subscriber
  also gets one immediately, so it can just wait for messages.

  Messages arrive as `{:listex, list_id, payload}`. Subscribing twice replaces
  the previous mode rather than doubling the traffic, and a subscriber that
  dies is dropped automatically.

  Pass `by:` to subscribe a process other than the caller.
  """
  @spec subscribe(list_ref(), List.mode(), keyword()) :: {:ok, Snapshot.t()} | error()
  def subscribe(list, mode \\ :updates, opts \\ []) when mode in [:full, :updates] do
    call(list, {:subscribe, Keyword.get(opts, :by, self()), mode})
  end

  @doc "Stops sending messages to `pid` (the caller by default)."
  @spec unsubscribe(list_ref(), pid()) :: :ok | error()
  def unsubscribe(list, pid \\ self()) when is_pid(pid) do
    call(list, {:unsubscribe, pid})
  end

  # ---------------------------------------------------------------- internals

  defp call(list, message) do
    GenServer.call(server(list), message, @call_timeout)
  catch
    # The list died (idle timeout, or it was never opened). That is an ordinary
    # outcome here, not a reason to take the caller down with it.
    :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :no_list}
  end

  defp server(list_id) when is_binary(list_id), do: Registry.via(list_id)
  defp server(list), do: list

  defp pid(list) when is_binary(list), do: whereis(list)
  defp pid(list) when is_pid(list), do: if(Process.alive?(list), do: list)
  defp pid(list), do: GenServer.whereis(list)
end
