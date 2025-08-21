#!/usr/bin/env bash
# ==============================================================================
# create-release.sh — Create a GitHub release with appropriate notes
#
# This script creates a GitHub release for a vendored tarball with release notes
# that indicate whether it was a preemptive build or vendored build.
#
# Usage:
#   ./create-release.sh <tarball_path> <name> <tag> <vcs> <build_type> <language> [crates_tarball]
#
# Example:
#   ./create-release.sh glow-v1.2.3-deps.tar.xz glow v1.2.3 https://github.com/charmbracelet/glow.git preemptive go
#
# Requirements:
#   - gh (GitHub CLI)
#   - GITHUB_TOKEN environment variable
# ==============================================================================
set -Eeuo pipefail

# Resolve path to this script (even if it's symlinked)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to the logging library
LOGGING_PATH="${SCRIPT_DIR}/../scripts/lib/logging/logging.lib.sh"

# Check and source the logging library
if [[ -f ${LOGGING_PATH} ]]; then
  # shellcheck source=../scripts/lib/logging/logging.lib.sh
  source "${LOGGING_PATH}"
  logging::init "${BASH_SOURCE[0]}"
else
  printf "Something went wrong sourcing the logging lib: %s\n" "${LOGGING_PATH}" >&2
  exit 1
fi

usage() {
  cat << RELEASE_THE_KRAKEN
Usage: $(basename "${0}") <tarball_path> <name> <tag> <vcs> <build_type> <language> [crates_tarball]

    tarball_path    Path to the vendored dependency tarball
    name            Package name
    tag             Version tag (e.g., v1.2.3)
    vcs             Upstream VCS URL
    build_type      Either 'vendored' or 'preemptive'
    language        Language of the vendored package (e.g., go, rust)
    crates_tarball  Optional path to crates tarball (Rust only)

Environment:
  GITHUB_TOKEN       GitHub token for API access
  GITHUB_REPOSITORY  Repository in owner/repo format

RELEASE_THE_KRAKEN
  exit 1
}

