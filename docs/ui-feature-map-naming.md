# UI feature map naming

The feature map describes user-visible surfaces without copying runtime data. It is an
inventory and navigation aid, not a snapshot of a particular account or terminal.

## Stable identifiers

Component IDs use `<platform>.<surface>.<component>`. `platform` is `ios`, `macos`, or
`widget`; `surface` is a durable product surface, and `component` is a short semantic
token. IDs do not encode row numbers, presentation wording, or current layout. Put
renamed terms in `aliases`; do not change an ID just because a label or position moves.

Hierarchy lives in `parent`. Within each parent, `order` starts at 1 and is contiguous.
`canonical_path` is the slash-separated semantic-name path from the root component to
the component. This gives queries a human-readable screen → row → column ordering while
leaving IDs stable.

## Hierarchy and kinds

- A screen or window is a root. Place its rows or groups beneath it, then columns or
  controls beneath those groups.
- Use `group` for nested visual or semantic groups and `repeated` for a row or card
  template rendered from a collection. Describe the collection in `repetition`.
- Drawers, sheets, windows, menus, widgets, alerts, and overlays use those `kind` values.
  Put the trigger and dismissal behavior in `presentation` and link the trigger with
  `related_components`.
- Model conditional variants as one stable component with named `states`, unless a
  variant has independent actions, resources, or navigation and needs its own component.
- Compiled UI that cannot be reached from a current entry point belongs in
  `legacy_components`, never in the reachable `components` list.

## Vocabulary

Prefer **Terminal** for a shell UI or session, **Connection** for a paired Mac and its
route, and **Attachment** for a client joined to a shared terminal. Record older or
conflicting labels as aliases. Protocol and CLI spellings such as `session.open`,
`terminal.resize`, and `clive attach` are exact interfaces and must not be renamed.

For user-facing agentic workflows, use the shared terms in
[the Human Interface Guidelines reference](human-interface-guidelines.md). In particular,
use **Task**, **Proposal**, **Approval**, **Run**, **Needs attention**, **Paused**,
**Completed**, **Failed**, **Cancelled**, and **Result** consistently across component
names, states, accessibility identifiers, and documentation. Platform-native terminology
and exact protocol or CLI spellings take precedence.

## Safety

Record source paths, type names, static localization keys, and identifier patterns only.
Never record certificate fingerprints, QR payloads, pairing material, hostnames,
credentials, terminal input/output, device names, or other runtime values.

## Query and maintenance workflow

Resolve a canonical ID, semantic name, or exact alias without searching the repository:

```sh
python3 scripts/feature-map.py query Terminal
python3 scripts/feature-map.py query ios.workspace.new-terminal-button
```

For a component-impacting change, update its hierarchy, relationships, states, and every
resource category in `docs/ui-feature-map.json`. Preserve existing IDs when labels or
layout change. For a change with no component impact, append one immutable
`no-component-impact` review whose sorted paths cover the complete pull-request diff
except the map itself.

Validation executes the versioned JSON Schema, checks hierarchy and ordering invariants,
and verifies every repository-relative resource path. Validate the result locally against
the pull-request base:

```sh
python3 scripts/feature-map.py validate
python3 scripts/feature-map.py check-change --base <develop-base>
python3 -m unittest discover -s Tests/FeatureMapTests
```
