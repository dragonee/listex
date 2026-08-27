# Listex

[![Hex.pm](https://img.shields.io/hexpm/v/listex.svg)](https://hex.pm/packages/listex)
[![Docs](https://img.shields.io/badge/hexdocs-listex-informational)](https://hexdocs.pm/listex)
[![License](https://img.shields.io/hexpm/l/listex.svg)](LICENSE)

One process per list, for simple concurrent editing.

A list is spawned from a plain Elixir list and lives in its own process.
Editors send it operations; it applies them one at a time, in arrival order,
and tells subscribers what happened. Items keep the id they were given for as
long as they exist, so an editor can hold on to an id and refer to it later
even after everyone else has reordered the list underneath it.

No operational transform, no CRDT, no merge — **arrival order wins**. That is
the whole conflict policy, and for a shared to-do list, a playlist, a kanban
column or a set of form rows, it is usually the policy you actually want.

Pure Elixir, no dependencies.

## Installation

Add `:listex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:listex, "~> 0.1.0"}
  ]
end
```

Or straight from git:

```elixir
def deps do
  [
    {:listex, github: "dragonee/listex"}
  ]
end
```

Then `mix deps.get`. Listex starts its own supervision tree (a `Registry` and a
`DynamicSupervisor`) when your application starts — there is nothing to add to
your own supervisor.

Requires Elixir ~> 1.14 and OTP 24 or later.

## Getting started

### Spawn a list from a list

```elixir
{:ok, list} = Listex.new(["milk", "eggs"])
```

`list` is the list's id, and it is what you pass to everything else here. The
contents are any terms you like — strings, maps, structs, tuples:

```elixir
{:ok, todos} = Listex.new([
  %{"title" => "buy milk", "done" => false},
  %{"title" => "call mum", "done" => true}
])
```

### Edit it

```elixir
{:ok, id} = Listex.insert(list, "bread")        # appended, returns a stable id
{:ok, id} = Listex.insert(list, "jam", after: id)
{:ok, _}  = Listex.update(list, id, "marmalade")
:ok       = Listex.move(list, id, :start)
:ok       = Listex.delete(list, id)

Listex.contents(list)
#=> ["milk", "eggs", "bread"]
```

Every operation is a message to one process, so concurrent editors are
serialised for free. The id you got back is yours to keep: moves, updates and
other people's edits never change it.

### Watch it

Two kinds of subscription, depending on whether you would rather re-render or
patch:

```elixir
# The whole list after every change — simplest thing to render.
{:ok, snapshot} = Listex.subscribe(list, :full)

receive do
  {:listex, ^list, %Listex.Snapshot{version: v, items: items}} ->
    render(items)
end

# Or one event per change — enough to keep your own copy in step.
{:ok, snapshot} = Listex.subscribe(list, :updates)

receive do
  {:listex, ^list, %Listex.Event{type: :inserted, item: item, after: anchor}} ->
    insert_row(item, anchor)

  {:listex, ^list, %Listex.Event{type: :deleted, id: id}} ->
    remove_row(id)
end
```

`subscribe/3` returns the current snapshot as a baseline, so there is no gap
between reading the list and starting to hear about it. Events carry
consecutive `:version` numbers: if one skips, you missed a message and should
re-read with `Listex.snapshot/1`.

### Show who is typing

```elixir
Listex.start_editing(list, item_id, %{user: "kim"})
```

A no-op as far as the list is concerned — nothing changes and the version stays
put — that reaches every *other* subscriber, of both kinds, as
`%Listex.Event{type: :editing, id: item_id, data: data, by: pid}`. Put whatever
you want in `data`; it is passed through untouched.

### Let it go

A list process exits after five minutes without a client message. Subscribers
get `{:listex, list_id, {:closed, :idle}}` first, and calls afterwards return
`{:error, :no_list}` rather than exiting the caller. Bring it back from your own
storage with the id you already have:

```elixir
{:ok, _pid} = Listex.open(list, contents_from_your_database)
```

Change or disable the timeout per list:

```elixir
{:ok, list} = Listex.new(contents, idle_timeout: :timer.minutes(30))
{:ok, list} = Listex.new(contents, idle_timeout: :infinity)
```

## Operations

| Operation | Call | Result |
| --- | --- | --- |
| insert | `Listex.insert(list, content, after: :end \| :start \| id)` | `{:ok, id}` |
| update | `Listex.update(list, id, content)` | `{:ok, item}` |
| move | `Listex.move(list, id, after_id \| :start \| :end)` | `:ok` |
| delete | `Listex.delete(list, id)` | `:ok` |
| start editing | `Listex.start_editing(list, id, data)` | `:ok` |

Errors are `{:error, :not_found}` (the item is gone), `{:error, :anchor_not_found}`
(the item you wanted to sit behind is gone), `{:error, :id_taken}` and
`{:error, :no_list}`.

`Listex.cast/2` sends the same operations without waiting for a reply — same
ordering, no round trip, no error reporting.

## Conflict policy

Arrival order wins, and the process mailbox decides the order.

* Two editors renaming the same item both get `{:ok, item}`. The list holds
  what the second one wrote.
* An operation on an item somebody else has already deleted gets
  `{:error, :not_found}` — its author lost the race, and the event stream tells
  them why.
* A move behind an anchor that has just been deleted is refused rather than
  quietly appended somewhere. Re-read and try again.
* Nothing is queued, retried or transformed. What you see in the event stream
  is what happened, in the order it happened.

## Lifetime and state

State lives in the process and nowhere else: when the process goes, so does the
list. That is deliberate — Listex is the editing session, not the database.
Persist by subscribing (`:updates` for a change log, `:full` for
write-the-whole-thing) and rehydrate with `Listex.new/2` or `Listex.open/3`,
passing `Listex.Item` structs when you want the ids back too.

A list that crashes is not restarted: a `:temporary` child is better than one
silently resurrected from stale contents.

## Documentation

Every module and function is documented. Build the full API reference locally:

```
mix deps.get
mix docs
open doc/index.html
```

`ex_doc` is the only dependency and it is `only: :dev` — nothing is pulled in
at runtime.

## Testing

```
mix test
```

The suite covers the operations and their failure cases, both kinds of
subscriber, event replay (an update-only subscriber must be able to reconstruct
the list exactly), the editing signal, idle shutdown and what happens when
dozens of editors hit one list at once.

## License

MIT — see [LICENSE](LICENSE).
