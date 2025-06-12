#!/usr/bin/env python3.12
"""
Generate a registry.json of all ebuilds under an overlay,
annotated with category, name, version, inherited eclasses and inferred language,
then group the results by package name with sorted versions.
"""

import argparse
import json
import logging
import re
from pathlib import Path
from packaging.version import parse as parse_version  # pip install packaging

# —————————————————————————————————————————————————————————————————————————
# Regex to match “name-version.ebuild” and capture name & version
EBUILD_RE = re.compile(r"^(?P<name>.+)-(?P<version>[0-9][^/]*)\.ebuild$")

# Map eclasses → language
ECLASS_LANGUAGES: dict[str, str] = {
    "go-module": "go",
    "python-r1": "python",
    "python-single-r1": "python",
    "cargo": "rust",
    "cmake": "cpp",
    "meson": "cpp",
}


def get_eclasses(path: Path) -> list[str]:
    """Read an ebuild and pull out every inherited eclass."""
    text = path.read_text(encoding="utf-8")
    eclasses: set[str] = set()
    for line in text.splitlines():
        line = line.strip()
        match line.split():
            case ["inherit", *cls]:
                eclasses.update(cls)
            case _:
                continue
    return sorted(eclasses)


def extract_metadata(path: Path, root: Path) -> dict | None:
    """
    Given a full path to an .ebuild, return its metadata dict or None
    if it doesn't conform to <root>/<category>/<pkg>/<name>-<ver>.ebuild.
    """
    rel = path.relative_to(root).parts
    match rel:
        case [*_, category, _, filename] if filename.endswith(".ebuild"):
            pass
        case _:
            return None

    if not (m := EBUILD_RE.match(filename)):
        return None

    name, version = m.group("name", "version")
    ecls = get_eclasses(path)
    language = next((ECLASS_LANGUAGES[e] for e in ecls if e in ECLASS_LANGUAGES), None)

    return {
        "category": category,
        "name": name,
        "version": version,
        "eclasses": ecls,
        "language": language,
    }


def scan(root: Path) -> list[dict]:
    """Walk the tree, extract metadata, and return a sorted list."""
    entries = (
        meta
        for p in root.rglob("*.ebuild")
        if (meta := extract_metadata(p, root)) is not None
    )
    return sorted(entries, key=lambda e: (e["category"], e["name"], e["version"]))


def group_by_name(entries: list[dict]) -> list[dict]:
    """Group flat metadata entries by package name and sort versions."""
    pkgs: dict[str, dict] = {}
    for e in entries:
        nm = e["name"]
        if nm not in pkgs:
            pkgs[nm] = {
                "name": nm,
                "category": e["category"],
                "eclasses": e["eclasses"],
                "language": e["language"],
                "versions": [],
            }
        pkgs[nm]["versions"].append(e["version"])

    for pkg in pkgs.values():
        pkg["versions"].sort(key=parse_version)

    return sorted(pkgs.values(), key=lambda p: p["name"])


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "root", type=Path, nargs="?", default=Path.cwd(), help="Overlay root directory"
    )
    p.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("registry.json"),
        help="Output JSON file",
    )
    p.add_argument("-v", "--verbose", action="store_true", help="Enable debug logging")
    args = p.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    flat = scan(args.root)
    grouped = group_by_name(flat)
    args.output.write_text(json.dumps(grouped, sort_keys=True), encoding="utf-8")
    logging.info(f"Wrote {len(grouped)} package groups to {args.output}")


if __name__ == "__main__":
    main()
