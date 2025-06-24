#!/usr/bin/env bash
# ==============================================================================
# build-deps.sh — Build vendored Go dependency tarball for a given module tag
#
# This script is meant to be invoked from CI or automation. It reads a JSON
# config (from stdin) describing a Go module to build (name, repo, vcs, tag),
# checks out the repo at the specified tag, downloads its Go dependencies,
# and packages them into a compressed tarball.
#
# Output: the tarball filename (stdout)
#
# Behavior:
#   - Uses custom logging library (logging.lib.sh)
#   - Exits on errors with detailed log messages
#   - Requires jq, git, tar, xz, go to be installed
#   - Ensures Go mod cache is non-empty before packaging
#
# Meant to be sourced for testing or invoked directly by CI (e.g., GitHub Actions)
#
# Example:
#   jq -n --arg name foo --arg repo myorg/foo --arg vcs https://github.com/myorg/foo.git --arg tag v1.2.3 \
#     '{name: $name, repo: $repo, vcs: $vcs, tag: $tag}' \
#     | ./ci/build-deps.sh
#
# See also: ../scripts/lib/logging.lib.sh
# ==============================================================================
set -Eeuo pipefail

# Resolve path to this script (even if it's symlinked)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to the logging library
LOGGING_PATH="${SCRIPT_DIR}/../scripts/lib/logging.lib.sh"

# Check and source the logging library
if [[ -f ${LOGGING_PATH} ]]; then
  # shellcheck source=../scripts/lib/logging.lib.sh
  source "${LOGGING_PATH}"
  logging::init "${BASH_SOURCE[0]}"
else
  printf "Something went wrong sourcing the logging lib: %s\n" "${LOGGING_PATH}" >&2
  exit 1
fi

usage() {
  cat << FIXIT_FELIX
Usage: $(basename "${BASH_SOURCE[0]}")

Expects config JSON on stdin.
FIXIT_FELIX
  exit 2
}

# Verifies that our commands are available on path and our environment is correct
check_requirements() {
  # Required stuff for this build should be installed but we check anyway
  local -a required_cmds=(jq git tar xz go)

  for cmd in "${required_cmds[@]}"; do
    if ! command -v "${cmd}" &> /dev/null; then
      logging::log_fatal "Missing required command: ${cmd}"
    fi
  done

  if ! tar --warning=no-unknown-keyword -cf - /dev/null &> /dev/null; then
    logging::log_fatal "GNU tar not installed. Please install and try again."
  fi
}

# Extracts a required field from JSON or logs and exits
parse_field_or_die() {
  local key="${1}"
  local json="${2}"
  local value

  if ! value="$(jq -er ".${key}" <<< "${json}" 2> /dev/null)"; then
    logging::log_error "'${key}' missing in config"
    return 3
  fi

  printf "%s" "${value}"
}

# Reads config JSON from an FD and sets the passed nameref variables directly.
# Usage: parse_config fd name_var repo_var vcs_var tag_var
parse_config() {
  local fd="${1}"
  local -A key_to_var=(
    [name]="${2}"
    [repo]="${3}"
    [vcs]="${4}"
    [tag]="${5}"
  )
  # NOTE: in the future if we need to parse more variables from json we can swap
  # to using a generalized approach: shifting after assigning fd and then using a
  # loop to dynamically build the mapping.

  local config_json key
  local -a json_lines
  mapfile -t -u "${fd}" json_lines || {
    logging::log_error "Failed to read config JSON from FD: ${fd}"
    return 3
  }

  printf -v config_json "%s\n" "${json_lines[@]}"

  for key in "${!key_to_var[@]}"; do
    var_name="${key_to_var[${key}]}"
    local -n ref="${var_name}"
    ref="$(parse_field_or_die "${key}" "${config_json}")"
  done
}

checkout_tag() {
  local name="${1}"
  local repo="${2}"
  local vcs="${3}"
  local tag="${4}"

  logging::log_info "Cloning ${vcs} and checking out tag ${tag}"
  git clone \
    --depth 1 \
    --branch "${tag}" \
    --recurse-submodules \
    --shallow-submodules \
    -- "${vcs}" "${name}"
}

