defmodule Listex.EditingTest do
  use ExUnit.Case, async: true

  import Listex.TestHelpers

  alias Listex.{Event, Snapshot}

  defp start_peer(list, mode) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _snapshot} = Listex.subscribe(list, mode)
        send(test, {:subscribed, self()})
        peer_loop(test)
      end)

    assert_receive {:subscribed, ^pid}
    pid
  end

  defp peer_loop(test) do
    receive do
      {:listex, list_id, payload} ->
        send(test, {:peer, self(), list_id, payload})
        peer_loop(test)
    end
  end

  setup do
    list = start_list(["a", "b"])
    [a, b] = Listex.items(list)
    %{list: list, a: a.id, b: b.id}
  end

  test "tells the other subscribers, whatever kind they are", %{list: list, a: a} do
    updates = start_peer(list, :updates)
    full = start_peer(list, :full)
    assert_receive {:peer, ^full, ^list, %Snapshot{}}

    assert :ok = Listex.start_editing(list, a, %{user: "kim"})

    me = self()

    assert_receive {:peer, ^updates, ^list,
                    %Event{type: :editing, id: ^a, data: %{user: "kim"}, by: ^me}}

    assert_receive {:peer, ^full, ^list,
                    %Event{type: :editing, id: ^a, data: %{user: "kim"}, by: ^me}}
  end

  test "does not echo back to the editor", %{list: list, a: a} do
    {:ok, _} = Listex.subscribe(list, :updates)

    :ok = Listex.start_editing(list, a)

    refute_receive {:listex, ^list, _}, 50
  end

  test "excludes the pid given as :by, not the caller", %{list: list, a: a} do
    {:ok, _} = Listex.subscribe(list, :updates)
    peer = start_peer(list, :updates)

    :ok = Listex.start_editing(list, a, "typing", by: peer)

    assert_receive {:listex, ^list, %Event{type: :editing, id: ^a, data: "typing", by: ^peer}}
    refute_receive {:peer, ^peer, ^list, _}, 50
  end

  test "changes nothing about the list", %{list: list, a: a} do
    before = Listex.snapshot(list)

    :ok = Listex.start_editing(list, a, "typing")

    assert Listex.snapshot(list) == before
    assert %Snapshot{version: 0} = before
  end

  test "reports the version the list is currently at", %{list: list, a: a} do
    peer = start_peer(list, :updates)
    {:ok, _} = Listex.insert(list, "c")
    assert_receive {:peer, ^peer, ^list, %Event{type: :inserted, version: 1}}

    :ok = Listex.start_editing(list, a)

    assert_receive {:peer, ^peer, ^list, %Event{type: :editing, version: 1}}
  end

  test "carries any term as data", %{list: list, a: a} do
    peer = start_peer(list, :updates)

    for data <- [nil, "kim", %{user: 1, cursor: {2, 9}}, [:done], 42] do
      :ok = Listex.start_editing(list, a, data)
      assert_receive {:peer, ^peer, ^list, %Event{type: :editing, data: ^data}}
    end
  end

  test "is not replayed to someone who subscribes later", %{list: list, a: a} do
    peer = start_peer(list, :updates)
    :ok = Listex.start_editing(list, a, "typing")
    assert_receive {:peer, ^peer, ^list, %Event{type: :editing}}

    {:ok, snapshot} = Listex.subscribe(list, :full)

    assert_receive {:listex, ^list, ^snapshot}
    assert %Snapshot{version: 0, items: [_, _]} = snapshot
    refute_receive {:listex, ^list, %Event{}}, 50
  end

  test "fails for an item that is not there", %{list: list} do
    assert {:error, :not_found} = Listex.start_editing(list, "nope")
  end

  test "fails for an item that has just been deleted", %{list: list, a: a} do
    :ok = Listex.delete(list, a)

    assert {:error, :not_found} = Listex.start_editing(list, a, "typing")
  end

  test "does not stop anyone else from editing the same item", %{list: list, a: a} do
    peer = start_peer(list, :updates)

    :ok = Listex.start_editing(list, a, "kim")
    :ok = Listex.start_editing(list, a, "sam", by: peer)

    assert {:ok, _} = Listex.update(list, a, "whoever got here last")
    assert Listex.contents(list) == ["whoever got here last", "b"]
  end
end
