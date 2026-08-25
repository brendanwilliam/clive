---
name: clive-update-feature-map
description: Update and freshness-check Clive's UI feature map when preparing a pull request into develop.
---

# Update the Clive feature map

Use this when preparing a pull request into `develop`, not for every intermediate
commit. The final branch diff is the source of truth. Before editing the map, inspect
the complete diff from the PR base and query the affected components:

```sh
git diff --stat <base>...HEAD
git diff <base>...HEAD
python3 scripts/feature-map.py query <id-or-name>
```

Read [the naming reference](../../docs/ui-feature-map-naming.md) and update component
relationships and resources for affected UI, state, actions, navigation, models, services,
protocols, accessibility identifiers, localization, tests, fixtures, assets, previews, and
documentation. Preserve stable IDs and explicit empty resource categories.

If the complete PR diff has no component impact, append exactly one review record. Its ID is
`YYYY-MM-DD-<stable-slug>`, its reason explains why mappings are unchanged, its result is
`no-component-impact`, and its sorted repository-relative `paths` exactly equal all PR
paths except `docs/ui-feature-map.json`. Never edit an existing record. Do not use PR-body
attestations or include sensitive/runtime values.

Finish with:

```sh
python3 scripts/feature-map.py validate
python3 scripts/feature-map.py check-change --base <base>
python3 -m unittest discover -s Tests/FeatureMapTests
```
