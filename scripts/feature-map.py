#!/usr/bin/env python3
"""Validate, query, and enforce freshness of Clive's dependency-free UI map."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MAP = ROOT / "docs/ui-feature-map.json"
SCHEMA = ROOT / "docs/ui-feature-map.schema.json"
RESOURCE_KEYS = (
    "views", "state_actions_navigation", "models_services_protocols",
    "accessibility_ids", "localization", "tests", "fixtures", "assets",
    "previews", "documentation",
)
COMPONENT_KEYS = (
    "id", "semantic_name", "platform", "kind", "parent", "canonical_path",
    "order", "aliases", "presentation", "repetition", "related_components",
    "states", "resources",
)
KINDS = {"screen", "row", "column", "group", "repeated", "drawer", "sheet", "window", "menu", "widget", "alert", "overlay", "control"}
ID_RE = re.compile(r"^(ios|macos|widget)\.[a-z0-9-]+\.[a-z0-9-]+$")
REVIEW_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*$")


class MapError(ValueError):
    pass


def load(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MapError(f"{path}: {error}") from error


def canonical(value: dict) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def validate_schema(instance: object, schema: dict, root: dict, path: str = "$") -> None:
    """Validate the JSON Schema vocabulary used by the feature-map schema."""
    if "$ref" in schema:
        reference = schema["$ref"]
        if not isinstance(reference, str) or not reference.startswith("#/"):
            raise MapError(f"unsupported schema reference at {path}: {reference!r}")
        target: object = root
        for part in reference[2:].split("/"):
            if not isinstance(target, dict) or part not in target:
                raise MapError(f"unresolved schema reference at {path}: {reference}")
            target = target[part]
        if not isinstance(target, dict):
            raise MapError(f"schema reference is not an object at {path}: {reference}")
        validate_schema(instance, target, root, path)
        return

    expected_type = schema.get("type")
    if expected_type is not None:
        names = expected_type if isinstance(expected_type, list) else [expected_type]
        matches = {
            "object": lambda value: isinstance(value, dict),
            "array": lambda value: isinstance(value, list),
            "string": lambda value: isinstance(value, str),
            "integer": lambda value: isinstance(value, int) and not isinstance(value, bool),
            "null": lambda value: value is None,
        }
        if not all(name in matches for name in names):
            raise MapError(f"unsupported schema type at {path}: {names!r}")
        if not any(matches[name](instance) for name in names):
            raise MapError(f"schema type mismatch at {path}: expected {' or '.join(names)}")

    if "const" in schema and instance != schema["const"]:
        raise MapError(f"schema const mismatch at {path}")
    if "enum" in schema and instance not in schema["enum"]:
        raise MapError(f"schema enum mismatch at {path}")
    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            raise MapError(f"schema minLength mismatch at {path}")
        if "pattern" in schema and re.fullmatch(schema["pattern"], instance) is None:
            raise MapError(f"schema pattern mismatch at {path}")
    if isinstance(instance, int) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            raise MapError(f"schema minimum mismatch at {path}")
    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            raise MapError(f"schema minItems mismatch at {path}")
        if "items" in schema:
            for index, value in enumerate(instance):
                validate_schema(value, schema["items"], root, f"{path}[{index}]")
    if isinstance(instance, dict):
        required = schema.get("required", [])
        missing = [key for key in required if key not in instance]
        if missing:
            raise MapError(f"schema required properties missing at {path}: {missing!r}")
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for key, value in instance.items():
            if key in properties:
                validate_schema(value, properties[key], root, f"{path}.{key}")
            elif isinstance(additional, dict):
                validate_schema(value, additional, root, f"{path}.{key}")
            elif additional is False:
                raise MapError(f"schema additional property at {path}: {key}")


def safe_path(value: str, *, must_exist: bool = True) -> None:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or value.startswith(".git/"):
        raise MapError(f"unsafe repository path: {value!r}")
    if must_exist and not (ROOT / value).exists():
        raise MapError(f"repository path does not exist: {value}")


def validate_data(data: dict, *, source: Path | None = None, canonical_text: str | None = None) -> None:
    required_root = ["schema_version", "naming_reference", "vocabulary", "components", "legacy_components", "reviews"]
    if list(data) != required_root or data.get("schema_version") != 1:
        raise MapError("root fields/order or schema_version is invalid")
    if data["naming_reference"] != "docs/ui-feature-map-naming.md":
        raise MapError("naming_reference is invalid")
    safe_path(data["naming_reference"])
    if not isinstance(data["vocabulary"], dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in data["vocabulary"].items()):
        raise MapError("vocabulary must map strings to strings")
    all_components = data["components"] + data["legacy_components"]
    if not all(isinstance(value, list) for value in (data["components"], data["legacy_components"], data["reviews"])):
        raise MapError("component, legacy, and review collections must be arrays")
    ids: dict[str, dict] = {}
    for component in all_components:
        if not isinstance(component, dict) or tuple(component) != COMPONENT_KEYS:
            raise MapError("component fields/order is invalid")
        component_id = component["id"]
        if not isinstance(component_id, str) or not ID_RE.fullmatch(component_id) or component_id in ids:
            raise MapError(f"invalid or duplicate component ID: {component_id!r}")
        if component["platform"] != component_id.split(".", 1)[0] or component["kind"] not in KINDS:
            raise MapError(f"invalid platform or kind for {component_id}")
        if not isinstance(component["semantic_name"], str) or not component["semantic_name"]:
            raise MapError(f"invalid semantic_name for {component_id}")
        if component["parent"] is not None and not isinstance(component["parent"], str):
            raise MapError(f"invalid parent for {component_id}")
        if not isinstance(component["canonical_path"], str) or not component["canonical_path"]:
            raise MapError(f"invalid canonical_path for {component_id}")
        if not isinstance(component["presentation"], str) or not isinstance(component["repetition"], (str, type(None))):
            raise MapError(f"invalid presentation or repetition for {component_id}")
        if not isinstance(component["order"], int) or isinstance(component["order"], bool) or component["order"] < 1:
            raise MapError(f"invalid order for {component_id}")
        for key in ("aliases", "related_components", "states"):
            if not isinstance(component[key], list) or not all(isinstance(v, str) and v for v in component[key]):
                raise MapError(f"{component_id}.{key} must be a string array")
        resources = component["resources"]
        if not isinstance(resources, dict) or tuple(resources) != RESOURCE_KEYS:
            raise MapError(f"resource categories/order is invalid for {component_id}")
        for key, values in resources.items():
            if not isinstance(values, list) or not all(isinstance(v, str) and v for v in values):
                raise MapError(f"{component_id}.resources.{key} must be a string array")
            if len(values) != len(set(values)):
                raise MapError(f"{component_id}.resources.{key} must not contain duplicates")
            if key not in ("accessibility_ids", "localization"):
                for path in values:
                    safe_path(path)
        ids[component_id] = component
    siblings: dict[tuple[str, str, str | None], list[int]] = {}
    reachable_ids = {component["id"] for component in data["components"]}
    for component in all_components:
        component_id = component["id"]
        parent = component["parent"]
        if parent is not None and parent not in ids:
            raise MapError(f"dangling parent {parent} in {component_id}")
        if parent is not None and ids[parent]["platform"] != component["platform"]:
            raise MapError(f"cross-platform parent in {component_id}")
        expected = component["semantic_name"] if parent is None else f"{ids[parent]['canonical_path']}/{component['semantic_name']}"
        if component["canonical_path"] != expected:
            raise MapError(f"inconsistent canonical_path for {component_id}: expected {expected!r}")
        collection = "reachable" if component_id in reachable_ids else "legacy"
        siblings.setdefault((collection, component["platform"], parent), []).append(component["order"])
        for related in component["related_components"]:
            if related not in ids:
                raise MapError(f"dangling relationship {related} in {component_id}")
    for (_, _, parent), orders in siblings.items():
        if sorted(orders) != list(range(1, len(orders) + 1)):
            raise MapError(f"orders below {parent or '<root>'} must be unique and contiguous")
    previous_id = ""
    for review in data["reviews"]:
        if not isinstance(review, dict) or tuple(review) != ("id", "reason", "paths", "result"):
            raise MapError("review fields/order is invalid")
        review_id = review["id"]
        if not isinstance(review_id, str) or not REVIEW_RE.fullmatch(review_id) or review_id <= previous_id:
            raise MapError("review IDs must be unique, stable, and increasing")
        if not isinstance(review["reason"], str) or len(review["reason"].strip()) < 12:
            raise MapError(f"review {review_id} needs a concise reason")
        paths = review["paths"]
        if not paths or paths != sorted(set(paths)):
            raise MapError(f"review {review_id} paths must be nonempty, unique, and sorted")
        for path in paths:
            safe_path(path, must_exist=False)
        if review["result"] != "no-component-impact":
            raise MapError(f"review {review_id} has invalid result")
        previous_id = review_id
    if canonical_text is not None and canonical_text != canonical(data):
        raise MapError(f"{source or 'map'} is not canonical JSON (two-space indentation and final newline required)")


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise MapError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout


def map_at_ref(base: str, relative_map: str) -> dict | None:
    result = subprocess.run(["git", "show", f"{base}:{relative_map}"], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise MapError(f"base map is malformed: {error}") from error


def check_change_data(old: dict | None, new: dict, changed_paths: list[str], map_path: str) -> str:
    validate_data(new)
    if old is None:
        return "bootstrap feature-map creation"
    validate_data(old)
    if old["components"] != new["components"] or old["legacy_components"] != new["legacy_components"]:
        if old["reviews"] != new["reviews"]:
            raise MapError("component-impacting changes must not also alter review records")
        return "component mappings changed"
    old_reviews, new_reviews = old["reviews"], new["reviews"]
    if len(new_reviews) != len(old_reviews) + 1 or new_reviews[:-1] != old_reviews:
        raise MapError("no-impact changes must append exactly one record; existing reviews are immutable")
    expected = sorted(path for path in changed_paths if path != map_path)
    if new_reviews[-1]["paths"] != expected:
        raise MapError(f"review paths are stale; expected {expected!r}")
    return f"no-component-impact review {new_reviews[-1]['id']} matches the PR diff"


def command_validate(args: argparse.Namespace) -> None:
    path = Path(args.map).resolve()
    data = load(path)
    schema = load(SCHEMA)
    validate_schema(data, schema, schema)
    validate_data(data, source=path, canonical_text=path.read_text(encoding="utf-8"))
    print(f"valid: {path.relative_to(ROOT)} ({len(data['components'])} reachable, {len(data['legacy_components'])} legacy)")


def command_query(args: argparse.Namespace) -> None:
    data = load(Path(args.map).resolve())
    validate_data(data)
    matches = query_matches(data, args.term)
    if not matches:
        raise MapError(f"no component matches {args.term!r}")
    if len(matches) > 1:
        raise MapError("ambiguous component: " + ", ".join(sorted(c["id"] for c in matches)))
    print(json.dumps(matches[0], ensure_ascii=False, indent=2))


def query_matches(data: dict, term: str) -> list[dict]:
    needle = term.casefold()
    components = data["components"] + data["legacy_components"]
    exact = [component for component in components if component["id"].casefold() == needle]
    return exact or [
        component for component in components
        if component["semantic_name"].casefold() == needle
        or needle in [alias.casefold() for alias in component["aliases"]]
    ]


def command_check(args: argparse.Namespace) -> None:
    path = Path(args.map).resolve()
    relative = path.relative_to(ROOT).as_posix()
    new = load(path)
    old = map_at_ref(args.base, relative)
    changed = [line for line in git("diff", "--name-only", f"{args.base}...HEAD").splitlines() if line]
    print("fresh: " + check_change_data(old, new, changed, relative))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--map", default=str(DEFAULT_MAP))
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    query = sub.add_parser("query"); query.add_argument("term")
    check = sub.add_parser("check-change"); check.add_argument("--base", required=True)
    args = parser.parse_args()
    try:
        {"validate": command_validate, "query": command_query, "check-change": command_check}[args.command](args)
        return 0
    except (MapError, ValueError) as error:
        print(f"feature-map: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
