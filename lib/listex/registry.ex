defmodule Listex.Registry do
  @moduledoc """
  Maps a list id to the process holding that list.
  """

  alias Listex.ID

  @doc "The `:via` tuple a list process registers itself under."
  @spec via(ID.t()) :: {:via, module(), {module(), ID.t()}}
  def via(list_id), do: {:via, Registry, {__MODULE__, list_id}}

  @doc "The pid holding `list_id`, or `nil` if no process is running for it."
  @spec whereis(ID.t()) :: pid() | nil
  def whereis(list_id) do
    # A registry entry outlives its process by the moment it takes the registry
    # to handle the DOWN, and callers here ask right after stopping a list.
    case Registry.lookup(__MODULE__, list_id) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc "Ids of every list currently held in a process on this node."
  @spec list_ids() :: [ID.t()]
  def list_ids do
    __MODULE__
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_id, pid} -> Process.alive?(pid) end)
    |> Enum.map(&elem(&1, 0))
  end
end
