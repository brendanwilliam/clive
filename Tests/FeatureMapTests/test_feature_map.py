import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("feature_map", ROOT / "scripts/feature-map.py")
feature_map = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(feature_map)


class FeatureMapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads((ROOT / "docs/ui-feature-map.json").read_text())

    def test_repository_map_is_valid_and_canonical(self):
        text = (ROOT / "docs/ui-feature-map.json").read_text()
        feature_map.validate_data(self.data, canonical_text=text)

    def test_dangling_relationship_is_rejected(self):
        value = copy.deepcopy(self.data)
        value["components"][0]["related_components"] = ["ios.missing.value"]
        with self.assertRaisesRegex(feature_map.MapError, "dangling relationship"):
            feature_map.validate_data(value)

    def test_hierarchy_path_and_order_are_rejected(self):
        value = copy.deepcopy(self.data)
        value["components"][1]["canonical_path"] = "wrong"
        with self.assertRaisesRegex(feature_map.MapError, "canonical_path"):
            feature_map.validate_data(value)
        value = copy.deepcopy(self.data)
        value["components"][1]["order"] = 99
        with self.assertRaisesRegex(feature_map.MapError, "contiguous"):
            feature_map.validate_data(value)

    def test_unsafe_and_stale_paths_are_rejected(self):
        value = copy.deepcopy(self.data)
        value["components"][0]["resources"]["views"] = ["../secret"]
        with self.assertRaisesRegex(feature_map.MapError, "unsafe"):
            feature_map.validate_data(value)
        value = copy.deepcopy(self.data)
        value["components"][0]["resources"]["views"] = ["missing.swift"]
        with self.assertRaisesRegex(feature_map.MapError, "does not exist"):
            feature_map.validate_data(value)

    def test_duplicate_resources_are_rejected(self):
        value = copy.deepcopy(self.data)
        resources = value["components"][0]["resources"]["views"]
        resources.append(resources[0])
        with self.assertRaisesRegex(feature_map.MapError, "must not contain duplicates"):
            feature_map.validate_data(value)

    def test_bootstrap_and_component_change_pass(self):
        self.assertIn("bootstrap", feature_map.check_change_data(None, self.data, ["docs/ui-feature-map.json"], "docs/ui-feature-map.json"))
        old = copy.deepcopy(self.data); new = copy.deepcopy(old)
        new["components"][0]["aliases"].append("App workspace")
        self.assertIn("component mappings", feature_map.check_change_data(old, new, ["Apps/Clive/App/WorkspaceView.swift", "docs/ui-feature-map.json"], "docs/ui-feature-map.json"))

    def test_valid_no_impact_review_passes(self):
        old = copy.deepcopy(self.data); new = copy.deepcopy(old)
        new["reviews"].append({"id": "2099-01-01-doc-fix", "reason": "Documentation wording only.", "paths": ["README.md"], "result": "no-component-impact"})
        self.assertIn("matches", feature_map.check_change_data(old, new, ["README.md", "docs/ui-feature-map.json"], "docs/ui-feature-map.json"))

    def test_missing_edited_incomplete_stale_or_out_of_order_review_fails(self):
        old = copy.deepcopy(self.data)
        cases = []
        cases.append(copy.deepcopy(old))
        immutable_old = copy.deepcopy(old); immutable_old["reviews"] = [{"id": "2098-01-01-old", "reason": "An existing review record.", "paths": ["AGENTS.md"], "result": "no-component-impact"}]
        edited = copy.deepcopy(immutable_old); edited["reviews"][0]["reason"] = "An invalid replacement record."
        with self.assertRaises(feature_map.MapError):
            feature_map.check_change_data(immutable_old, edited, ["README.md", "docs/ui-feature-map.json"], "docs/ui-feature-map.json")
        incomplete = copy.deepcopy(old); incomplete["reviews"].append({"id": "2099-01-01-doc", "reason": "Documentation wording only.", "paths": [], "result": "no-component-impact"}); cases.append(incomplete)
        stale = copy.deepcopy(old); stale["reviews"].append({"id": "2099-01-01-doc", "reason": "Documentation wording only.", "paths": ["CONTRIBUTING.md"], "result": "no-component-impact"}); cases.append(stale)
        unordered = copy.deepcopy(old); unordered["reviews"].append({"id": "2099-01-01-doc", "reason": "Documentation wording only.", "paths": ["README.md", "AGENTS.md"], "result": "no-component-impact"}); cases.append(unordered)
        for value in cases:
            with self.subTest(value=value.get("reviews")):
                with self.assertRaises(feature_map.MapError):
                    feature_map.check_change_data(old, value, ["README.md", "docs/ui-feature-map.json"], "docs/ui-feature-map.json")

    def test_exact_alias_and_ambiguous_queries_are_deterministic(self):
        self.assertEqual(["ios.workspace.root"], [value["id"] for value in feature_map.query_matches(self.data, "ios.workspace.root")])
        self.assertEqual(["ios.workspace.root"], [value["id"] for value in feature_map.query_matches(self.data, "Terminal workspace")])
        value = copy.deepcopy(self.data)
        value["legacy_components"][0]["aliases"].append("Terminal workspace")
        self.assertEqual(
            ["ios.workspace.root", "ios.legacy.mac-list"],
            [item["id"] for item in feature_map.query_matches(value, "Terminal workspace")],
        )

    def test_terminal_screen_has_required_row_and_column_hierarchy(self):
        components = {component["id"]: component for component in self.data["components"]}
        expected = {
            "ios.workspace.header-row": ("row", "ios.workspace.root", 1),
            "ios.workspace.terminal-list-button": ("column", "ios.workspace.header-row", 1),
            "ios.workspace.current-connection": ("column", "ios.workspace.header-row", 2),
            "ios.workspace.terminal-actions": ("group", "ios.workspace.header-row", 3),
            "ios.workspace.shortcut-button": ("control", "ios.workspace.terminal-actions", 1),
            "ios.workspace.new-terminal-button": ("control", "ios.workspace.terminal-actions", 2),
            "ios.workspace.terminal-row": ("row", "ios.workspace.root", 2),
            "ios.workspace.terminal-pager": ("repeated", "ios.workspace.terminal-row", 1),
            "ios.workspace.keyboard-row": ("row", "ios.workspace.root", 3),
            "ios.workspace.terminal-keyboard": ("overlay", "ios.workspace.keyboard-row", 1),
        }
        for component_id, (kind, parent, order) in expected.items():
            with self.subTest(component_id=component_id):
                component = components[component_id]
                self.assertEqual(kind, component["kind"])
                self.assertEqual(parent, component["parent"])
                self.assertEqual(order, component["order"])
        self.assertEqual(
            ["ios.workspace.terminal-pager"],
            [component["id"] for component in feature_map.query_matches(self.data, "Terminal")],
        )

    def test_whitespace_and_schema_only_changes_need_a_review(self):
        old = copy.deepcopy(self.data)
        with self.assertRaisesRegex(feature_map.MapError, "append exactly one"):
            feature_map.check_change_data(old, copy.deepcopy(old), ["docs/ui-feature-map.json"], "docs/ui-feature-map.json")
        with self.assertRaisesRegex(feature_map.MapError, "append exactly one"):
            feature_map.check_change_data(old, copy.deepcopy(old), ["docs/ui-feature-map.schema.json", "docs/ui-feature-map.json"], "docs/ui-feature-map.json")

    def test_later_commit_makes_review_stale(self):
        old = copy.deepcopy(self.data); new = copy.deepcopy(old)
        new["reviews"].append({"id": "2099-01-01-doc", "reason": "Documentation wording only.", "paths": ["README.md"], "result": "no-component-impact"})
        with self.assertRaisesRegex(feature_map.MapError, "stale"):
            feature_map.check_change_data(old, new, ["README.md", "SECURITY.md", "docs/ui-feature-map.json"], "docs/ui-feature-map.json")


if __name__ == "__main__":
    unittest.main()
