defmodule Listex.ListTest do
  use ExUnit.Case, async: true

  import Listex.TestHelpers

  alias Listex.{Event, Item, List, Snapshot}

  describe "start_link/1" do
    test "runs standalone, without the registry" do
      {:ok, pid} = List.start_link(name: false, contents: ["a"])
      on_exit(fn -> Listex.stop(pid) end)

      assert Listex.contents(pid) == ["a"]
      refute Enum.any?(Listex.list_ids(), &(Listex.whereis(&1) == pid))
    end

    test "registers under its id" do
      id = Listex.ID.new()
      {:ok, pid} = List.start_link(id: id, contents: ["a"])
      on_exit(fn -> Listex.stop(pid) end)

      assert Listex.Registry.whereis(id) == pid
      assert Listex.contents(id) == ["a"]
    end

    test "generates a list id when none is given" do
      {:ok, pid} = List.start_link([])
      on_exit(fn -> Listex.stop(pid) end)

      assert %Snapshot{list_id: id} = Listex.snapshot(pid)
      assert is_binary(id)
      assert Listex.Registry.whereis(id) == pid
    end

    test "is a temporary child: a dead list stays dead" do
      assert List.child_spec(id: "x").restart == :temporary
      assert List.child_spec(id: "x").id == "x"
    end
  end

  describe "idle timeout" do
    test "defaults to five minutes" do
      {:ok, pid} = List.start_link(name: false)
      on_exit(fn -> Listex.stop(pid) end)

      assert :sys.get_state(pid).idle_timeout == :timer.minutes(5)
    end

    test "the process exits once it has been left alone" do
      {:ok, pid} = List.start_link(name: false, contents: ["a"], idle_timeout: 150)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "subscribers are told why" do
      list = start_list(["a"], idle_timeout: 150)
      {:ok, _} = Listex.subscribe(list, :updates)

      # The warning goes out before the process exits, so it is still up for an
      # instant after we hear it.
      assert_receive {:listex, ^list, {:closed, :idle}}, 1_000
      assert wait_until(fn -> not Listex.alive?(list) end)
    end

    test "whole-list subscribers are told too" do
      list = start_list(["a"], idle_timeout: 150)
      {:ok, _} = Listex.subscribe(list, :full)
      assert_receive {:listex, ^list, %Snapshot{}}

      assert_receive {:listex, ^list, {:closed, :idle}}, 1_000
    end

    test "operations push the deadline back" do
      {:ok, pid} = List.start_link(name: false, contents: [], idle_timeout: 300)
      ref = Process.monitor(pid)

      for n <- 1..4 do
        Process.sleep(100)
        assert {:ok, _} = Listex.insert(pid, n)
      end

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 0
      assert length(Listex.items(pid)) == 4
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "reads, subscribes and editing signals count as activity too" do
      {:ok, pid} = List.start_link(name: false, contents: ["a"], idle_timeout: 300)
      ref = Process.monitor(pid)
      [a] = Listex.items(pid)

      Process.sleep(200)
      Listex.snapshot(pid)
      Process.sleep(200)
      {:ok, _} = Listex.subscribe(pid, :updates)
      Process.sleep(200)
      :ok = Listex.start_editing(pid, a.id)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 0
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "a subscriber going down does not keep the list alive" do
      {:ok, pid} = List.start_link(name: false, contents: ["a"], idle_timeout: 300)
      list_ref = Process.monitor(pid)

      peer = spawn(fn -> receive(do: (:stop -> :ok)) end)
      {:ok, _} = Listex.subscribe(pid, :updates, by: peer)
      peer_ref = Process.monitor(peer)

      Process.sleep(250)
      send(peer, :stop)
      assert_receive {:DOWN, ^peer_ref, :process, ^peer, :normal}

      # The list was last touched by the subscribe, so it is due at ~300ms, not
      # ~550ms as it would be if the monitor message had counted as activity.
      assert_receive {:DOWN, ^list_ref, :process, ^pid, :normal}, 200
    end

    test ":infinity keeps the list up" do
      {:ok, pid} = List.start_link(name: false, contents: ["a"], idle_timeout: :infinity)
      on_exit(fn -> Listex.stop(pid) end)
      ref = Process.monitor(pid)

      assert :sys.get_state(pid).idle_timeout == :infinity
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      assert Listex.contents(pid) == ["a"]
    end

    test "unrelated messages do not confuse the timer" do
      {:ok, pid} = List.start_link(name: false, contents: ["a"], idle_timeout: 300)
      ref = Process.monitor(pid)

      send(pid, :something_else)
      send(pid, {:tuple, :of, :nonsense})

      assert Listex.contents(pid) == ["a"]
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end

  describe "cast/2" do
    setup do
      list = start_list(["a"])
      [a] = Listex.items(list)
      {:ok, _} = Listex.subscribe(list, :updates)
      %{list: list, a: a.id}
    end

    test "applies operations without a round trip", %{list: list, a: a} do
      :ok = Listex.cast(list, {:insert, "b", id: "b-id"})
      :ok = Listex.cast(list, {:update, "b-id", "B"})
      :ok = Listex.cast(list, {:move, "b-id", :start})
      :ok = Listex.cast(list, {:delete, a})

      # The reply to this call cannot overtake the casts sent before it.
      assert Listex.contents(list) == ["B"]
      assert %Snapshot{version: 4} = Listex.snapshot(list)
    end

    test "accepts an insert without options", %{list: list} do
      :ok = Listex.cast(list, {:insert, "b"})

      assert Listex.contents(list) == ["a", "b"]
    end

    test "tells subscribers just like a call does", %{list: list} do
      :ok = Listex.cast(list, {:insert, "b", id: "b-id"})

      assert_receive {:listex, ^list, %Event{type: :inserted, item: %Item{id: "b-id"}}}
    end

    test "drops rejected operations silently", %{list: list} do
      :ok = Listex.cast(list, {:delete, "nope"})
      :ok = Listex.cast(list, {:update, "nope", "x"})
      :ok = Listex.cast(list, {:insert, "b", after: "nope"})

      assert Listex.alive?(list)
      assert %Snapshot{version: 0} = Listex.snapshot(list)
      refute_receive {:listex, ^list, _}, 50
    end
  end
end
