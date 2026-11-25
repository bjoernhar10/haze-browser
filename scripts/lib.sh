#!/usr/bin/env bash
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Shared paths, logging and error handling for every Haze script.
#
# Source it as the first thing in a script:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# macOS ships bash 3.2, so this file avoids bash 4 features (associative
# arrays, ${var,,}, mapfile).

# -E so the ERR trap below also fires inside functions and subshells.
set -Eeuo pipefail

if [ -n "${HAZE_LIB_SOURCED:-}" ]; then
  return 0
fi
HAZE_LIB_SOURCED=1

# --- Paths -------------------------------------------------------------------

HAZE_SCRIPTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HAZE_ROOT=$(cd -- "${HAZE_SCRIPTS_DIR}/.." && pwd)

HAZE_VERSION_FILE="${HAZE_ROOT}/chromium_version.txt"
HAZE_UNGOOGLED_DIR="${HAZE_ROOT}/ungoogled-chromium"
HAZE_OVERLAY_DIR="${HAZE_ROOT}/overlay"
HAZE_PATCHES_DIR="${HAZE_ROOT}/patches"
HAZE_SERIES_FILE="${HAZE_PATCHES_DIR}/series"
HAZE_FLAGS_DIR="${HAZE_ROOT}/flags"
HAZE_TOKENS_FILE="${HAZE_ROOT}/tokens/haze.json"
HAZE_DOCS_DIR="${HAZE_ROOT}/docs"
HAZE_TEST_DATA_DIR="${HAZE_ROOT}/test/data"

# Everything below build/ is gitignored and may be deleted at any time.
HAZE_BUILD_DIR="${HAZE_ROOT}/build"
HAZE_SRC_DIR="${HAZE_BUILD_DIR}/src"
HAZE_DOWNLOAD_DIR="${HAZE_BUILD_DIR}/download"
HAZE_LOG_DIR="${HAZE_BUILD_DIR}/logs"
HAZE_PROFILE_DIR="${HAZE_BUILD_DIR}/profiles"
HAZE_OUT_DEV="${HAZE_SRC_DIR}/out/Dev"
HAZE_OUT_RELEASE="${HAZE_SRC_DIR}/out/Release"

# Where overlay/ is synced to inside the Chromium tree. A copy, never edited.
HAZE_SRC_HAZE_DIR="${HAZE_SRC_DIR}/haze"

# --- Logging -----------------------------------------------------------------
# All logging goes to stderr so a function's stdout stays usable as data.

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  HAZE_C_RESET=$'\033[0m'
  HAZE_C_DIM=$'\033[2m'
  HAZE_C_BOLD=$'\033[1m'
  HAZE_C_RED=$'\033[31m'
  HAZE_C_YELLOW=$'\033[33m'
  HAZE_C_BLUE=$'\033[34m'
else
  HAZE_C_RESET=''
  HAZE_C_DIM=''
  HAZE_C_BOLD=''
  HAZE_C_RED=''
  HAZE_C_YELLOW=''
  HAZE_C_BLUE=''
fi

haze_step() {
  printf '%s==>%s %s%s%s\n' \
    "${HAZE_C_BLUE}" "${HAZE_C_RESET}" "${HAZE_C_BOLD}" "$*" "${HAZE_C_RESET}" >&2
}

haze_info() {
  printf '    %s\n' "$*" >&2
}

haze_warn() {
  printf '%swarning:%s %s\n' "${HAZE_C_YELLOW}" "${HAZE_C_RESET}" "$*" >&2
}

haze_error() {
  printf '%serror:%s %s\n' "${HAZE_C_RED}" "${HAZE_C_RESET}" "$*" >&2
}

haze_debug() {
  if [ -n "${HAZE_VERBOSE:-}" ]; then
    printf '%s    %s%s\n' "${HAZE_C_DIM}" "$*" "${HAZE_C_RESET}" >&2
  fi
}

haze_die() {
  haze_error "$@"
  exit 1
}

# Echo a command, then run it. Keeps build logs readable.
haze_run() {
  printf '%s    $ %s%s\n' "${HAZE_C_DIM}" "$*" "${HAZE_C_RESET}" >&2
  "$@"
}

# --- Error handling ----------------------------------------------------------

haze_on_error() {
  local status=$1 line=$2 cmd=$3
  haze_error "${HAZE_SCRIPT_NAME:-${0##*/}}: command failed (exit ${status}) at line ${line}"
  haze_error "  ${cmd}"
  exit "${status}"
}

trap 'haze_on_error "$?" "${LINENO}" "${BASH_COMMAND}"' ERR

# --- Checks ------------------------------------------------------------------

haze_require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || haze_die "required command not found: ${cmd}"
  done
}

haze_require_file() {
  [ -f "$1" ] || haze_die "required file not found: $1"
}

haze_require_dir() {
  [ -d "$1" ] || haze_die "required directory not found: $1"
}

# --- Facts about this checkout -----------------------------------------------

# The pinned Chromium version, e.g. 158.0.8127.88.
haze_chromium_version() {
  haze_require_file "${HAZE_VERSION_FILE}"
  local version
  version=$(tr -d '[:space:]' < "${HAZE_VERSION_FILE}")
  [ -n "${version}" ] || haze_die "${HAZE_VERSION_FILE} is empty"
  printf '%s\n' "${version}"
}

# The tag the ungoogled-chromium submodule is checked out at, e.g.
# 158.0.8127.88-1. Fails if the submodule is not on a tag, because an
# unpinned base layer makes builds unreproducible.
haze_ungoogled_tag() {
  haze_require_dir "${HAZE_UNGOOGLED_DIR}"
  git -C "${HAZE_UNGOOGLED_DIR}" describe --tags --exact-match HEAD 2>/dev/null \
    || haze_die "ungoogled-chromium is not checked out at a tag; run: git submodule update --init"
}

# mac | win | linux
haze_platform() {
  case "$(uname -s)" in
    Darwin) printf 'mac\n' ;;
    Linux) printf 'linux\n' ;;
    MINGW* | MSYS* | CYGWIN*) printf 'win\n' ;;
    *) haze_die "unsupported platform: $(uname -s)" ;;
  esac
}

# Parallelism for ninja and friends. Override with HAZE_JOBS.
haze_jobs() {
  if [ -n "${HAZE_JOBS:-}" ]; then
    printf '%s\n' "${HAZE_JOBS}"
    return 0
  fi
  case "$(haze_platform)" in
    mac) sysctl -n hw.ncpu ;;
    *) nproc ;;
  esac
}
