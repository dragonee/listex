defmodule ListexTest do
  use ExUnit.Case, async: true

  doctest Listex, except: [:moduledoc]

  import Listex.TestHelpers

  alias Listex.{Item, Snapshot}

  defp contents(list), do: Listex.contents(list)

  describe "new/2" do
    test "spawns a process from a plain list" do
      list = start_list(["milk", "eggs"])

      assert Listex.alive?(list)
      assert contents(list) == ["milk", "eggs"]
    end

    test "spawns an empty list" do
      list = start_list()

      assert contents(list) == []
      assert %Snapshot{version: 0, items: []} = Listex.snapshot(list)
    end

    test "gives every item a distinct id" do
      list = start_list(["a", "a", "a"])

      ids = list |> Listex.items() |> Enum.map(& &1.id)
      assert length(Enum.uniq(ids)) == 3
    end

    test "accepts a caller-chosen list id" do
      id = "list-" <> Base.encode16(:crypto.strong_rand_bytes(4))

      assert {:ok, ^id} = Listex.new(["a"], id: id, idle_timeout: :timer.seconds(30))
      on_exit(fn -> Listex.stop(id) end)
      assert is_pid(Listex.whereis(id))
      assert Listex.contents(id) == ["a"]
    end

    test "refuses a second list under the same id" do
      list = start_list(["a"])

      assert {:error, :already_started} = Listex.new(["b"], id: list)
    end

    test "restores items with the ids they already had" do
      items = [Item.new("a", "id-a"), Item.new("b", "id-b")]
      list = start_list(items)

      assert Listex.items(list) == items
      assert {:ok, item} = Listex.update(list, "id-a", "A")
      assert item.id == "id-a"
    end

    @tag :capture_log
    test "refuses contents with duplicate ids" do
      items = [Item.new("a", "same"), Item.new("b", "same")]

      assert {:error, {:duplicate_ids, ["same"]}} = Listex.new(items)
    end
  end

  describe "open/3" do
    test "spawns the list when it is not running" do
      id = Listex.ID.new()
      on_exit(fn -> Listex.stop(id) end)

      refute Listex.alive?(id)
      assert {:ok, pid} = Listex.open(id, ["a"], idle_timeout: :timer.seconds(30))
      assert is_pid(pid)
      assert contents(id) == ["a"]
    end

    test "returns the running process and ignores the contents when it is alive" do
      list = start_list(["a"])
      pid = Listex.whereis(list)

      assert {:ok, ^pid} = Listex.open(list, ["ignored"])
      assert contents(list) == ["a"]
    end

    test "reopens a list after its process is gone" do
      list = start_list(["a"])
      :ok = Listex.stop(list)

      assert {:ok, pid} = Listex.open(list, ["a", "b"], idle_timeout: :timer.seconds(30))
      on_exit(fn -> Listex.stop(pid) end)
      assert contents(list) == ["a", "b"]
    end
  end

  describe "insert/3" do
    test "appends by default and returns a stable id" do
      list = start_list(["a"])

      assert {:ok, id} = Listex.insert(list, "b")
      assert contents(list) == ["a", "b"]
      assert [_a, %Item{id: ^id, content: "b", rev: 0}] = Listex.items(list)
    end

    test "inserts at the start" do
      list = start_list(["a"])

      {:ok, _} = Listex.insert(list, "b", after: :start)
      assert contents(list) == ["b", "a"]
    end

    test "inserts after a given id" do
      list = start_list(["a", "c"])
      [a, _c] = Listex.items(list)

      {:ok, _} = Listex.insert(list, "b", after: a.id)
      assert contents(list) == ["a", "b", "c"]
    end

    test "refuses an anchor that is not there" do
      list = start_list(["a"])

      assert {:error, :anchor_not_found} = Listex.insert(list, "b", after: "nope")
      assert contents(list) == ["a"]
    end

    test "accepts a caller-minted id" do
      list = start_list()

      assert {:ok, "mine"} = Listex.insert(list, "a", id: "mine")
      assert [%Item{id: "mine"}] = Listex.items(list)
    end

    test "refuses an id that is already taken" do
      list = start_list()
      {:ok, "mine"} = Listex.insert(list, "a", id: "mine")

      assert {:error, :id_taken} = Listex.insert(list, "b", id: "mine")
      assert contents(list) == ["a"]
    end

    test "keeps ids stable across every other operation" do
      list = start_list()
      {:ok, a} = Listex.insert(list, "a")
      {:ok, b} = Listex.insert(list, "b")
      {:ok, c} = Listex.insert(list, "c")

      {:ok, _} = Listex.update(list, a, "A")
      :ok = Listex.move(list, a, :end)
      :ok = Listex.delete(list, b)
      {:ok, d} = Listex.insert(list, "d", after: c)

      assert Enum.map(Listex.items(list), &{&1.id, &1.content}) ==
               [{c, "c"}, {d, "d"}, {a, "A"}]
    end
  end

  describe "update/3" do
    test "replaces content, bumps rev, keeps id and position" do
      list = start_list(["a", "b", "c"])
      [_a, b, _c] = Listex.items(list)

      assert {:ok, %Item{id: id, content: "B", rev: 1}} = Listex.update(list, b.id, "B")
      assert id == b.id
      assert contents(list) == ["a", "B", "c"]
    end

    test "bumps rev once per update" do
      list = start_list(["a"])
      [a] = Listex.items(list)

      {:ok, _} = Listex.update(list, a.id, 1)
      {:ok, _} = Listex.update(list, a.id, 2)
      assert {:ok, %Item{rev: 3}} = Listex.update(list, a.id, 3)
    end

    test "fails for an unknown id" do
      list = start_list(["a"])

      assert {:error, :not_found} = Listex.update(list, "nope", "x")
    end
  end

  describe "move/3" do
    setup do
      list = start_list(["a", "b", "c"])
      [a, b, c] = Listex.items(list)
      %{list: list, a: a.id, b: b.id, c: c.id}
    end

    test "moves to the start", %{list: list, c: c} do
      assert :ok = Listex.move(list, c, :start)
      assert contents(list) == ["c", "a", "b"]
    end

    test "moves to the end", %{list: list, a: a} do
      assert :ok = Listex.move(list, a, :end)
      assert contents(list) == ["b", "c", "a"]
    end

    test "moves after another id", %{list: list, a: a, b: b} do
      assert :ok = Listex.move(list, a, b)
      assert contents(list) == ["b", "a", "c"]
    end

    test "moving after an item that follows it works too", %{list: list, a: a, c: c} do
      assert :ok = Listex.move(list, a, c)
      assert contents(list) == ["b", "c", "a"]
    end

    test "moving an item where it already is changes nothing", %{list: list, b: b, a: a} do
      assert :ok = Listex.move(list, b, a)
      assert contents(list) == ["a", "b", "c"]
    end

    test "moving after itself is a no-op", %{list: list, b: b} do
      assert :ok = Listex.move(list, b, b)
      assert contents(list) == ["a", "b", "c"]
      assert %Snapshot{version: 0} = Listex.snapshot(list)
    end

    test "fails for an unknown item", %{list: list, a: a} do
      assert {:error, :not_found} = Listex.move(list, "nope", a)
      assert contents(list) == ["a", "b", "c"]
    end

    test "fails for an unknown anchor", %{list: list, a: a} do
      assert {:error, :anchor_not_found} = Listex.move(list, a, "nope")
      assert contents(list) == ["a", "b", "c"]
    end

    test "leaves the list untouched when the anchor is missing", %{list: list, a: a} do
      {:error, :anchor_not_found} = Listex.move(list, a, "nope")
      assert length(Listex.items(list)) == 3
    end
  end

  describe "delete/2" do
    test "removes the item" do
      list = start_list(["a", "b", "c"])
      [_a, b, _c] = Listex.items(list)

      assert :ok = Listex.delete(list, b.id)
      assert contents(list) == ["a", "c"]
    end

    test "fails for an unknown id" do
      list = start_list(["a"])

      assert {:error, :not_found} = Listex.delete(list, "nope")
    end

    test "does not free the id for reuse by later operations" do
      list = start_list(["a"])
      [a] = Listex.items(list)
      :ok = Listex.delete(list, a.id)

      assert {:error, :not_found} = Listex.update(list, a.id, "x")
      assert {:error, :not_found} = Listex.move(list, a.id, :start)
      assert {:error, :not_found} = Listex.delete(list, a.id)
    end
  end

  describe "versioning" do
    test "every applied change bumps the version by one" do
      list = start_list()

      assert %Snapshot{version: 0} = Listex.snapshot(list)
      {:ok, id} = Listex.insert(list, "a")
      assert %Snapshot{version: 1} = Listex.snapshot(list)
      {:ok, _} = Listex.update(list, id, "A")
      assert %Snapshot{version: 2} = Listex.snapshot(list)
      :ok = Listex.move(list, id, :start)
      assert %Snapshot{version: 3} = Listex.snapshot(list)
      :ok = Listex.delete(list, id)
      assert %Snapshot{version: 4} = Listex.snapshot(list)
    end

    test "rejected operations and reads do not bump the version" do
      list = start_list(["a"])

      {:error, :not_found} = Listex.delete(list, "nope")
      {:error, :anchor_not_found} = Listex.insert(list, "b", after: "nope")
      Listex.snapshot(list)
      Listex.contents(list)

      assert %Snapshot{version: 0} = Listex.snapshot(list)
    end
  end

  describe "arbitrary content" do
    test "holds any term without inspecting it" do
      terms = [
        "a string",
        %{"title" => "a map", "done" => false},
        %{atom: :keys, nested: %{deep: [1, 2, 3]}},
        [1, 2, 3],
        {:a, :tuple},
        :an_atom,
        42,
        3.14,
        nil,
        <<0, 1, 2>>,
        MapSet.new([1, 2]),
        ~D[2026-08-27],
        fn -> :ok end
      ]

      list = start_list(terms)

      assert contents(list) == terms
    end

    test "round-trips content through insert and update unchanged" do
      list = start_list()
      content = %{"body" => "hello", "tags" => ["a", "b"], "meta" => %{"n" => 1}}

      {:ok, id} = Listex.insert(list, content)
      assert [%Item{content: ^content}] = Listex.items(list)

      updated = put_in(content["meta"]["n"], 2)
      {:ok, %Item{content: ^updated}} = Listex.update(list, id, updated)
      assert contents(list) == [updated]
    end

    test "mixes content shapes in one list" do
      list = start_list(["string"])
      {:ok, _} = Listex.insert(list, %{map: true})
      {:ok, _} = Listex.insert(list, {:tuple, 1}, after: :start)

      assert contents(list) == [{:tuple, 1}, "string", %{map: true}]
    end
  end

  describe "reads" do
    test "snapshot, items and contents agree" do
      list = start_list(["a", "b"])

      snapshot = Listex.snapshot(list)
      assert %Snapshot{list_id: ^list, version: 0} = snapshot
      assert snapshot.items == Listex.items(list)
      assert Snapshot.contents(snapshot) == Listex.contents(list)
    end
  end

  describe "lifecycle" do
    test "stop/1 shuts the list down" do
      list = start_list(["a"])
      pid = Listex.whereis(list)
      ref = Process.monitor(pid)

      assert :ok = Listex.stop(list)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      refute Listex.alive?(list)
    end

    test "stop/1 on a list that is already gone is fine" do
      assert :ok = Listex.stop(Listex.ID.new())
    end

    test "operations on a dead list report it instead of exiting" do
      list = start_list(["a"])
      :ok = Listex.stop(list)

      assert {:error, :no_list} = Listex.insert(list, "b")
      assert {:error, :no_list} = Listex.update(list, "x", "b")
      assert {:error, :no_list} = Listex.move(list, "x", :start)
      assert {:error, :no_list} = Listex.delete(list, "x")
      assert {:error, :no_list} = Listex.snapshot(list)
      assert {:error, :no_list} = Listex.subscribe(list)
      assert {:error, :no_list} = Listex.start_editing(list, "x")
    end

    test "accepts a pid as well as an id" do
      list = start_list(["a"])
      pid = Listex.whereis(list)

      assert {:ok, _} = Listex.insert(pid, "b")
      assert Listex.contents(pid) == ["a", "b"]
      assert Listex.alive?(pid)
    end

    test "list_ids/0 reports live lists" do
      list = start_list(["a"])

      assert list in Listex.list_ids()
      :ok = Listex.stop(list)
      assert wait_until(fn -> list not in Listex.list_ids() end)
    end

    @tag :capture_log
    test "a crashing list is not restarted with stale contents" do
      list = start_list(["a"])
      pid = Listex.whereis(list)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # Give the supervisor a moment to not restart it.
      Process.sleep(50)
      refute Listex.alive?(list)
    end
  end
end
