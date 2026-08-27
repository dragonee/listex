defmodule Listex.List do
  @moduledoc """
  The process that holds one list.

  Everything interesting about this module follows from one fact: a `GenServer`
  has a mailbox, and a mailbox is a total order. Operations from any number of
  concurrent editors are applied one at a time in the order they arrive, and
  that order *is* the conflict policy — no operational transform, no vector
  clocks, no merge. Two editors updating the same item both succeed; the one
  whose message arrives second is the one you end up looking at.

  You normally reach this through `Listex`, but the process is a plain
  `GenServer` and can be started and supervised on its own.

  ## Options

    * `:id` — the list id; generated when absent.
    * `:contents` — a list of terms (or `Listex.Item` structs when you want to
      choose the ids) to spawn the process from.
    * `:idle_timeout` — milliseconds without a client message before the
      process shuts down. Defaults to 5 minutes. `:infinity` disables it.
    * `:name` — a name to register under, or `false` for an unnamed process.
      Defaults to `Listex.Registry.via(id)`.

  ## Idle shutdown

  Client messages (operations, reads, subscribes) push the deadline back;
  internal traffic such as a subscriber going down does not. On expiry every
  subscriber is sent `{:listex, list_id, {:closed, :idle}}` and the process
  exits `:normal`. State lives in memory only — it goes with the process.
  """

  use GenServer

  alias Listex.{Event, ID, Item, Registry, Snapshot}

  @default_idle_timeout :timer.minutes(5)

  @type mode :: :full | :updates
  @type op ::
          {:insert, term(), keyword()}
          | {:update, ID.t(), term()}
          | {:move, ID.t(), ID.t() | :start | :end}
          | {:delete, ID.t()}

  defstruct [:id, :items, :version, :idle_timeout, :last_active, :subscribers]

  # ---------------------------------------------------------------- lifecycle

  @doc "Starts a list process. See the module docs for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {id, opts} = Keyword.pop_lazy(opts, :id, &ID.new/0)

    case Keyword.get(opts, :name, Registry.via(id)) do
      false -> GenServer.start_link(__MODULE__, {id, opts})
      name -> GenServer.start_link(__MODULE__, {id, opts}, name: name)
    end
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      # In-memory state: a restart would resurrect a list from its initial
      # contents under the same id, which is worse than being gone.
      restart: :temporary
    }
  end

  # ------------------------------------------------------------------ GenServer

  @impl true
  def init({id, opts}) do
    items = opts |> Keyword.get(:contents, []) |> Enum.map(&to_item/1)

    case duplicate_ids(items) do
      [] ->
        state = %__MODULE__{
          id: id,
          items: items,
          version: 0,
          idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout),
          last_active: now(),
          subscribers: %{}
        }

        {:ok, state, timeout(state)}

      dups ->
        {:stop, {:duplicate_ids, dups}}
    end
  end

  @impl true
  def handle_call({:op, op}, _from, state) do
    version = state.version + 1

    case apply_op(op, state, version) do
      {:ok, reply, items, event} ->
        state = %{state | items: items, version: version}
        broadcast(state, event)
        reply(reply, state)

      {:noop, reply} ->
        reply(reply, state)

      {:error, reason} ->
        reply({:error, reason}, state)
    end
  end

  def handle_call({:editing, item_id, data, by}, _from, state) do
    if has_id?(state, item_id) do
      event = event(state, :editing, id: item_id, data: data, by: by)
      broadcast(state, event, except: by)
      reply(:ok, state)
    else
      reply({:error, :not_found}, state)
    end
  end

  def handle_call(:snapshot, _from, state) do
    reply(snapshot(state), state)
  end

  def handle_call({:subscribe, pid, mode}, _from, state) when mode in [:full, :updates] do
    state = do_unsubscribe(state, pid)
    ref = Process.monitor(pid)
    state = %{state | subscribers: Map.put(state.subscribers, pid, {mode, ref})}
    snapshot = snapshot(state)
    if mode == :full, do: send(pid, {:listex, state.id, snapshot})
    reply({:ok, snapshot}, state)
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    reply(:ok, do_unsubscribe(state, pid))
  end

  @impl true
  def handle_cast({:op, op}, state) do
    version = state.version + 1

    case apply_op(op, state, version) do
      {:ok, _reply, items, event} ->
        state = %{state | items: items, version: version}
        broadcast(state, event)
        noreply(state)

      # Nothing to report an error to; the subscriber stream is the feedback.
      _ ->
        noreply(state)
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    # A message may have arrived after the timeout was armed; only stop when
    # the deadline has really passed.
    case timeout(state) do
      0 ->
        Enum.each(state.subscribers, fn {pid, _} ->
          send(pid, {:listex, state.id, {:closed, :idle}})
        end)

        {:stop, :normal, state}

      remaining ->
        {:noreply, state, remaining}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Not client activity: a subscriber dying must not keep the list alive.
    {:noreply, do_unsubscribe(state, pid), timeout(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state, timeout(state)}

  # ------------------------------------------------------------------ operations

  defp apply_op({:insert, content, opts}, state, version) do
    id = Keyword.get_lazy(opts, :id, &ID.new/0)
    anchor = Keyword.get(opts, :after, :end)

    if has_id?(state, id) do
      {:error, :id_taken}
    else
      item = %Item{id: id, content: content}

      case insert_after(state.items, anchor, item) do
        {:ok, items} ->
          event = event(state, :inserted, version: version, item: item, after: anchor)
          {:ok, {:ok, id}, items, event}

        :error ->
          {:error, :anchor_not_found}
      end
    end
  end

  defp apply_op({:update, id, content}, state, version) do
    case Enum.split_while(state.items, &(&1.id != id)) do
      {_before, []} ->
        {:error, :not_found}

      {before, [item | rest]} ->
        item = %{item | content: content, rev: item.rev + 1}
        event = event(state, :updated, version: version, item: item)
        {:ok, {:ok, item}, before ++ [item | rest], event}
    end
  end

  defp apply_op({:move, id, id}, _state, _version) do
    # "After itself" is meaningless, and replaying it as remove-then-insert
    # would strand the anchor. Nothing changed, so nobody is told anything.
    {:noop, :ok}
  end

  defp apply_op({:move, id, anchor}, state, version) do
    case pop_item(state.items, id) do
      {nil, _rest} ->
        {:error, :not_found}

      {item, rest} ->
        case insert_after(rest, anchor, item) do
          {:ok, items} ->
            event = event(state, :moved, version: version, id: id, after: anchor)
            {:ok, :ok, items, event}

          :error ->
            {:error, :anchor_not_found}
        end
    end
  end

  defp apply_op({:delete, id}, state, version) do
    case pop_item(state.items, id) do
      {nil, _rest} ->
        {:error, :not_found}

      {_item, rest} ->
        event = event(state, :deleted, version: version, id: id)
        {:ok, :ok, rest, event}
    end
  end

  defp insert_after(items, :end, item), do: {:ok, items ++ [item]}
  defp insert_after(items, anchor, item) when anchor in [:start, nil], do: {:ok, [item | items]}

  defp insert_after(items, anchor_id, item) do
    case Enum.split_while(items, &(&1.id != anchor_id)) do
      {_before, []} -> :error
      {before, [anchor | rest]} -> {:ok, before ++ [anchor, item | rest]}
    end
  end

  defp pop_item(items, id) do
    case Enum.split_while(items, &(&1.id != id)) do
      {_before, []} -> {nil, items}
      {before, [item | rest]} -> {item, before ++ rest}
    end
  end

  defp has_id?(state, id), do: Enum.any?(state.items, &(&1.id == id))

  # ------------------------------------------------------------------ subscribers

  defp broadcast(state, event, opts \\ []) do
    except = Keyword.get(opts, :except)

    Enum.reduce(state.subscribers, nil, fn
      {^except, _}, snapshot ->
        snapshot

      {pid, {:updates, _ref}}, snapshot ->
        send(pid, {:listex, state.id, event})
        snapshot

      {pid, {:full, _ref}}, snapshot ->
        # An ephemeral signal has no place in a snapshot, so whole-list
        # subscribers get it as an event like everyone else.
        payload = if event.type == :editing, do: event, else: snapshot || snapshot(state)
        send(pid, {:listex, state.id, payload})
        if event.type == :editing, do: snapshot, else: payload
    end)
  end

  defp do_unsubscribe(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {{_mode, ref}, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  # ------------------------------------------------------------------ helpers

  defp snapshot(state) do
    %Snapshot{list_id: state.id, version: state.version, items: state.items}
  end

  defp event(state, type, fields) do
    struct!(%Event{type: type, list_id: state.id, version: state.version}, fields)
  end

  defp to_item(%Item{} = item), do: item
  defp to_item(content), do: Item.new(content)

  defp duplicate_ids(items) do
    items
    |> Enum.frequencies_by(& &1.id)
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp reply(reply, state) do
    state = %{state | last_active: now()}
    {:reply, reply, state, timeout(state)}
  end

  defp noreply(state) do
    state = %{state | last_active: now()}
    {:noreply, state, timeout(state)}
  end

  defp timeout(%__MODULE__{idle_timeout: :infinity}), do: :infinity

  defp timeout(state) do
    max(state.idle_timeout - (now() - state.last_active), 0)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
