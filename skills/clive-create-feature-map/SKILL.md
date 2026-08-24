---
name: clive-create-feature-map
description: Create or substantially rebuild Clive's versioned UI feature map, including first inventories and new platform surfaces.
---

# Create the Clive feature map

Use this skill for bootstrap inventories, major rebuilds, and adding a platform—not for
ordinary repository changes. Read [the naming reference](../../docs/ui-feature-map-naming.md)
and [schema](../../docs/ui-feature-map.schema.json) before editing
`docs/ui-feature-map.json`.

Trace reachable UI from every app and extension entry point. Follow navigation,
presentations, conditional branches, menus, deep links, and repeated elements. Put
compiled but unreachable views in `legacy_components` and record conflicting terminology
as aliases. Apply stable IDs and hierarchy from the naming reference; do not encode layout
or display wording in IDs.

For every component, inspect and populate every resource category. Use an explicit empty
array when none exists. Never copy runtime values, QR data, fingerprints, hostnames,
credentials, or Terminal content into the map.

Run:

```sh
python3 scripts/feature-map.py validate
python3 scripts/feature-map.py query <representative-id-or-name>
python3 -m unittest discover -s Tests/FeatureMapTests
```

Query representative iOS, macOS, widget, and security-related components. Use
`clive-update-feature-map` for later routine changes.
