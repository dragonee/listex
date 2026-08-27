defmodule Listex.SubscriptionsTest do
  use ExUnit.Case, async: true

  import Listex.TestHelpers

  alias Listex.{Event, Item, Replay, Snapshot}

  # A stand-in for "some other editor": subscribes, and forwards everything it
  # hears back to the test process so we can assert on it.
  defp start_peer(list, mode) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _snapshot} = Listex.subscribe(list, mode)
        send(test, {:subscribed, self()})
        peer_loop(test)
      end)

    ref = Process.monitor(pid)
    assert_receive {:subscribed, ^pid}
    {pid, ref}
  end

  defp peer_loop(test) do
    receive do
      {:listex, list_id, payload} ->
        send(test, {:peer, self(), list_id, payload})
        peer_loop(test)

      :stop ->
        :ok
    end
  end

  describe "subscribe/3" do
    test "returns the current list as a baseline" do
      list = start_list(["a", "b"])

      assert {:ok, %Snapshot{list_id: ^list, version: 0, items: items}} = Listex.subscribe(list)
      assert Enum.map(items, & &1.content) == ["a", "b"]
    end

    test "a full subscriber gets a snapshot immediately" do
      list = start_list(["a"])

      {:ok, _} = Listex.subscribe(list, :full)
      assert_receive {:listex, ^list, %Snapshot{version: 0, items: [%Item{content: "a"}]}}
    end

    test "an update-only subscriber gets nothing until something happens" do
      list = start_list(["a"])

      {:ok, _} = Listex.subscribe(list, :updates)
      refute_receive {:listex, ^list, _}, 50

      {:ok, _} = Listex.insert(list, "b")
      assert_receive {:listex, ^list, %Event{type: :inserted}}
    end

    test "subscribing again replaces the mode instead of doubling the traffic" do
      list = start_list(["a"])
      {:ok, _} = Listex.subscribe(list, :updates)
      {:ok, _} = Listex.subscribe(list, :full)
      # The snapshot sent when switching to :full.
      assert_receive {:listex, ^list, %Snapshot{}}

      {:ok, _} = Listex.insert(list, "b")

      assert_receive {:listex, ^list, %Snapshot{version: 1}}
      refute_receive {:listex, ^list, _}, 50
    end

    test "subscribes another process with :by" do
      list = start_list(["a"])
      {peer, _ref} = start_peer(list, :updates)

      {:ok, _} = Listex.insert(list, "b")

      assert_receive {:peer, ^peer, ^list, %Event{type: :inserted}}
      refute_receive {:listex, ^list, _}, 50
    end
  end

  describe "unsubscribe/2" do
    test "stops the messages" do
      list = start_list(["a"])
      {:ok, _} = Listex.subscribe(list, :updates)

      assert :ok = Listex.unsubscribe(list)
      {:ok, _} = Listex.insert(list, "b")
      refute_receive {:listex, ^list, _}, 50
    end

    test "is fine when never subscribed" do
      list = start_list(["a"])

      assert :ok = Listex.unsubscribe(list)
    end

    test "a subscriber that dies is dropped" do
      list = start_list(["a"])
      {peer, ref} = start_peer(list, :updates)

      send(peer, :stop)
      assert_receive {:DOWN, ^ref, :process, ^peer, :normal}

      # The list neither crashes nor keeps sending to a dead mailbox.
      assert {:ok, _} = Listex.insert(list, "b")
      assert Listex.contents(list) == ["a", "b"]
    end
  end

  describe "update-only subscribers" do
    setup do
      list = start_list(["a"])
      {:ok, snapshot} = Listex.subscribe(list, :updates)
      %{list: list, baseline: snapshot, a: hd(snapshot.items).id}
    end

    test "insert", %{list: list} do
      {:ok, id} = Listex.insert(list, "b")

      assert_receive {:listex, ^list,
                      %Event{
                        type: :inserted,
                        list_id: ^list,
                        version: 1,
                        item: %Item{id: ^id, content: "b", rev: 0},
                        after: :end
                      }}
    end

    test "insert carries the anchor it was placed behind", %{list: list, a: a} do
      {:ok, _} = Listex.insert(list, "b", after: a)

      assert_receive {:listex, ^list, %Event{type: :inserted, after: ^a}}
    end

    test "update", %{list: list, a: a} do
      {:ok, _} = Listex.update(list, a, "A")

      assert_receive {:listex, ^list,
                      %Event{
                        type: :updated,
                        version: 1,
                        item: %Item{id: ^a, content: "A", rev: 1}
                      }}
    end

    test "move", %{list: list, a: a} do
      {:ok, b} = Listex.insert(list, "b")
      assert_receive {:listex, ^list, %Event{type: :inserted}}

      :ok = Listex.move(list, a, b)

      assert_receive {:listex, ^list, %Event{type: :moved, version: 2, id: ^a, after: ^b}}
    end

    test "delete", %{list: list, a: a} do
      :ok = Listex.delete(list, a)

      assert_receive {:listex, ^list, %Event{type: :deleted, version: 1, id: ^a}}
    end

    test "rejected operations produce no event", %{list: list} do
      {:error, :not_found} = Listex.delete(list, "nope")
      {:error, :anchor_not_found} = Listex.insert(list, "b", after: "nope")
      {:error, :not_found} = Listex.update(list, "nope", "x")

      refute_receive {:listex, ^list, _}, 50
    end

    test "a no-op move produces no event", %{list: list, a: a} do
      :ok = Listex.move(list, a, a)

      refute_receive {:listex, ^list, _}, 50
    end

    test "versions arrive consecutively", %{list: list, a: a} do
      {:ok, b} = Listex.insert(list, "b")
      {:ok, _} = Listex.update(list, b, "B")
      :ok = Listex.move(list, b, :start)
      :ok = Listex.delete(list, a)

      versions = drain_events() |> Enum.map(& &1.version)
      assert versions == [1, 2, 3, 4]
    end

    test "replaying the events reproduces the list exactly", %{list: list, baseline: baseline} do
      {:ok, b} = Listex.insert(list, "b")
      {:ok, c} = Listex.insert(list, "c", after: :start)
      {:ok, d} = Listex.insert(list, "d", after: b)
      {:ok, _} = Listex.update(list, b, "B")
      :ok = Listex.move(list, d, :start)
      :ok = Listex.move(list, c, b)
      :ok = Listex.delete(list, b)

      events = drain_events()
      assert Replay.replay(baseline, events) == Listex.items(list)
    end
  end

  describe "whole-list subscribers" do
    setup do
      list = start_list(["a"])
      {:ok, snapshot} = Listex.subscribe(list, :full)
      assert_receive {:listex, ^list, %Snapshot{version: 0}}
      %{list: list, a: hd(snapshot.items).id}
    end

    test "get the whole list after every change", %{list: list, a: a} do
      {:ok, b} = Listex.insert(list, "b")
      assert_receive {:listex, ^list, %Snapshot{version: 1, items: [_, %Item{id: ^b}]}}

      {:ok, _} = Listex.update(list, a, "A")
      assert_receive {:listex, ^list, %Snapshot{version: 2, items: [%Item{content: "A"}, _]}}

      :ok = Listex.move(list, a, :end)
      assert_receive {:listex, ^list, %Snapshot{version: 3, items: [%Item{id: ^b}, _]}}

      :ok = Listex.delete(list, b)
      assert_receive {:listex, ^list, %Snapshot{version: 4, items: [%Item{id: ^a}]}}
    end

    test "the snapshot always matches what the list reports", %{list: list} do
      {:ok, _} = Listex.insert(list, "b")
      {:ok, _} = Listex.insert(list, "c", after: :start)

      snapshots = drain_events()
      assert List.last(snapshots).items == Listex.items(list)
    end

    test "get nothing for a rejected operation", %{list: list} do
      {:error, :not_found} = Listex.delete(list, "nope")

      refute_receive {:listex, ^list, _}, 50
    end
  end

  describe "mixed subscribers" do
    test "each kind gets its own shape of the same change" do
      list = start_list(["a"])
      {peer, _ref} = start_peer(list, :full)
      assert_receive {:peer, ^peer, ^list, %Snapshot{version: 0}}
      {:ok, _} = Listex.subscribe(list, :updates)

      {:ok, b} = Listex.insert(list, "b")

      assert_receive {:listex, ^list, %Event{type: :inserted, item: %Item{id: ^b}}}
      assert_receive {:peer, ^peer, ^list, %Snapshot{version: 1, items: [_, %Item{id: ^b}]}}
    end
  end
end
