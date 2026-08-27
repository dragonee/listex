defmodule Listex.Snapshot do
  @moduledoc """
  The whole list at one point in time.

  This is what `Listex.snapshot/1` returns and what whole-list subscribers
  (`Listex.subscribe(list, :full)`) receive after every change.
  """

  alias Listex.{ID, Item}

  @enforce_keys [:list_id, :version, :items]
  defstruct [:list_id, :version, :items]

  @type t :: %__MODULE__{
          list_id: ID.t(),
          version: non_neg_integer(),
          items: [Item.t()]
        }

  @doc "The bare contents, in order, without ids or revisions."
  @spec contents(t()) :: [term()]
  def contents(%__MODULE__{items: items}), do: Enum.map(items, & &1.content)
end
