defmodule Listex.Event do
  @moduledoc """
  What a subscriber is told happened, in the order the list process decided it
  happened.

  Every event carries the `:version` of the list. State-changing events
  (`:inserted`, `:updated`, `:moved`, `:deleted`) carry the version *after*
  they were applied, and versions are consecutive: if you receive `7` right
  after `5` you missed one and should re-read the list with
  `Listex.snapshot/1`.

  Fields per type:

  | type        | fields |
  | ----------- | ------ |
  | `:inserted` | `:item`, `:after` (`:start`, `:end` or an anchor id) |
  | `:updated`  | `:item` |
  | `:moved`    | `:id`, `:after` |
  | `:deleted`  | `:id` |
  | `:editing`  | `:id`, `:data`, `:by` — ephemeral, does not bump `:version` |
  """

  alias Listex.{ID, Item}

  @enforce_keys [:type, :list_id, :version]
  defstruct [:type, :list_id, :version, :id, :item, :after, :data, :by]

  @type type :: :inserted | :updated | :moved | :deleted | :editing

  @type t :: %__MODULE__{
          type: type(),
          list_id: ID.t(),
          version: non_neg_integer(),
          id: ID.t() | nil,
          item: Item.t() | nil,
          after: ID.t() | :start | :end | nil,
          data: term(),
          by: pid() | nil
        }
end