download_modules() {
  local name="${1}"

  logging::log_info "Downloading Go modules for ${name}"
  (
    cd -P -- "${name}" || exit 1
    env GOMODCACHE="${PWD}/go-mod" go mod download -modcacherw -x
  )
}

# Ensure the tag matches the v0.0.0 format as this fails otherwise
# XXX: if different version types were to be added more robust version detection is required
check_tag() {
  local tag="${1}"

  if [[ ${tag} =~ ^v[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+$ ]]; then
    printf "%s" "${tag#v}"
  else
    logging::log_fatal "The specified tag is not supported: ${tag}"
  fi
}

# Returns success if the given directory exists and contains at least one entry.
# Uses 'compgen -G' to safely test for matching files without invoking external commands.
# Note: compgen -G expands globs and prints matches without breaking on filenames with spaces.
check_dir_not_empty() {
  local dir="${1}"
  [[ -d ${dir} ]] && compgen -G "${dir}/"\* | read -r
}

# Packages the go-mod directory into a compressed tarball.
# Returns the tarball filename on success.
create_tarball() {
  local name="${1}"
  local tag="${2}"
  local deps_dir="${name}/go-mod"
  local version target

  if ! version="$(check_tag "${tag}")"; then
    logging::log_fatal "Aborting: invalid tag '${tag}'"
  fi

  target="${name}-${version}-deps.tar.xz"
  logging::log_info "Creating tarball ${target}"

  if check_dir_not_empty "${deps_dir}"; then
    tar \
      --mtime="1989-01-01" \
      --sort=name \
      -C "${name}" -cf - "go-mod" | xz --threads=0 -9e -T0 > "${target}"
    printf '%s' "${target}"
  else
    logging::log_fatal "Go mod deps download failed, '${deps_dir}' is empty or missing."
  fi
}

# Move tarball into working dir and emit the final path
finalize_tarball() {
  local build_dir="${1}"
  local tarball_path="${2}"
  local final_path

  if [[ -z ${tarball_path} ]]; then
    logging::log_fatal "No tarball path provided to 'finalize_tarball'"
  fi

  final_path="${PWD}/$(basename "${tarball_path}")"

  if install -m 644 "${build_dir}/${tarball_path}" "${final_path}"; then
    logging::log_info "Tarball moved to working dir: ${final_path}"
    printf '%s\n' "${final_path}"
  else
    logging::log_fatal "Failed to move tarball to working dir"
  fi
}

main() {
  local name repo vcs tag

  # Duplicate stdin to an automatically assigned file descriptor for use in
  # subshell, this is necessary because process substitution does not respect
  # the main scripts stdin.
  exec {fd}<&0

  # Parse command line options passed to script
  parse_config "${fd}" name repo vcs tag

  # Close file descriptor
  exec {fd}<&-

  logging::log_info "Building Go dependency tarball for ${name} at tag ${tag}"

  # Create temporary working directory
  build_deps_tmp="$(mktemp -d build-deps-XXXXXX)"

  _cleanup() {
    local name="${1:-}"
    [[ -n ${name} ]] && rm -rf -- "${name}"
  }

  trap "_cleanup ${build_deps_tmp@Q}" EXIT TERM INT

  pushd "${build_deps_tmp}" > /dev/null || {
    logging::log_fatal "Failed to enter ${build_deps_tmp}"
  }

  # Checkout release tag
  checkout_tag "${name}" "${repo}" "${vcs}" "${tag}"

  # Download Go modules
  download_modules "${name}"

  # Create tarball of modules
  local tarball_path
  if tarball_path="$(create_tarball "${name}" "${tag}")"; then
    :
  else
    logging::log_fatal "Failed to create tarball for ${name} @ ${tag}"
  fi

  popd > /dev/null

  # Move the tarball to current working directory
  tarball_path="$(finalize_tarball "${build_deps_tmp}" "${tarball_path}")"
  logging::log_info "Build completed: ${tarball_path}"

  # Output the path to STDOUT so that the workflow can read it
  printf "%s\n" "${tarball_path}"
}

# Only run if we're source free!
if ! (return 0 2> /dev/null); then
  main "$@"
fi
