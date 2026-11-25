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
HAZE_UG_UTILS="${HAZE_UNGOOGLED_DIR}/utils"
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
HAZE_DOWNLOAD_DIR="${HAZE_BUILD_DIR}/download_cache"
HAZE_LOG_DIR="${HAZE_BUILD_DIR}/logs"
HAZE_PROFILE_DIR="${HAZE_BUILD_DIR}/profiles"
# Stamps record finished pipeline steps. They live outside build/src so the
# Chromium tree and its baseline git repo stay clean.
HAZE_STAMP_DIR="${HAZE_BUILD_DIR}/stamps"
# Pre-substitution copies, so domain substitution can be reverted on a rebase.
HAZE_DOMSUB_CACHE="${HAZE_BUILD_DIR}/domsubcache.tar.gz"

# gn is built from the tree (ungoogled prunes the prebuilt one) and shared by
# every config.
HAZE_GN="${HAZE_SRC_DIR}/out/gn_build/gn"

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

# --- Step stamps -------------------------------------------------------------

haze_stamp_done() {
  [ -f "${HAZE_STAMP_DIR}/$1" ]
}

haze_stamp_mark() {
  mkdir -p "${HAZE_STAMP_DIR}"
  date -u +'%Y-%m-%dT%H:%M:%SZ' > "${HAZE_STAMP_DIR}/$1"
}

# Stamps describe build/src. If the tree is gone, they are lies: drop them so a
# re-run rebuilds from scratch instead of skipping steps that never happened.
haze_drop_stale_stamps() {
  if [ -f "${HAZE_SRC_DIR}/chrome/VERSION" ]; then
    return 0
  fi
  local stamp
  for stamp in unpack prune patches domsub; do
    if haze_stamp_done "${stamp}"; then
      haze_warn "build/src is missing; dropping stale stamp: ${stamp}"
      rm -f "${HAZE_STAMP_DIR}/${stamp}"
    fi
  done
}

# --- Version checks ----------------------------------------------------------

# ungoogled's utils read their OWN chromium_version.txt, not Haze's. If the two
# disagree, the pipeline would quietly work on a different version than Haze
# pins, so refuse to run.
haze_assert_version_match() {
  local ours theirs
  ours=$(haze_chromium_version)
  haze_require_file "${HAZE_UNGOOGLED_DIR}/chromium_version.txt"
  theirs=$(tr -d '[:space:]' < "${HAZE_UNGOOGLED_DIR}/chromium_version.txt")
  if [ "${ours}" != "${theirs}" ]; then
    haze_error "version mismatch:"
    haze_error "  chromium_version.txt pins      ${ours}"
    haze_error "  ungoogled-chromium is built for ${theirs} (tag $(haze_ungoogled_tag))"
    haze_die "ungoogled's utils read their own file, so the pipeline would use ${theirs}"
  fi
}

# The version of the extracted tree, read from chrome/VERSION.
haze_src_version() {
  local f="${HAZE_SRC_DIR}/chrome/VERSION"
  haze_require_file "${f}"
  # chrome/VERSION holds MAJOR=..., MINOR=..., BUILD=..., PATCH=...
  awk -F= '/^(MAJOR|MINOR|BUILD|PATCH)=/ { v[$1] = $2 }
           END { printf "%s.%s.%s.%s\n", v["MAJOR"], v["MINOR"], v["BUILD"], v["PATCH"] }' "${f}"
}

haze_assert_src_version() {
  local pinned actual
  pinned=$(haze_chromium_version)
  actual=$(haze_src_version)
  if [ "${pinned}" != "${actual}" ]; then
    haze_die "build/src holds Chromium ${actual}, but chromium_version.txt pins ${pinned}"
  fi
}

# --- Timing and size ---------------------------------------------------------

haze_now() {
  date +%s
}

# haze_elapsed START_EPOCH -> "4m 07s" or "1h 12m 03s"
haze_elapsed() {
  local total=$(( $(date +%s) - $1 ))
  local h=$(( total / 3600 )) m=$(( (total % 3600) / 60 )) s=$(( total % 60 ))
  if [ "${h}" -gt 0 ]; then
    printf '%dh %02dm %02ds\n' "${h}" "${m}" "${s}"
  else
    printf '%dm %02ds\n' "${m}" "${s}"
  fi
}

# Human-readable size of a path, or "-" if it does not exist.
haze_disk_usage() {
  if [ -e "$1" ]; then
    du -sh "$1" 2>/dev/null | cut -f1
  else
    printf -- '-\n'
  fi
}

# --- build/src git hygiene ---------------------------------------------------

# build/src's history IS the Haze patch series, so anything generated must stay
# invisible to git there or it would leak into exported patches. overlay/ is the
# source of truth for build/src/haze/, and the toolchain links are host paths.
# .git/info/exclude is local to that tree and is not part of any commit.
haze_exclude_generated() {
  [ -d "${HAZE_SRC_DIR}/.git" ] || return 0
  local exclude="${HAZE_SRC_DIR}/.git/info/exclude"
  mkdir -p "${HAZE_SRC_DIR}/.git/info"
  local path
  for path in '/haze/' '/third_party/cpython3/' '/third_party/node/linux/' \
      '/third_party/gperf/cipd/'; do
    if ! grep -qxF "${path}" "${exclude}" 2>/dev/null; then
      printf '%s\n' "${path}" >> "${exclude}"
      haze_debug "excluded from build/src git: ${path}"
    fi
  done
}
