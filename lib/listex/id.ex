defmodule Listex.ID do
  @moduledoc """
  Stable identifiers for list items and lists.

  An id is generated once, at insert time, and never changes again: `:move`,
  `:update` and re-ordering by other clients all leave it alone. That is what
  makes it safe for a client to hold on to an id it saw in an event and refer
  to it in a later operation.
  """

  @type t :: String.t()

  @doc """
  Returns a fresh, URL-safe, 64-bit random id.

  Collisions are not the caller's problem in practice, but `Listex.List`
  rejects an insert with an id that is already taken anyway.
  """
  @spec new() :: t()
  def new do
    8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
