defmodule Listex.Replay do
  @moduledoc """
  Folds an event stream back into a list, the way a `:updates` subscriber has to.

  The whole point of the update-only subscription is that a client can keep an
  accurate copy of the list from events alone, so the tests hold the library to
  it: replay everything a subscriber heard and the result must equal the
  snapshot the process itself is holding.
  """

  alias Listex.{Event, Item, Snapshot}

  @doc "Applies `events` to a starting point, in order, and returns the resulting items."
  @spec replay(Snapshot.t() | [Item.t()], [Event.t()]) :: [Item.t()]
  def replay(%Snapshot{items: items}, events), do: replay(items, events)

  def replay(items, events) when is_list(items) do
    Enum.reduce(events, items, &apply_event/2)
  end

  defp apply_event(%Event{type: :inserted, item: item, after: anchor}, items) do
    insert_after(items, anchor, item)
  end

  defp apply_event(%Event{type: :updated, item: %Item{id: id} = item}, items) do
    Enum.map(items, fn
      %Item{id: ^id} -> item
      other -> other
    end)
  end

  defp apply_event(%Event{type: :moved, id: id, after: anchor}, items) do
    {item, rest} = pop(items, id)
    insert_after(rest, anchor, item)
  end

  defp apply_event(%Event{type: :deleted, id: id}, items) do
    {_item, rest} = pop(items, id)
    rest
  end

  # Ephemeral: carries no state change to replay.
  defp apply_event(%Event{type: :editing}, items), do: items

  defp insert_after(items, :end, item), do: items ++ [item]
  defp insert_after(items, :start, item), do: [item | items]

  defp insert_after(items, anchor_id, item) do
    {before, [anchor | rest]} = Enum.split_while(items, &(&1.id != anchor_id))
    before ++ [anchor, item | rest]
  end

  defp pop(items, id) do
    {before, [item | rest]} = Enum.split_while(items, &(&1.id != id))
    {item, before ++ rest}
  end
end
