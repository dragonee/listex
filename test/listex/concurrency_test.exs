defmodule Listex.ConcurrencyTest do
  use ExUnit.Case, async: true

  import Listex.TestHelpers

  alias Listex.{Event, Item, Replay, Snapshot}

  @editors 8
  @ops_per_editor 25

  describe "arrival order wins" do
    test "the last update to land is the one that stays" do
      list = start_list(["a"])
      [a] = Listex.items(list)
      {:ok, _} = Listex.subscribe(list, :updates)

      results =
        1..50
        |> Task.async_stream(fn n -> Listex.update(list, a.id, n) end, max_concurrency: 50)
        |> Enum.map(fn {:ok, result} -> result end)

      # Nobody is refused: every editor's write was applied at some point.
      assert Enum.all?(results, &match?({:ok, %Item{}}, &1))

      # This call is answered after every event above was sent to us, so by the
      # time it returns the mailbox holds all of them.
      snapshot = Listex.snapshot(list)
      events = drain_events()

      assert length(events) == 50
      assert Enum.map(events, & &1.version) == Enum.to_list(1..50)

      # What the list holds is exactly what the last arrival wrote.
      assert %Snapshot{version: 50, items: [%Item{content: last, rev: 50}]} = snapshot
      assert last == events |> List.last() |> Map.fetch!(:item) |> Map.fetch!(:content)
      assert last in 1..50
    end

    test "concurrent appends all land, in the order the process saw them" do
      list = start_list()
      {:ok, _} = Listex.subscribe(list, :updates)

      ids =
        1..50
        |> Task.async_stream(fn n -> Listex.insert(list, n) end, max_concurrency: 50)
        |> Enum.map(fn {:ok, {:ok, id}} -> id end)

      snapshot = Listex.snapshot(list)
      events = drain_events()

      assert snapshot.version == 50
      assert length(ids) == 50
      assert Enum.sort(ids) == snapshot.items |> Enum.map(& &1.id) |> Enum.sort()

      # The event stream and the list agree on the order.
      assert Enum.map(events, & &1.item.id) == Enum.map(snapshot.items, & &1.id)
    end

    test "a delete and an update racing over one item leave a consistent list" do
      list = start_list(["a"])
      [a] = Listex.items(list)

      [delete, update] =
        [
          Task.async(fn -> {:update, Listex.update(list, a.id, "updated")} end),
          Task.async(fn -> {:delete, Listex.delete(list, a.id)} end)
        ]
        |> Task.await_many()
        |> Enum.sort_by(fn {op, _result} -> op end)

      assert {:delete, :ok} = delete

      case update do
        # The delete got there first; the update lost and was told so.
        {:update, {:error, :not_found}} -> :ok
        # The update got there first; both succeeded.
        {:update, {:ok, %Item{content: "updated"}}} -> :ok
      end

      assert Listex.contents(list) == []
    end

    test "a move whose anchor was just deleted is refused rather than guessed at" do
      list = start_list(["a", "b", "c"])
      [a, b, c] = Listex.items(list)

      :ok = Listex.delete(list, b.id)

      assert {:error, :anchor_not_found} = Listex.move(list, c.id, b.id)
      assert Enum.map(Listex.items(list), & &1.id) == [a.id, c.id]
    end
  end

  describe "many editors at once" do
    test "the list survives a storm of mixed operations and stays consistent" do
      seed = ExUnit.configuration()[:seed]
      list = start_list(Enum.map(1..10, &"item #{&1}"))
      {:ok, baseline} = Listex.subscribe(list, :updates)
      known = Enum.map(baseline.items, & &1.id)

      1..@editors
      |> Task.async_stream(
        fn editor ->
          :rand.seed(:exsss, {seed, editor, editor})
          Enum.each(1..@ops_per_editor, fn n -> random_op(list, known, editor, n) end)
        end,
        max_concurrency: @editors,
        timeout: 30_000
      )
      |> Stream.run()

      snapshot = Listex.snapshot(list)
      events = drain_events()
      changes = Enum.reject(events, &(&1.type == :editing))

      # Versions are consecutive, so a subscriber can tell it missed nothing.
      assert Enum.map(changes, & &1.version) == Enum.to_list(1..snapshot.version)

      # The events alone are enough to reconstruct the list exactly.
      assert Replay.replay(baseline, events) == snapshot.items

      # Ids stayed put: no renumbering, no duplicates, and the arithmetic of
      # inserts and deletes matches what is actually there.
      inserted = Enum.count(changes, &(&1.type == :inserted))
      deleted = Enum.count(changes, &(&1.type == :deleted))
      assert length(snapshot.items) == length(known) + inserted - deleted
      assert length(Enum.uniq_by(snapshot.items, & &1.id)) == length(snapshot.items)
      assert Enum.all?(snapshot.items, &is_binary(&1.id))
    end

    test "every subscriber sees the events in the same order" do
      list = start_list(["a"])
      {:ok, _} = Listex.subscribe(list, :updates)
      peer = start_peer(list)

      1..20
      |> Task.async_stream(fn n -> Listex.insert(list, n) end, max_concurrency: 20)
      |> Stream.run()

      Listex.snapshot(list)
      mine = drain_events() |> Enum.map(& &1.version)
      theirs = collect_peer_events(peer)

      assert mine == Enum.to_list(1..20)
      assert theirs == mine
    end
  end

  defp random_op(list, known, editor, n) do
    ids = Enum.map(Listex.items(list), & &1.id)
    id = Enum.random(ids ++ known)

    case :rand.uniform(6) do
      1 -> Listex.insert(list, {editor, n}, id: "e#{editor}-#{n}")
      2 -> Listex.insert(list, {editor, n}, after: id)
      3 -> Listex.update(list, id, {editor, n})
      4 -> Listex.move(list, id, Enum.random([:start, :end, id]))
      5 -> Listex.delete(list, id)
      6 -> Listex.start_editing(list, id, {editor, n})
    end
  end

  defp start_peer(list) do
    test = self()

    peer =
      spawn(fn ->
        {:ok, _} = Listex.subscribe(list, :updates)
        send(test, {:subscribed, self()})

        receive do
          {:collect, ^test} ->
            # Same trick: a synchronous call flushes everything the list sent
            # us beforehand into this mailbox.
            Listex.snapshot(list)
            send(test, {:collected, peer_drain([])})
        end
      end)

    assert_receive {:subscribed, ^peer}
    peer
  end

  defp peer_drain(acc) do
    receive do
      {:listex, _list, %Event{} = event} -> peer_drain([event.version | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_peer_events(peer) do
    send(peer, {:collect, self()})
    assert_receive {:collected, versions}
    versions
  end
end
