defmodule Listex.Item do
  @moduledoc """
  One element of a list.

  * `:id` — stable for the whole life of the item (see `Listex.ID`).
  * `:content` — any term; `Listex` never looks inside it.
  * `:rev` — bumped on every `:update` of this item. Handy for spotting a
    write that landed after the one you were rendering.
  """

  alias Listex.ID

  @enforce_keys [:id]
  defstruct [:id, :content, rev: 0]

  @type t :: %__MODULE__{id: ID.t(), content: term(), rev: non_neg_integer()}

  @doc "Builds an item, generating an id unless one is given."
  @spec new(term(), ID.t() | nil) :: t()
  def new(content, id \\ nil) do
    %__MODULE__{id: id || ID.new(), content: content}
  end
end
