#!/usr/bin/env bash
# ==============================================================================
# build-common.lib.sh — Shared vendoring logic for language-specific CI builds
#
# This library script extracts and consolidates common logic used to build
# vendored dependency tarballs, originally implemented in build-deps.sh.
#
# Intended to be sourced by language-specific CI scripts (e.g., Go, Node, etc.)
# that override `override::*` functions to implement language-specific behavior.
#
# Features:
#   - Ensures required tools (jq, git, tar, xz) are installed and validates tar version
#   - Parses module metadata from a JSON config piped via stdin
#   - Checks out a VCS repo at a specified tag
#   - Provides reusable helpers for:
#       * Checking directory contents
#       * Validating tag format
#       * Finalizing tarball location
#   - Provides `common::run_build`, the entry point for orchestrating the build
#
# Usage:
#   1. Must be sourced from a wrapper script that provides:
#        - `override::vendor_dependencies` to perform vendoring
#        - `override::create_tarball` to package the vendored deps
#   2. The wrapper script must source logging.lib.sh and utils.lib.sh *before* this script.
#   3. The wrapper script should then call `common::run_build`
#
# Example:
#   jq -n '{"name":"foo","repo":"myorg/foo","vcs":"https://github.com/myorg/foo.git","tag":"v1.2.3"}' \
#     | ./ci/build-go-deps.sh
#
# This file is not meant to be executed directly.
# ==============================================================================
set -Eeuo pipefail

die() {
  printf "%s\n" "$@" >&2
  exit 1
}

# Bail out if we're not being sourced
(return 0 2> /dev/null) || {
  die "This script is meant to be sourced, not executed."
}

# Make sure that the logging library is available
declare -f logging::init &> /dev/null || {
  die "The logging library (logging.lib.sh) was not sourced, or the sourcing order is wrong.\n \
logging.lib.sh should be sourced BEFORE this script."
}

# Cleanup the now unnecessary `die`
unset -f die

