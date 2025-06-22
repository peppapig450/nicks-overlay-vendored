#!/usr/bin/env bash
# ==============================================================================
# create-release.sh — Create a GitHub release with appropriate notes
#
# This script creates a GitHub release for a vendored tarball with release notes
# that indicate whether it was a preemptive build or vendored build.
#
# Usage:
#   ./create-release.sh <tarball_path> <name> <tag> <vcs> <build_type>
#
# Example:
#   ./create-release.sh glow-v1.2.3-deps.tar.xz glow v1.2.3 https://github.com/charmbracelet/glow.git preemptive
#
# Requirements:
#   - gh (GitHub CLI)
#   - GITHUB_TOKEN environment variable
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
  logging::init "${BASH_SOURCE[0]}"
else
  printf "Something went wrong sourcing the logging lib: %s\n" "${LOGGING_PATH}" >&2
  exit 1
fi

usage() {
  cat <<RELEASE_THE_KRAKEN
Usage: $(basename "${0}") <tarball_path> <name> <tag> <vcs> <build_type>

    tarball_path    Path to the built tarball
    name            Package name
    tag             Version tag (e.g., v1.2.3)
    vcs             Upstream VCS URL
    build_type      Either 'vendored' or 'preemptive'

Environment:
  GITHUB_TOKEN       GitHub token for API access
  GITHUB_REPOSITORY  Repository in owner/repo format

RELEASE_THE_KRAKEN
  exit 1
}

# Validate required environment variables
check_environment() {
  local -a required_vars=(GITHUB_TOKEN GITHUB_REPOSITORY)

  for var in "${required_vars[@]}"; do
    if [[ -z ${!var:-} ]]; then
      logging::log_fatal "Required environment variable not set: ${var}"
    fi
  done
}

# These functions write build-type-specific release notes to a file descriptor.
#
# Instead of passing the descriptor around and redirecting each individual `echo` or `cat`,
# we redirect the entire function output using `} >&${fd}`.
#
# This syntax applies the redirection to the **entire compound command** (the function body).
# It must appear **after** the closing brace.
#
# Note: `${fd}` must be assigned and open before these functions are defined.
# If not, Bash will fail to parse or write to an undefined descriptor.
#
# Why this way?
# - Cleaner function bodies (no `>&${fd}` clutter inside)
# - Easier to read and maintain (especially for multiple lines/heredocs)
# - Bash supports it (surprisingly!)
#
# This is legal Bash, if you don't believe me read the FUNCTIONS section of the
# manpage.
write_preemptive_notes() {
  cat <<'FAST_AND_CURIOUS'
**Preemptive Build**

This tarball was built preemptively and may not yet be available in the ebuild repository.
This allows for faster ebuild creation when adding new packages or versions.

Once the corresponding ebuild is created and added to the overlay, this becomes a standard
vendored release.
FAST_AND_CURIOUS
} >&${fd}

write_vendored_notes() {
  cat <<'DEAR_PORTAGE'
**Vendored Build**

This tarball corresponds to a version that exists in the ebuild repository and has been
automatically built to provide vendored dependencies.
DEAR_PORTAGE
} >&${fd}

# Generate release notes based on build type
generate_release_notes() {
  local name="${1}"
  local tag="${2}"
  local vcs="${3}"
  local build_type="${4}"
  local notes_file="${5}"

  # Open notes file for writing with a file descriptor
  exec {fd}>>"${notes_file}"

  # Base release notes
  printf "Vendored release for %s version %s\n\n" "${name}" "${tag}" >&${fd}
  printf "Upstream repository: %s\n\n" "${vcs}" >&${fd}

  # Add-on more notes based on build-type
  case "${build_type}" in
    preemptive)
      write_preemptive_notes # ${fd} is inferred from scope
      ;;
    vendored)
      write_vendored_notes
      ;;
    *)
      logging::log_warn "Unknown build type: ${build_type}. Using generic notes."
      printf "Build type: %s\n" "${build_type}" >&${fd}
      ;;
  esac

  # Use printf with strftime-style formatting (%(... )T) to insert current UTC timestamp
  printf "\n---\nGenerated: %(%Y-%m-%d %H:%M:%S UTC)T\n" >&${fd}

  # Close the file descriptor since we're done
  exec {fd}>&-
}

create_github_release() {
  local tarball_path="${1}"
  local name="${2}"
  local tag="${3}"
  local build_type="${4}"
  local notes_file="${5}"

  local release_tag="${name}-${tag}"
  local title="[${build_type}] ${name} ${tag}"

  logging::log_info "Creating release: ${release_tag}"

  gh release create "${release_tag}" \
    --repo "${GITHUB_REPOSITORY}" \
    --title "${title}" \
    --notes-file "${notes_file}" \
    --target "${GITHUB_SHA:-HEAD}" \
    "${tarball_path}"
}

main() {
  if (($# != 5)); then
    logging::log_error "Invalid number of arguments: $#"
    usage
  fi

  local tarball_path="${1}"
  local name="${2}"
  local tag="${3}"
  local vcs="${4}"
  local build_type="${5}"

  # Validate inputs
  if [[ ! -f ${tarball_path} ]]; then
    logging::log_fatal "Tarball not found: ${tarball_path}"
  fi

  if [[ ! ${build_type} =~ ^(vendored|preemptive)$ ]]; then
    logging::log_fatal "Invalid build_type: ${build_type}. Must be 'vendored' or 'preemptive'"
  fi

  # Check environment
  check_environment

  # Generate release notes
  local notes_file
  notes_file="$(mktemp release_notes.txt.XXXXXX)"

  generate_release_notes "${name}" "${tag}" "${vcs}" "${build_type}" "${notes_file}"

  # Create the release
  create_github_release "${tarball_path}" "${name}" "${tag}" "${build_type}" "${notes_file}"

  # Cleanup
  rm -f -- "${notes_file}"

  logging::log_info "Release created successfully: ${name}-${tag}"
}

if ! (return 0 2>/dev/null); then
  main "$@"
fi
