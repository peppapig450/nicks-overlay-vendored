#!/usr/bin/env bash
# ==============================================================================
# build-rust-deps.sh — Build vendored Rust dependency tarball for a given module tag
#
# This script is a Rust-specific wrapper around the shared vendoring framework
# (`build-common.lib.sh`). It is intended to be invoked from CI pipelines and
# expects a JSON configuration via stdin describing a Rust crate to vendor.
#
# The script performs the following:
#   - Sources logging and common vendoring libraries
#   - Overrides vendoring and tarball-creation functions for Rust
#   - Fetches and vendors Cargo dependencies into a `vendor/` directory
#   - Packages the vendored dependencies into a deterministic tarball
#   - Emits the resulting tarball filename to stdout
#
# Expected input (via stdin): JSON with the following fields:
#   - name: crate name (used as folder name)
#   - repo: GitHub organization/repo
#   - vcs: repository URL
#   - tag: git tag to checkout
#
# Example usage:
#   jq -n --arg name foo --arg repo myorg/foo --arg vcs https://github.com/myorg/foo.git --arg tag v1.2.3 \
#     '{name: $name, repo: $repo, vcs: $vcs, tag: $tag}' \
#     | ./ci/build-rust-deps.sh
#
# Requirements:
#   - bash 4+
#   - jq, git, tar, xz, and cargo (Rust toolchain) installed in the environment
#   - GNU tar (not BSD tar)
#
# This script should not be sourced — it is meant to be executed directly.
#
# See also: build-common.lib.sh, logging.lib.sh
# ==============================================================================

set -Eeuo pipefail

UTILS_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib" && pwd)"

source "${UTILS_LIB_ROOT}/utils.lib.sh"

utils::load_or_die logging.lib.sh
logging::init "$0"
utils::load_or_die build-common.lib.sh

override::vendor_dependencies() {
  local name="$1"
  local subdir="$2"

  logging::log_info "Vendoring Cargo crates for ${name}"
  (
    cd -P -- "${name}" || logging::log_fatal "Failed to enter directory: ${name}"
    if [[ -n ${subdir} ]]; then
      cd -P -- "${subdir}" || logging::log_fatal "Failed to enter subdir: ${subdir}"
    fi

    if ! cargo vendor --locked > /dev/null; then
      logging::log_fatal "Something went wrong running 'cargo vendor'"
    fi
  )
}

# Packages the vendor/ directory into a compressed tarball
# Returns the tarball filename on success
override::create_tarball() {
  local name="$1"
  local tag="$2"
  local subdir="$3"

  local base_dir="${name}"
  [[ -n ${subdir} ]] && base_dir+="/${subdir}"

  local version
  if ! version="$(common::check_tag "${tag}")"; then
    logging::log_fatal "Aborting, invalid tag: '${tag}'"
  fi

  local target_name="${name}-${version}"
  local target="${target_name}-vendor.tar.xz"
  logging::log_info "Creating tarball: ${target}"

  local deps_dir="${base_dir}/vendor"

  if common::check_dir_not_empty "${deps_dir}"; then
    tar \
      --mtime="1989-01-01" \
      --sort=name \
      --transform="s|^vendor|${target_name}/vendor|"\
      -C "${base_dir}" -cf - "vendor" \
      | xz --threads=0 -9e -T0 > "${target}"
    printf "%s" "${target}"
  else
    logging::log_fatal "Cargo vendoring failed, '${deps_dir}' is empty or missing"
  fi
}

# Only run if the script is executed
if ! (return 0 2> /dev/null); then
  common::run_build
fi
