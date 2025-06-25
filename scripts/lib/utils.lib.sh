#!/usr/bin/env bash
set -Eeuo pipefail
# ==============================================================================
# utils.lib.sh — Utility functions for Bash scripting
#
# This library provides reusable helper functions used across CI scripts and
# Bash tooling. It encapsulates common operations like version parsing and
# dynamic sourcing of dependency scripts.
#
# Features:
#   - `utils::load_or_die` — Dynamically locate and source a library by name,
#                            with strict error handling and fuzzy search.
#   - `utils::extract_version` — Extract semver (X.Y.Z) components from a tag.
#
# This file is intended to be sourced. Not executable on its own.
# ==============================================================================

# Bail out if we're not being sourced
(return 0 2> /dev/null) || {
  printf "This script is meant to be sourced, not executed." >&2
  exit 1
}

# utils::load_or_die <filename> [label]
#
# Searches recursively under UTILS_LIB_ROOT for a file named <filename> and
# sources it. If not found or multiple matches are found, logs an error and exits.
#
# Arguments:
#   filename  — Basename of the file to source (e.g., logging.lib.sh)
#   label     — Optional human-friendly label for error messages
#
# Environment:
#   UTILS_LIB_ROOT — Optional. Root directory to start searching under.
#                    Defaults to sibling lib/ relative to the calling script.
utils::load_or_die() {
  local lib_name="$1"
  local label="${2:-${lib_name}}"
  local search_root="${UTILS_LIB_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")/.." && pwd)/lib}"

  shopt -s nullglob globstar
  trap 'shopt -u nullglob globstar' RETURN

  local -a matches
  mapfile -t matches < <(compgen -G "${search_root}/**/${lib_name}")

  if ((${#matches[@]} == 1)); then
    # shellcheck source=/dev/null
    source "${matches[0]}"
  elif ((${#matches[@]} == 0)); then
    printf "Could not find %s in %s\n" "$label" "$search_root" >&2
    exit 1
  else
    printf "Multiple matches found for %s in %s:\n" "$label" "$search_root" >&2
    printf -- " - %s\n" "${matches[@]}" >&2
    exit 1
  fi
}

# Extracts semver-like X.Y.Z from a tag string.
# If no match is found, returns 1.
utils::extract_version() {
  local tag="$1"

  if [[ ${tag} =~ ([[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+) ]]; then
    printf "%s" "${BASH_REMATCH[1]}"
  else
    logging::log_warn "Could not extract version from tag: ${tag}"
    return 1
  fi
}
