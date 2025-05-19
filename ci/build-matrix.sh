#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<INTO_THE_MATRIX_NEO
Usage: $(basename "${0}") <configs.json> <released_tags.txt>
  configs.json       JSON array of { name, repo, vcs } objects
  released_tags.txt  One tag per line (already-released)
INTO_THE_MATRIX_NEO
  exit 1
}

parse_args() {
  (( $# == 2 )) || { echo "ERROR: invalid number of args passed" >&2; usage; }
  declare -g CONFIG_FILE="${1}"
  declare -g RELEASED_FILE="${2}"

  [[ -f ${CONFIG_FILE} ]] || { echo "ERROR: missing ${CONFIG_FILE}"  >&2; usage; }
  [[ -f ${RELEASED_FILE} ]] || { echo "ERROR: missing ${RELEASED_FILE}" >&2; usage; }
}

load_released_tags() {
  declare -gA RELEASED

  while IFS=$'\n' read -r tag; do
    [[ -n ${tag} ]] && RELEASED["${tag}"]=1
  done < "${RELEASED_FILE}"
}

# fetch all tags from a git repo
get_remote_tags() {
  local vcs_url="${1}"

  git ls-remote --tags -- "${vcs_url}" \
    | perl -ne 'print "$1" if /refs\/tags\/([^\^}]+)/'
}

# process one module, append new entries to matrix_entries[]
process_module() {
  declare -ga MATRIX_ENTRIES

  local name="${1}" repo="${2}" vcs="${3}"
  echo "[INFO] Checking tags for ${name}"

  # read remote tags into an array
  mapfile -t tags < <(get_remote_tags "${vcs}")
  for tag in "${tags[@]}"; do
    [[ -z ${tag} ]] && continue
    if [[ -z ${released[${tag}]:-} ]]; then
      MATRIX_ENTRIES+=("$(
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
  while IFS=$'\t' read -r name repo vcs; do
    [[ -z $name || -z $repo || -z $vcs ]] && {
      echo "[WARN] Skipping incomplete line: $name | $repo | $vcs" >&2
      continue
    }
    process_module "${name}" "${repo}" "${vcs}"
  done < <(
    jq -r '.[] | [.name, .repo, .vcs] | @tsv' "${CONFIG_FILE}"
  )
}

# Entry point
main() {
  # Parse and validate args
  parse_args "$@"

  # Load already downloaded release tags
  load_released_tags

  # Build matrix json array
  build_matrix
  printf '%s\n' "${MATRIX_ENTRIES[@]}" | jq -s .
}

# Make sure main is only ran if executed and not
# if it is sourced.
if ! (return 0 2>/dev/null); then
  main "$@"
fi
