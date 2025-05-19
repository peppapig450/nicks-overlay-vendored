#!/usr/bin/env bash
set -Eeuo pipefail

# Required stuff for this build should be installed but we check anyway
REQUIRED_CMDS=(jq git tar xz go)

usage() {
  cat <<FIXIT_FELIX
Usage: $(basename "${BASH_SOURCE[0]}")

Expects config JSON on stdin.
FIXIT_FELIX
  exit 2
}

log() {
  local level="${1}"
  shift
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local color_reset="\033[0m]"
  local color

  case "${level}" in
    INFO) color="\033[0;32m" ;;  # Green!
    WARN) color="\033[0;33m" ;;  # Yellow!
    ERROR) color="\033[0;31m" ;; # Red!
    *)
      printf "Invalid log level: %s\n" "${level}"; exit 1 ;;
  esac

  # Send to stderr like a good log citizen
  printf "%b[%s] [%s] %s%b\n" "${color}" "${ts}" "${level}" "$*" "${color_reset}" >&2
}

log_info()  { log INFO "$@"; }
log_warn()  { log WARN "$@"; }
log_error() { log ERROR "$@"; }
log_fatal() { log ERROR "$@"; exit 1; }

trap 'log_fatal "Unexpected fatal error in ${BASH_SOURCE[0]} on line ${LINENO}: ${BASH_COMMAND}"' ERR

# Verifies that our commands are available on path and our environment is correct
check_requirements() {
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_fatal "Missing required command: ${cmd}"
        fi
    done
}

# Parse the JSON passed to the script as input
parse_config() {
  local config_json name repo vcs tag
  config_json="$(<&3)" || { log_error "Failed to read stdin"; return 3; }

  name="$(jq -er .name <<< "${config_json}")" || { log_error "'name' missing in config"; return 3; }
  repo="$(jq -er .repo <<< "${config_json}")" || { log_error "'repo' missing in config"; return 3; }
  vcs="$(jq -er .vcs <<< "${config_json}")" || { log_error "'vcs' missing in config"; return 3; }
  tag="$(jq -er .tag <<< "${config_json}")" || { log_error "'vcs' missing in config"; return 3; }

  printf "%s\0%s\0%s\0%s\0" "${name}" "${repo}" "${vcs}" "${tag}"
}

checkout_tag() {
  local name="${1}"
  local repo="${2}"
  local vcs="${3}"
  local tag="${4}"

  log_info "Cloning ${vcs} and checking out tag ${tag}"
  git clone --depth 1 --branch "${tag}" -- "${vcs}" "${name}"
}

download_modules() {
  local name="${1}"
  local basedir="${PWD}"

  log_info "Downloading Go modules for ${name}"
  pushd "${name}" > /dev/null
  env GOMODCACHE="${basedir}/go-mod" go mod download -modcachedrw -x
  popd > /dev/null
}

# Ensure the TAG matches the v0.0.0 format as this fails otherwise
# XXX: if different version types were to be added more robust version detection is required
check_tag() {
  local tag="${1}"

  if [[ ${tag} =~ ^v[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+$ ]]; then
    printf '%s' "${tag#v}"
  else
    log_error "The specified TAG is not supported: ${tag}"
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
    log_error "Aborting: invalid tag '${tag}'."
    return 1
  fi

  target="${name}-${version}-deps.tar.xz"
  log_info "Creating tarball ${target}"

  if check_dir_not_empty "${deps_dir}"; then
      tar -cf - "${deps_dir}" | xz --threads=0 -9e -T0 > "${target}"
      printf '%s' "${target}"
  else
      log_error "Go mod deps download failed, '${deps_dir}' is empty or missing."
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
    log_error "STDIN empty. Exiting.."
    usage
  fi

  # Duplicate stdin to FD 3 for use in subshell
  exec 3<&0

  # Parse command line options passed to script
  mapfile -d '' fields < <(parse_config <&3)
  
  name="${fields[0]}"
  repo="${fields[1]}"
  vcs="${fields[2]}"
  tag="${fields[3]}"
  
  # Close file descriptor
  exec 3<&-

  log_info "Building Go dependency tarball for ${name} at tag ${tag}"

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
    log_error "Failed to create tarball for ${name} @ ${TAG}"
    exit 1
  fi
  
  popd > /dev/null

  # Move the tarball to current working directory
  mv "${TMPDIR}/${tarball_path}"

  log_info "Build completed: ${tarball_path}"
}

# Only run if we're source free!
if ! (return 0 2>/dev/null); then
  main "$@"
fi
