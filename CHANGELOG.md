# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-08-27

First release.

### Added

- `Listex.new/2` spawns a list process from a plain Elixir list; contents are
  any term. `Listex.open/3` reopens one by id after its process has gone.
- Operations: `insert/3` (with `:after` and a caller-minted `:id`),
  `update/3`, `move/3`, `delete/2`, and `cast/2` for the same operations
  without a round trip.
- `start_editing/4` — a presence signal that reaches every other subscriber
  without changing the list or its version.
- Stable item ids: assigned once at insert and untouched by every other
  operation.
- Arrival order as the conflict policy. Operations naming an item or anchor
  that is already gone are refused with `{:error, :not_found}` or
  `{:error, :anchor_not_found}` rather than guessed at.
- Two kinds of subscriber: `:full` receives a `Listex.Snapshot` after every
  change, `:updates` receives one `Listex.Event` per change with consecutive
  versions. Subscribers are monitored and dropped when they die.
- Idle shutdown after five minutes, configurable per list with
  `:idle_timeout`. Subscribers are told with `{:closed, :idle}`, and calls to
  a list that is gone return `{:error, :no_list}` instead of exiting the
  caller.
- `Listex.List` can be started and supervised on its own, without the
  registry.

[0.1.0]: https://github.com/dragonee/listex/releases/tag/v0.1.0
