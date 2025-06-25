#!/usr/bin/env bash
# ==============================================================================
# build-go-deps.sh — Build vendored Go dependency tarball for a given module tag
#
# This script is a Go-specific wrapper around the shared vendoring framework
# (`build-common.lib.sh`). It is intended to be invoked from CI pipelines and
# expects a JSON configuration via stdin describing a Go module to vendor.
#
# The script performs the following:
#   - Sources logging and common vendoring libraries
#   - Overrides vendoring and tarball-creation functions for Go
#   - Downloads Go module dependencies into a local mod cache (vendor-like)
#   - Packages the downloaded dependencies into a deterministic tarball
#   - Emits the resulting tarball filename to stdout
#
# Expected input (via stdin): JSON with the following fields:
#   - name: module name (used as folder name)
#   - repo: GitHub organization/repo
#   - vcs: repository URL
#   - tag: git tag to checkout
#
# Example usage:
#   jq -n --arg name foo --arg repo myorg/foo --arg vcs https://github.com/myorg/foo.git --arg tag v1.2.3 \
#     '{name: $name, repo: $repo, vcs: $vcs, tag: $tag}' \
#     | ./ci/build-go-deps.sh
#
# Requirements:
#   - bash 4+
#   - jq, git, tar, xz, and Go installed in the environment
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

  logging::log_info "Downloading Go modules for ${name}"
  (
    cd -P -- "${name}" || logging::log_fatal "Failed to enter directory: ${name}"
    env GOMODCACHE="${PWD}/go-mod" go mod download -modcacherw -x
  )
}

# XXX: maybe move this to build-common.lib.sh and use a variable/array for the directories
# to include in the tarball.

# Packages the go-mod directory into a compressed tarball.
# Returns the tarball filename on success.
override::create_tarball() {
  local name="$1"
  local tag="$2"
  local deps_dir="${name}/go-mod"

  local version
  if ! version="$(common::check_tag "${tag}")"; then
    logging::log_fatal "Aborting: invalid tag '${tag}'"
  fi

  local target="${name}-${version}-deps.tar.xz"
  logging::log_info "Creating tarball: ${target}"

  if common::check_dir_not_empty "${deps_dir}"; then
    tar \
      --mtime="1989-01-01" \
      --sort=name \
      -C "${name}" -cf - "go-mod" \
      | xz --threads=0 -9e -T0 > "${target}"
    printf "%s" "${target}"
  else
    logging::log_fatal "Go mod deps download failed, '${deps_dir}' is empty or missing"
  fi
}

# Only run if the script is executed
if ! (return 0 2> /dev/null); then
  common::run_build
fi
