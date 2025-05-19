#!/usr/bin/env bash
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

  if ! value="$(jq -er ".${key}" <<< "${json}" 2>/dev/null)"; then
    logging::log_error "'${key}' missing in config"
    return 3
  fi

  printf "%s" "${value}"
}

# Parse the JSON passed to the script as input
parse_config() {
  local config_json key value
  local -ar required_keys=(name repo vcs tag)
  local -a values=()

  config_json="$(<&3)" || { logging::log_error "Failed to read stdin"; return 3; }

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
  local basedir="${PWD}"

  logging::log_info "Downloading Go modules for ${name}"
  pushd "${name}" > /dev/null
  env GOMODCACHE="${basedir}/go-mod" go mod download -modcacherw -x
  popd > /dev/null
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

# Ensure that the go-mod directory exists and is non-empty
check_dir_not_empty() {
  local dir="${1}"
  [[ -d ${dir} ]] && compgen -G "${dir}/"\* | read -r
}

# Create vendored Go deps tarball
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
      tar -cf - "${deps_dir}" | xz --threads=0 -9e -T0 > "${target}"
      printf '%s' "${target}"
  else
      logging::log_error "Go mod deps download failed, '${deps_dir}' is empty or missing."
      return 1
  fi
}

cleanup() {
  popd > /dev/null || true
  rm -rf -- "${TMPDIR}"
}

trap 'cleanup' EXIT TERM INT

main() {
  local name repo vcs tag

  ## If stdin is empty; exit
  if [[ -t 0 ]]; then
    logging::log_error "STDIN empty. Exiting.."
    usage
  fi

  # Duplicate stdin to FD 3 for use in subshell
  exec 3<&0

  # Parse command line options passed to script
  mapfile -d '' fields < <(parse_config <&3)
  (( ${#fields[@]} == 4 )) || {
    logging::logging_error "Invalid config input: missing fields."
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
  TMPDIR="$(mktemp -d)"

  pushd "${TMPDIR}" > /dev/null

  # Checkout release tag
  checkout_tag "${name}" "${repo}" "${vcs}" "${tag}"

  # Download Go modules
  download_modules "${name}"

  # Create tarball of modules
  local tarball_path
  if tarball_path="$(create_tarball "${name}")"; then
    :
  else
    logging::log_error "Failed to create tarball for ${name} @ ${tag}"
    exit 1
  fi

  popd > /dev/null

  # Move the tarball to current working directory
  mv "${TMPDIR}/${tarball_path}" .

  logging::log_info "Build completed: ${tarball_path}"
}

# Only run if we're source free!
if ! (return 0 2>/dev/null); then
  main "$@"
fi
