defmodule Listex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Listex.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Listex.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Listex.RootSupervisor)
  end
end
