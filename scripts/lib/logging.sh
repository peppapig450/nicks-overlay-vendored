#!/usr/bin/env bash
# ==============================================================================
# logging.sh — Logging utilities for Bash scripts
#
# This library provides timestamped, color-coded log output and error handling
# utilities suitable for CI pipelines or general-purpose scripting.
#
# Features:
#   - Structured log levels: INFO, WARN, ERROR
#   - Color-coded output to stderr
#   - Namespaced function names via `logging::` convention
#       - Uses some conventions from the Google Shell Style Guide:
#       - https://google.github.io/styleguide/shellguide.html
#       - Particularly the use of `namespace::function` for namespacing.
#   - Drop-in error trap handler and safe trap appender
#
# Usage:
#   source ./logging.sh
#   logging::log_info "Things are fine"
#   logging::add_err_trap
#
# This file is intended to be sourced, not executed.
# ==============================================================================
set -Eeuo pipefail

# Bail if we're not being sourced
(return 0 2>/dev/null) || {
  printf "This script is meant to be sourced, not executed.\n" >&2
  exit 1
}

# helper: what’s our current shell?
_detect_shell() {
  # try /proc → otherwise ps
  if [ -r "/proc/$$/exe" ]; then
    basename "$(readlink /proc/$$/exe)"
  else
    basename "$(ps -p $$ -o comm= 2>/dev/null)"
  fi
}

# if not bash, complain and bail
if [ -z "${BASH_VERSION-}" ]; then
  shell="$(_detect_shell 2>/dev/null || echo unknown)"
  printf 'Error: this script requires Bash. You appear to be running in %s.\n' \
    "${shell}" >&2
  return 1
fi

# logging::log LEVEL MESSAGE
# Logs a message to stderr with UTC timestamp and color-coded level.
# Usage: logging::log INFO "Message"
# Note: For internal use by other logging functions.
logging::log() {
  local level="${1^^}" # Capitalize input for case-insensitive matching
  shift
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local color_reset=$'\033[0m' # Use ANSI-C quoting
  local color

  # CI pipelines need more color...
  case "${level}" in
    INFO) color=$'\033[0;32m' ;;  # Green!
    WARN) color=$'\033[0;33m' ;;  # Yellow!
    ERROR) color=$'\033[0;31m' ;; # Red!
    *)
      printf "Invalid log level: %s\n" "${level}"
      exit 1
      ;;
  esac

  # Send to stderr like a good log citizen
  LC_ALL=C printf "%b[%s] [%s] %s%b\n" "${color}" "${ts}" "${level}" "$*" "${color_reset}" >&2
}

logging::log_info() { logging::log INFO "$@"; }
logging::log_warn() { logging::log WARN "$@"; }
logging::log_error() { logging::log ERROR "$@"; }
logging::log_fatal() {
  logging::log ERROR "$@"
  exit 1
}

# logging::trap_err_handler
# A trap-safe fatal error logger. Logs an error message with source and line,
# then exits the script. Use this in a trap, e.g.:
#   trap 'logging::trap_err_handler' ERR
logging::trap_err_handler() {
  logging::log_fatal "Unexpected fatal error in ${BASH_SOURCE[1]} on line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
}

# logging::add_err_trap
# Appends logging::trap_err_handler to an existing ERR trap without overwriting it.
# Uses Perl to safely parse and chain existing trap commands.
logging::add_err_trap() {
  local existing

  # Extract any existing ERR trap command.
  # This matches lines like: trap -- 'echo something' ERR
  # We use Perl because quoting rules in shell are cursed and sed can't be trusted.
  # This extracts the inner single-quoted command safely—even if it contains
  # spaces, quotes, or other fragile syntax.
  existing="$(perl -lne '
        # Match a line that starts with `trap -- '...command...' ERR`
        if (/^trap -- '\''([^'\'']*)'\'' ERR$/) {
            print "$1"; # Print just the command portion inside the single quotes
        }
    ' <<<"$(trap -p ERR)" || true)"

  if [[ -z ${existing:-} ]]; then
    trap -- 'logging::trap_err_handler' ERR
  else
    trap -- "$(printf '%s; logging::trap_err_handler' "$existing")" ERR
  fi
}
