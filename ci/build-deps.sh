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
#   - Uses custom logging library (logging.sh)
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
# See also: ../scripts/lib/logging.sh
# ==============================================================================
set -Eeuo pipefail

# Resolve path to this script (even if it's symlinked)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to the logging library
LOGGING_PATH="${SCRIPT_DIR}/../scripts/lib/logging.sh"

# Check and source the logging library
if [[ -f "${LOGGING_PATH}" ]]; then
  # shellcheck source=../scripts/lib/logging.sh
  source "${LOGGING_PATH}"
else
  printf "Something went wrong sourcing the logging lib: %s\n" "${LOGGING_PATH}" >&2
  exit 1
fi

# Required stuff for this build should be installed but we check anyway
REQUIRED_CMDS=(jq git tar xz go)

usage() {
  cat <<FIXIT_FELIX
Usage: $(basename "${BASH_SOURCE[0]}")

Expects config JSON on stdin.
FIXIT_FELIX
  exit 2
}

# Use logging lib to setup fatal trap
trap 'logging::trap_err_handler' ERR

# Verifies that our commands are available on path and our environment is correct
check_requirements() {
  for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      logging::log_fatal "Missing required command: ${cmd}"
    fi
  done
}

# Extracts a required field from JSON or logs and exits
parse_field_or_die() {
  local key="${1}"
  local json="${2}"
  local value

  if ! value="$(jq -er ".${key}" <<<"${json}" 2>/dev/null)"; then
    logging::log_error "'${key}' missing in config"
    return 3
  fi

  printf "%s" "${value}"
}

# Reads config JSON from FD 3 and extracts required fields (name, repo, vcs, tag).
# Outputs them as null-delimited strings (for safe array unpacking).
parse_config() {
  local fd="${1}"
  local config_json key value
  local -ar required_keys=(name repo vcs tag)
  local -a values=()
  local -a json_lines

  mapfile -t -u "${fd}" json_lines || {
    logging::log_error "Failed to read config JSON From FD ${fd}"
    return 3
  }

  printf -v config_json "%s\n" "${json_lines[@]}"

  for key in "${required_keys[@]}"; do
    values+=("$(parse_field_or_die "${key}" "${config_json}")")
  done

  printf "%s\0" "${values[@]}"
}

checkout_tag() {
  local name="${1}"
  local repo="${2}"
  local vcs="${3}"
  local tag="${4}"

  logging::log_info "Cloning ${vcs} and checking out tag ${tag}"
  git clone --depth 1 --branch "${tag}" -- "${vcs}" "${name}"
}

download_modules() {
  local name="${1}"

  logging::log_info "Downloading Go modules for ${name}"
  (
    cd "${name}" || exit 1
    env GOMODCACHE="$(pwd)/go-mod" go mod download -modcacherw -x
  )
}

# Ensure the tag matches the v0.0.0 format as this fails otherwise
# XXX: if different version types were to be added more robust version detection is required
check_tag() {
  local tag="${1}"

  if [[ ${tag} =~ ^v[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+$ ]]; then
    printf '%s' "${tag#v}"
  else
    logging::log_error "The specified tag is not supported: ${tag}"
    return 1
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
    logging::log_error "Aborting: invalid tag '${tag}'."
    return 1
  fi

  target="${name}-${version}-deps.tar.xz"
  logging::log_info "Creating tarball ${target}"

  if check_dir_not_empty "${deps_dir}"; then
    tar -C "${name}" -cf - "go-mod" | xz --threads=0 -9e -T0 >"${target}"
    printf '%s' "${target}"
  else
    logging::log_error "Go mod deps download failed, '${deps_dir}' is empty or missing."
    return 1
  fi
}

# Move tarball into working dir and emit the final path
finalize_tarball() {
  local build_dir="${1}"
  local tarball_path="${2}"
  local final_path

  if [[ -z ${tarball_path} ]]; then
    logging::log_fatal "No tarball path provided to 'finalize_tarball'"
    return 1
  fi

  final_path="${PWD}/$(basename "${tarball_path}")"

  if install -m 644 "${build_dir}/${tarball_path}" "${final_path}"; then
    logging::log_info "Tarball moved to working dir: ${final_path}"
    printf '%s\n' "${final_path}"
  else
    logging::log_error "Failed to move tarball to working dir"
    return 1
  fi
}

cleanup() {
  popd >/dev/null || true
  rm -rf -- "${BUILD_DEPS_TMP}"
}

trap 'cleanup' EXIT TERM INT

main() {
  local name repo vcs tag

  # Duplicate stdin to FD 3 for use in subshell
  exec 3<&0

  # Parse command line options passed to script
  mapfile -d '' fields < <(parse_config 3)
  ((${#fields[@]} == 4)) || {
    logging::log_error "Invalid config input: missing fields."
    exit 2
  }

  name="${fields[0]}"
  repo="${fields[1]}"
  vcs="${fields[2]}"
  tag="${fields[3]}"

  # Close file descriptor
  exec 3<&-

  logging::log_info "Building Go dependency tarball for ${name} at tag ${tag}"

  # Create temporary working directory
  build_deps_tmp="$(mktemp -d build-deps-XXXX)"
  BUILD_DEPS_TMP="${build_deps_tmp}"

  pushd "${BUILD_DEPS_TMP}" >/dev/null || {
    logging::log_error "Failed to enter ${BUILD_DEPS_TMP}"
    exit 1
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
    logging::log_error "Failed to create tarball for ${name} @ ${tag}"
    exit 1
  fi

  popd >/dev/null

  # Move the tarball to current working directory
  tarball_path="$(finalize_tarball "${BUILD_DEPS_TMP}" "${tarball_path}")"
  logging::log_info "Build completed: ${tarball_path}"

  # Output the path to STDOUT so that the workflow can read it
  printf "%s\n" "${tarball_path}"
}

# Only run if we're source free!
if ! (return 0 2>/dev/null); then
  main "$@"
fi