# Verify our required dependencies are installed.
check_dependencies() {
  local -a dependencies=(gh sha256sum sha512sum b2sum)
  local -a missing_dependencies=()

  for dependency in "${dependencies[@]}"; do
    if ! command -v -- "$dependency" &> /dev/null; then
      missing_dependencies+=("$dependency")
    fi
  done

  if ((${#missing_dependencies[@]})); then
    logging::log_fatal "The following dependencies are not installed: ${missing_dependencies[*]}"
  fi
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

# Compute and write checksum files for the tarball.
compute_checksums() {
  local tarball="$1"
  local -n _checksums="$2"

  local tarball_name
  tarball_name="$(basename -- "$tarball")"

  local -A commands=(
    ["sha256"]="sha256sum"
    ["sha512"]="sha512sum"
    ["blake2"]="b2sum"
  )

  _checksums=(
    ["sha256"]="${tarball_name}.sha256sum"
    ["sha512"]="${tarball_name}.sha512sum"
    ["blake2"]="${tarball_name}.blake2bsum"
  )

  for algo in "${!_checksums[@]}"; do
    cmd="${commands[${algo}]}"
    output_file="${_checksums[${algo}]}"

    "$cmd" -- "$tarball" > "$output_file"
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
  cat << 'FAST_AND_CURIOUS'
**Preemptive Build**

This tarball was built preemptively and may not yet be available in the ebuild repository.
This allows for faster ebuild creation when adding new packages or versions.

Once the corresponding ebuild is created and added to the overlay, this becomes a standard
vendored release.
FAST_AND_CURIOUS
} >&${fd}

write_vendored_notes() {
  cat << 'DEAR_PORTAGE'
**Vendored Build**

This tarball corresponds to a version that exists in the ebuild repository and has been
automatically built to provide vendored dependencies.
DEAR_PORTAGE
} >&${fd}

write_checksum_notes() {
  local label="$1"
  local -n __checksums="$2"
  local sha256_sum sha256_path sha512_sum sha512_path

  IFS=' ' read -r sha256_sum sha256_path < "${__checksums["sha256"]}"
  IFS=' ' read -r sha512_sum sha512_path < "${__checksums["sha512"]}"

  sha256_path="$(basename -- "$sha256_path")"
  sha512_path="$(basename -- "$sha512_path")"

  cat << CHECKMATE

**Checksums for ${label}**

SHA256 (${sha256_path}): ${sha256_sum}
SHA512 (${sha512_path}): ${sha512_sum}
CHECKMATE
} >&${fd}

# Generate release notes based on build type
generate_release_notes() {
  local name="$1"
  local tag="$2"
  local vcs="$3"
  local build_type="$4"
  local language="$5"
  local notes_file="$6"
  local vendor_checksums_name="$7"
  local crates_tarball="$8"
  local crates_checksums_name="$9"

  # Open notes file for writing with a file descriptor
  exec {fd}>> "${notes_file}"

  # Base release notes
  printf "Vendored release for %s version %s\n\n" "${name}" "${tag}" >&${fd}
  printf "Upstream repository: %s\n\n" "${vcs}" >&${fd}
  printf "Language: %s\n\n" "${language}" >&${fd}

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

  # Add checksums
  write_checksum_notes "vendored tarball" "$vendor_checksums_name"
  if [[ -n ${crates_tarball} ]]; then
    printf "\n" >&${fd}
    write_checksum_notes "crates tarball" "$crates_checksums_name"
  fi

  # Use printf with strftime-style formatting (%(... )T) to insert current UTC timestamp
  TZ=UTC printf "\n---\nGenerated: %(%Y-%m-%d %H:%M:%S UTC)T\n" -1 >&${fd}

  # Close the file descriptor since we're done
  exec {fd}>&-
}

create_github_release() {
  local tarball_path="$1"
  local name="$2"
  local tag="$3"
  local build_type="$4"
  local notes_file="$5"
  local vendor_checksums_name="$6"
  local crates_tarball="$7"
  local crates_checksums_name="$8"
  local -n _vendor_checksums="$vendor_checksums_name"
  local -n _crates_checksums="$crates_checksums_name"

  local release_tag="${name}-${tag}"
  local title="[${build_type}] ${name} ${tag}"
  local -a files=("${tarball_path}")

  for file in "${_vendor_checksums[@]}"; do
    if [[ -r ${file} ]]; then
      files+=("${file}")
    fi
  done

  if [[ -n ${crates_tarball} ]]; then
    files+=("${crates_tarball}")
    for file in "${_crates_checksums[@]}"; do
      if [[ -r ${file} ]]; then
        files+=("${file}")
      fi
    done
  fi

  logging::log_info "Creating release: ${release_tag}"

  gh release create "${release_tag}" \
    --repo "${GITHUB_REPOSITORY}" \
    --title "${title}" \
    --notes-file "${notes_file}" \
    --target "${GITHUB_SHA:-HEAD}" \
    "${files[@]}"
}

main() {
  if (( $# < 6 || $# > 7 )); then
    logging::log_error "Invalid number of arguments: $#"
    usage
  fi

  local tarball_path="$1"
  local name="$2"
  local tag="$3"
  local vcs="$4"
  local build_type="$5"
  local language="$6"
  local crates_tarball_path="${7:-}"

  # Validate inputs
  if [[ ! -f ${tarball_path} ]]; then
    logging::log_fatal "Tarball not found: ${tarball_path}"
  fi
  if [[ -n ${crates_tarball_path} && ! -f ${crates_tarball_path} ]]; then
    logging::log_fatal "Crates tarball not found: ${crates_tarball_path}"
  fi

  if [[ ! ${build_type} =~ ^(vendored|preemptive)$ ]]; then
    logging::log_fatal "Invalid build_type: ${build_type}. Must be 'vendored' or 'preemptive'"
  fi

  # Check environment
  check_environment

  # Check dependencies
  check_dependencies

  # Generate checksums
  local -A vendor_checksums
  compute_checksums "$tarball_path" vendor_checksums
  local -A crates_checksums
  if [[ -n ${crates_tarball_path} ]]; then
    compute_checksums "$crates_tarball_path" crates_checksums
  fi

  # Generate release notes
  local notes_file
  notes_file="$(mktemp release_notes.txt.XXXXXX)"

  generate_release_notes "${name}" "${tag}" "${vcs}" "${build_type}" "${language}" "${notes_file}" vendor_checksums "${crates_tarball_path}" crates_checksums

  # Create the release
  create_github_release "$tarball_path" "$name" "$tag" "$build_type" "$notes_file" vendor_checksums "${crates_tarball_path}" crates_checksums

  # Cleanup
  rm -f -- "$notes_file"

  logging::log_info "Release created successfully: ${name}-${tag}"
}

if ! (return 0 2> /dev/null); then
  main "$@"
fi
