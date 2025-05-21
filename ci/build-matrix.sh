#!/usr/bin/env bash
# ==============================================================================
# build-matrix.sh — Generate a CI matrix from unreleased Git tags
#
# This script reads a JSON config containing module info (name, repo, vcs),
# and compares each module's available Git tags with a list of already-released
# tags. Any unreleased tags are collected into a JSON array suitable for CI.
#
# Input:
#   - configs.json: JSON array of module definitions
#   - released_tags.txt: plain text list of already released tags
#
# Output:
#   - JSON array of unreleased {name, repo, vcs, tag} objects (to stdout)
#
# Usage:
#   ./build-matrix.sh configs.json released_tags.txt > matrix.json
#
# Requires:
#   - bash 4+
#   - jq
#   - git
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

usage() {
  cat <<INTO_THE_MATRIX_NEO
Usage: $(basename "${0}") <configs.json> <released_tags.txt>

  configs.json       JSON array of { name, repo, vcs } objects
  released_tags.txt  One tag per line (already-released)
INTO_THE_MATRIX_NEO
  exit 1
}

# Use logging lib to setup fatal trap
trap 'logging::trap_err_handler' ERR

# Parses the config and validates input arguments.
# Exits if file paths are missing or invalid.
parse_args() {
  (($# == 2)) || {
    logging::log_error "Invalid number of args parsed"
    usage
  }

  local config_file="${1}"
  local released_file="${2}"

  [[ -f ${config_file} ]] || {
    logging::log_error "Missing ${config_file}"
    usage
  }
  [[ -f ${released_file} ]] || {
    logging::log_error "Missing ${released_file}"
    usage
  }

  printf "%s %s\n" "${config_file}" "${released_file}"
}

# Builds an associative array of tags we've already released,
# so we can skip them during matrix generation.
load_released_tags() {
  local array_name="${1}"
  local released_file="${2}"
  declare -n arr="${array_name}"
  arr=()

  while IFS=$'\n' read -r tag; do
    logging::log_info "Found tag: ${tag}"
    [[ -n ${tag} ]] && arr["${tag}"]=1
  done <"${released_file}"
}

# Fetch the latest 3 release tags from a git repo using graphql
# XXX: Maybe add more configurable queries here.
get_release_tags() {
  local repo="${1}"
  local owner="${repo%%/*}"
  local name="${repo##*/}"

  if [[ -z ${owner} || -z ${name} || ${owner} =~ ${repo} ]]; then
    logging::log_error "Invalid repo string: '${repo}'"
    return 1
  fi

  # Define the GraphQL document
  gql="$(
    cat <<-'BASHING_GQL'
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        releases(first: 3) {
          nodes { tagName }
        }
      }
  }
BASHING_GQL
  )"

  # Fire off the request with raw-field (preserves newlines/quotes cleanly)
  gh api graphql \
    -f query="${gql}" \
    -f owner="${owner}" \
    -f name="${name}" \
    | jq -r '.data.repository.releases.nodes[].tagName'
}

# Fetches tags from the remote Git repo and filters out already released ones.
# Appends unreleased entries (as JSON) into the matrix array.
process_module() {
  local name="${1}"
  local repo="${2}"
  local vcs="${3}"
  local released_ref="${4}"
  local matrix_ref="${5}"

  # Use namerefs to mutate the arrays passed by name
  declare -n released="${released_ref}"
  declare -n matrix="${matrix_ref}"

  logging::log_info "Checking tags for ${name}"

  # read remote tags into an array
  mapfile -t tags < <(get_release_tags "${repo}")
  for tag in "${tags[@]}"; do
    check_tag="${name}-${tag}" # Add name to tag to match what's in the released array
    [[ -z ${check_tag} ]] && continue
    if [[ -z ${released["${check_tag}"]:-} ]]; then
      matrix+=("$(
        jq -nc --arg name "${name}" \
          --arg repo "${repo}" \
          --arg vcs "${vcs}" \
          --arg tag "${tag}" \
          '$ARGS.named'
      )")
    fi
  done
}

# iterate over configs.json
build_matrix() {
  local config_file="${1}"
  local released_ref="${2}"
  local matrix_ref="${3}"

  # Use nameref to mutate the release array
  declare -n released="${released_ref}"

  while IFS=$'\t' read -r name repo vcs; do
    [[ -z ${name} || -z ${repo} || -z ${vcs} ]] && {
      logging::log_warn "Skipping incomplete line: ${name} | ${repo} | ${vcs}"
      continue
    }
    process_module "${name}" "${repo}" "${vcs}" "${released_ref}" "${matrix_ref}"
  done < <(
    jq -r '.[] | [.name, .repo, .vcs] | @tsv' "${config_file}"
  )
}

# Entry point
main() {
  # Parse and validate args
  config_args="$(parse_args "$@")"
  read -r config_file released_file <<<"${config_args}"

  declare -A released_tags
  declare -a matrix_entries

  # Load already downloaded release tags
  load_released_tags released_tags "${released_file}"

  # Build matrix json array
  build_matrix "${config_file}" released_tags matrix_entries

  printf '%s\n' "${matrix_entries[@]}" | jq -s -c .
}

# Make sure main is only ran if executed and not
# if it is sourced.
if ! (return 0 2>/dev/null); then
  main "$@"
fi
