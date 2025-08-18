#!/usr/bin/env python3.12
"""Generate a registry.json of all ebuilds under an overlay, annotated with category, name, version,
repo slug, inherited eclasses and inferred language, then group the results by package name with
sorted versions.
"""

import argparse
import json
import logging
import re
from functools import reduce
from pathlib import Path

from packaging.version import (
    InvalidVersion,
    Version,
    parse as parse_version,  # pip install packaging
)


# —————————————————————————————————————————————————————————————————————————
# Regex to match “name-version.ebuild” and capture name & version
EBUILD_RE = re.compile(r"^(?P<name>.+)-(?P<version>[0-9][^/]*)\.ebuild$")

# Regex to extract the upstream Git repository
GITHUB_REPO_RE = re.compile(
    r"https?://github\.com/(?P<owner>[A-Za-z0-9_.-]+)/(?P<repo>[A-Za-z0-9_.-]+)(?:\.git)?/?"
)

# Map eclasses → language
ECLASS_LANGUAGES: dict[str, str] = {
    "go-module": "go",
    "python-r1": "python",
    "python-single-r1": "python",
    "cargo": "rust",
    "cmake": "cpp",
    "meson": "cpp",
}


def safe_version_parse(ver: str) -> Version | str:
    """Parse Gentoo version strings with common suffixes.

    Returns a Version object if parsing succeeds, otherwise returns
    the original string for lexicographic sorting.
    """
    transformations = [(r"_p(\d+)", r".post\1"), (r"_rc", "rc"), (r"_beta", "b")]

    def try_parse(version_str: str):
        try:
            return parse_version(version_str)
        except InvalidVersion:
            return None

    # Try original first, fallback to normalized
    if result := try_parse(ver):
        return result

    # Apply regex transformations one by one
    def apply_transformations(version: str, pattern_replacement: tuple[str, str]) -> str:
        pattern, replacement = pattern_replacement
        return re.sub(pattern, replacement, version)

    normalized = reduce(apply_transformations, transformations, ver)

    return try_parse(normalized) or ver


def get_eclasses(text: str) -> list[str]:
    """Read an ebuild and pull out every inherited eclass."""
    eclasses: set[str] = set()
    for line in text.splitlines():
        current_line = line.strip()
        match current_line.split():
            case ["inherit", *cls]:
                eclasses.update(cls)
            case _:
                continue
    return sorted(eclasses)


def extract_repo_slug(text: str) -> str | None:
    """Extract GitHub owner/repo from HOMEPAGE or SRC_URI."""
    if match := GITHUB_REPO_RE.search(text):
        return f"{match.group('owner')}/{match.group('repo')}"
    return None


def extract_metadata(path: Path, root: Path) -> dict | None:
    """Given a full path to an .ebuild, return its metadata dict or None
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

    text = path.read_text(encoding="utf-8")
    ecls = get_eclasses(text)
    repo = extract_repo_slug(text)
    language = next((ECLASS_LANGUAGES[e] for e in ecls if e in ECLASS_LANGUAGES), None)

    return {
        "category": category,
        "name": name,
        "version": version,
        "eclasses": ecls,
        "language": language,
        "repo": repo,
    }


def scan(root: Path) -> list[dict]:
    """Walk the tree, extract metadata, and return a sorted list."""
    entries = (
        meta for p in root.rglob("*.ebuild") if (meta := extract_metadata(p, root)) is not None
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
                "repo": e["repo"],
                "versions": [],
            }
        pkgs[nm]["versions"].append(e["version"])

    for pkg in pkgs.values():
        pkg["versions"].sort(key=safe_version_parse)

    return sorted(pkgs.values(), key=lambda p: p["name"])


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("root", type=Path, nargs="?", default=Path.cwd(), help="Overlay root directory")
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
