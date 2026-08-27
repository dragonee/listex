defmodule Listex.DataTest do
  use ExUnit.Case, async: true

  alias Listex.{Event, ID, Item, Snapshot}

  describe "Listex.ID" do
    test "generates url-safe ids" do
      id = ID.new()

      assert is_binary(id)
      assert id =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "does not repeat itself" do
      ids = Enum.map(1..10_000, fn _ -> ID.new() end)

      assert length(Enum.uniq(ids)) == 10_000
    end
  end

  describe "Listex.Item" do
    test "generates an id when none is given" do
      assert %Item{id: id, content: "a", rev: 0} = Item.new("a")
      assert is_binary(id)
    end

    test "keeps the id it is handed" do
      assert %Item{id: "mine", content: "a"} = Item.new("a", "mine")
    end

    test "holds any term as content" do
      for content <- ["a", %{a: 1}, {:a, 1}, [1, 2], nil, 1.5, self()] do
        assert %Item{content: ^content} = Item.new(content)
      end
    end

    test "requires an id" do
      assert_raise ArgumentError, fn -> struct!(Item, content: "a") end
    end
  end

  describe "Listex.Snapshot" do
    test "contents/1 strips ids and revisions" do
      snapshot = %Snapshot{
        list_id: "l",
        version: 3,
        items: [Item.new("a"), Item.new(%{b: 1})]
      }

      assert Snapshot.contents(snapshot) == ["a", %{b: 1}]
    end

    test "contents/1 of an empty list" do
      assert Snapshot.contents(%Snapshot{list_id: "l", version: 0, items: []}) == []
    end
  end

  describe "Listex.Event" do
    test "requires a type, a list id and a version" do
      assert %Event{type: :deleted, list_id: "l", version: 1, id: "i"} =
               %Event{type: :deleted, list_id: "l", version: 1, id: "i"}

      assert_raise ArgumentError, fn -> struct!(Event, type: :deleted) end
    end

    test "leaves the fields that do not apply nil" do
      event = %Event{type: :deleted, list_id: "l", version: 1, id: "i"}

      assert event.item == nil
      assert event.after == nil
      assert event.data == nil
      assert event.by == nil
    end
  end
end