# Verifies that tools needed are installed
common::check_requirements() {
  # This stuff should be installed in the runner, but we check it anyway
  local -a required_cmds=(jq git tar xz)
  local -a missing_cmds=()

  for cmd in "${required_cmds[@]}"; do
    if ! command -v -- "${cmd}" &> /dev/null; then
      missing_cmds+=("${cmd}")
    fi
  done

  if ((${#missing_cmds[@]})); then
    logging::log_fatal "The following tools are not installed: ${missing_cmds[*]}. Please install them."
  fi

  # Make sure default tar is not BSD
  if ! tar --warning=no-unknown-keyword -cf - /dev/null &> /dev/null; then
    logging::log_fatal "GNU tar not installed. Please install and try again."
  fi
}

# Extracts a required field from JSON or logs and exits
parse_field_or_die() {
  local key="$1"
  local json="$2"

  local value
  if ! value="$(jq -er ".${key}" <<< "${json}" 2> /dev/null)"; then
    logging::log_error "'${key}' missing in config"
    return 1
  fi

  printf "%s" "${value}"
}

# Reads config JSON from an FD and sets the passed name-referenced variables directly.
# Usage: parse_config <fd> <name_var> <repo_var> <vcs_var> <tag_var>
common::parse_config() {
  local fd="$1"
  local -A key_to_var=(
    [name]="$2"
    [repo]="$3"
    [vcs]="$4"
    [tag]="$5"
  )
  # NOTE: in the future if we need to parse more variables from json we can swap
  # to using a generalized approach: shifting after assigning fd and then using a
  # loop to dynamically build the mapping.

  # Unset the helper function once this function returns
  trap 'unset -f parse_field_or_die' RETURN

  local -a json_lines
  mapfile -t -u "${fd}" json_lines || {
    logging::log_fatal "Failed to read config JSON from fd: ${fd}"
  }

  local config_json
  printf -v config_json "%s\n" "${json_lines[@]}"

  local key
  for key in "${!key_to_var[@]}"; do
    local var_name="${key_to_var[${key}]}"
    local -n ref="${var_name}"
    if ! ref="$(parse_field_or_die "${key}" "${config_json}")"; then
      logging::log_fatal "Missing field: ${key} in config"
    fi
  done
}

common::checkout_tag() {
  local name="$1"
  local repo="$2"
  local vcs="$3"
  local tag="$4"

  logging::log_info "Cloning ${vcs} into ${name} and checking out tag: ${tag}"
  git clone \
    --depth 1 \
    --branch "${tag}" \
    --recurse-submodules \
    --shallow-submodules \
    -- "${vcs}" "${name}"
}

# Ensure the tag contains a valid version and fail otherwise
# XXX: If semver regex needs to be handled, switch to perl.
common::check_tag() {
  utils::extract_version "$@" || return 1
}

# Returns true if the given directory exists and contains at least one entry.
# Uses 'compgen -G' to safely test for matching files without invoking external commands.
# Note: compgen -G expands globs and prints matches without breaking on filenames with spaces.
common::check_dir_not_empty() {
  local dir="$1"
  [[ -d ${dir} ]] && compgen -G "${dir}/"\* | read -r
}

# Move tarball into working directory and emit the final path
common::finalize_tarball() {
  local build_dir="$1"
  local tarball_path="$2"

  if [[ -z ${tarball_path} ]]; then
    logging::log_fatal "No tarball path provided to 'finalize_tarball'"
  fi

  local final_path
  final_path="${PWD}/$(basename -- "${tarball_path}")"

  if install -m 644 "${build_dir}/${tarball_path}" "${final_path}"; then
    logging::log_info "Tarball moved to working dir at path: ${final_path}"
    printf "%s" "${final_path}"
  else
    logging::log_fatal "Failed to move tarball from path: ${build_dir}/${tarball_path} to working dir: ${final_path}."
  fi
}

# Function to download the dependencies to vendor, this should be overridden in
# sourcing scripts.
override::vendor_dependencies() {
  logging::log_fatal "'override::vendor_dependencies' not overridden"
}

# Package the vendored dependencies into a compressed tarball.
# This should be implemented in the sourcing script.
override::create_tarball() {
  logging::log_fatal "'override::create_tarball' not overridden"
}

# Main orchestrator that is ran inside sourcing scripts to build and package the
# vendor tarball. Implements language specific vendoring based on the sourcing scripts
# implementation of the override::* functions.
common::run_build() {
  local name repo vcs tag

  # Ensure the necessary tools are installed
  common::check_requirements

  # Duplicate stdin to an automatically assigned file descriptor for safe parsing
  # of the JSON configuration piped to the script. This is necessary because subshells
  # and process substitution do not respect the main script's stdin.
  local fd
  exec {fd}<&0

  # Parse command line options passed to the script via nameref
  common::parse_config "${fd}" name repo vcs tag

  # Close file descriptor
  exec {fd}<&-

  logging::log_info "Building vendored tarball for ${name} at ${tag}"

  # Create temporary working directory
  local build_tmp
  build_tmp="$(mktemp -p /tmp -d build-deps-XXXXXX)"

  # Ensure directory is always cleaned up (not really necessary in CI/CD but why not)
  _cleanup() {
    local name="${1:-}"
    [[ -n ${name} ]] && rm -rf -- "${name}"
  }

  # @Q expands the variable and quotes it; equivalent to printf %q
  trap '_cleanup '"${build_tmp@Q}" EXIT TERM INT

  # Pushd is used here because we use the directory over multiple functions
  pushd "${build_tmp}" > /dev/null || {
    logging::log_fatal "Failed to enter ${build_tmp}"
  }

  # Checkout release tag to vendor
  common::checkout_tag "${name}" "${repo}" "${vcs}" "${tag}"

  override::vendor_dependencies "${name}"

  local tarball_path
  if ! tarball_path="$(override::create_tarball "${name}" "${tag}")"; then
    logging::log_fatal "Failed to create tarball for ${name} at ${tag}"
  fi

  popd > /dev/null

  # Move the tarball to the current working directory
  tarball_path="$(common::finalize_tarball "${build_tmp}" "${tarball_path}")"
  logging::log_info "Vendoring completed: ${tarball_path}"

  # Output the path to STDOUT so that the workflow can read it
  printf "%s\n" "${tarball_path}"
}
