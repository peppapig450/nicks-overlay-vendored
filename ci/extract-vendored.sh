#!/usr/bin/env bash
# ==============================================================================
# extract-vendored.sh — List vendored versions for a given language from ebuild
# registry
#
# Given an ebuild_registry.json file (generated from an overlay scan), this script
# filters the packages that match a specified language and prints each version in
# the form:
#   name-version
#
# Usage:
#   ./extract-vendored.sh ebuild_registry.json go
#
# Output:
#   cli-v2.74.0
#   glow-v2.1.1
#
# Requirements:
#   - bash
#   - jq
# ==============================================================================
set -Eeuo pipefail

# Resolve path to this script (even if it's symlinked)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to the logging library
LOGGING_PATH="${SCRIPT_DIR}/../scripts/lib/logging.sh"

# Check and source the logging library
if [[ -f ${LOGGING_PATH} ]]; then
  # shellcheck source=../scripts/lib/logging.sh
  source "${LOGGING_PATH}"
else
  printf "Something went wrong sourcing the logging lib: %s\n" "${LOGGING_PATH}" >&2
  exit 1
fi

extract_versions() {
  local registry_file="${1}"
  local lang="${2}"

  jq -r --arg lang "$lang" '
    .[]
    | select(.language == $lang)
    | .name as $n
    | .versions[]
    | select(. != "9999")
    | "\($n)-\(.)"
    ' "$registry_file"
}

main() {
    if (( $# != 2 )); then
        logging::log_fatal "Usage: $(basename "$0") <ebuild_registry.json> <language>"
    fi

    local registry="${1}"
    local lang="${2@L}"
    local -a versions=()

    if [[ ! -r ${registry} ]]; then
        logging::log_error "${registry} is not a readable file"
        return 1
    fi

    mapfile -t versions < <(extract_versions "${registry}" "${lang}")
    (( ${#versions[@]} )) || logging::error "No versions for language: ${lang} were parsed from the registry: ${registry}"

    printf '%s\n' "${versions[@]}"
}

if ! (return 0 2>/dev/null); then
  main "$@"
fi