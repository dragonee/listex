defmodule Listex.TestHelpers do
  @moduledoc "Small helpers shared by the test files."

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Starts a list that shuts down with the test.

  The idle timeout is pushed out of the way unless a test is specifically
  about it.
  """
  def start_list(contents \\ [], opts \\ []) do
    {:ok, list} = Listex.new(contents, Keyword.put_new(opts, :idle_timeout, :timer.seconds(30)))
    on_exit(fn -> Listex.stop(list) end)
    list
  end

  @doc """
  Retries `fun` until it returns a truthy value or the deadline passes.

  For the handful of places where something happens just after the call that
  triggered it returns — registry cleanup, a monitor firing.
  """
  def wait_until(fun, timeout \\ 500)

  def wait_until(fun, timeout) when timeout <= 0, do: fun.()

  def wait_until(fun, timeout) do
    fun.() || (Process.sleep(10) && wait_until(fun, timeout - 10))
  end

  @doc "Drains the mailbox of `{:listex, _, _}` messages received so far."
  def drain_events(acc \\ []) do
    receive do
      {:listex, _list_id, payload} -> drain_events([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
