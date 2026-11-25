#!/usr/bin/env bash
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Builds Haze.
#
#   scripts/build.sh dev|release [target ...]    # default target: chrome
#
# It syncs overlay/ into build/src/haze/, makes sure the toolchain is in
# place, writes args.gn, runs gn gen and then ninja. Everything is logged to
# build/logs/build-<config>-<timestamp>.log.
#
# args.gn is always ungoogled's flags.gn followed by flags/<config>.gn, so the
# ungoogled args come from the submodule instead of being copied into Haze and
# going stale on the next rebase.

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HAZE_SCRIPT_NAME="build.sh"

# Domain substitution rewrites the Chromium tool-download URLs, which breaks
# fetching the prebuilt clang and rust. update.py reads this environment
# variable, and update_rust.py imports its downloader, so one variable fixes
# both without touching the source tree.
export CDS_CLANG_BUCKET_OVERRIDE='https://commondatastorage.googleapis.com/chromium-browser-clang'

usage() {
  cat >&2 <<'USAGE'
usage: scripts/build.sh dev|release [target ...]

  dev      component build in out/Dev, fast to link
  release  official build in out/Release

Targets default to "chrome".
USAGE
  exit 2
}

CONFIG=''
OUT_DIR=''
FLAGS_FILE=''

main() {
  case "${1:-}" in
    dev)
      CONFIG='dev'
      OUT_DIR="${HAZE_OUT_DEV}"
      FLAGS_FILE="${HAZE_FLAGS_DIR}/dev.gn"
      ;;
    release)
      CONFIG='release'
      OUT_DIR="${HAZE_OUT_RELEASE}"
      FLAGS_FILE="${HAZE_FLAGS_DIR}/release.gn"
      ;;
    *) usage ;;
  esac
  shift
  if [ "$#" -eq 0 ]; then
    set -- chrome
  fi

  haze_require_cmd python3 git rsync ninja gperf node
  haze_require_file "${FLAGS_FILE}"
  haze_assert_version_match
  if [ ! -f "${HAZE_SRC_DIR}/chrome/VERSION" ]; then
    haze_die "no prepared tree at ${HAZE_SRC_DIR}; run scripts/fetch.sh and scripts/prepare.sh first"
  fi
  haze_assert_src_version

  mkdir -p "${HAZE_LOG_DIR}"
  local log
  log="${HAZE_LOG_DIR}/build-${CONFIG}-$(date -u +%Y%m%dT%H%M%SZ).log"
  haze_step "build ${CONFIG}: $*"
  haze_info "log  ${log}"
  # Keep the console output and write the same thing to the log.
  exec > >(tee -a "${log}") 2>&1

  local started
  started=$(haze_now)

  exclude_generated_paths
  sync_overlay
  ensure_toolchain
  ensure_gn
  write_args
  generate
  compile "$@"

  haze_step "build ${CONFIG} done in $(haze_elapsed "${started}")"
  haze_info "output   ${OUT_DIR}"
  haze_info "log      ${log}"
}

# build/src is a git repo whose history is the Haze patch series, so anything
# generated must stay invisible to git or it would show up in exported patches.
# .git/info/exclude is local to the tree and survives re-running this script.
exclude_generated_paths() {
  local exclude="${HAZE_SRC_DIR}/.git/info/exclude"
  [ -d "${HAZE_SRC_DIR}/.git" ] || return 0
  mkdir -p "$(dirname "${exclude}")"
  local path
  for path in '/haze/' '/third_party/node/linux/' '/third_party/gperf/cipd/'; do
    if ! grep -qxF "${path}" "${exclude}" 2>/dev/null; then
      printf '%s\n' "${path}" >> "${exclude}"
      haze_debug "excluded from build/src git: ${path}"
    fi
  done
}

# overlay/ is the source of truth. build/src/haze/ is a copy and is never
# edited by hand, so --delete keeps it exactly in step with overlay/.
sync_overlay() {
  haze_step "syncing overlay/ -> build/src/haze/"
  mkdir -p "${HAZE_SRC_HAZE_DIR}"
  haze_run rsync -a --delete "${HAZE_OVERLAY_DIR}/" "${HAZE_SRC_HAZE_DIR}/"
}

ensure_toolchain() {
  haze_step "checking toolchain"
  cd "${HAZE_SRC_DIR}"

  # Both scripts check what is already installed and exit early, so running
  # them on every build costs a second or two.
  haze_run python3 ./tools/clang/scripts/update.py
  haze_run python3 ./tools/rust/update_rust.py

  if grep -q '^use_sysroot[[:space:]]*=[[:space:]]*false' "${FLAGS_FILE}"; then
    haze_info "use_sysroot=false; skipping sysroot install"
  else
    haze_run python3 ./build/linux/sysroot_scripts/install-sysroot.py --arch=amd64
  fi

  # Pruning removed Chromium's bundled node and gperf, but the build still
  # looks for them at these paths, so point them at the host's copies.
  link_host_tool node "${HAZE_SRC_DIR}/third_party/node/linux/node-linux-x64/bin/node"
  link_host_tool gperf "${HAZE_SRC_DIR}/third_party/gperf/cipd/bin/gperf"
}

link_host_tool() {
  local tool="$1" dest="$2" src
  src=$(command -v "${tool}")
  if [ -L "${dest}" ] && [ "$(readlink "${dest}")" = "${src}" ]; then
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  ln -sfn "${src}" "${dest}"
  haze_info "linked ${tool}: ${dest} -> ${src}"
}

# ungoogled prunes the prebuilt gn, so build it from the tree. It lands inside
# out/, which Chromium's own .gitignore already excludes.
ensure_gn() {
  local gn="${OUT_DIR}/gn"
  if [ -x "${gn}" ]; then
    haze_info "gn present: $("${gn}" --version)"
    return 0
  fi
  haze_step "bootstrapping gn"
  mkdir -p "${OUT_DIR}"
  cd "${HAZE_SRC_DIR}"
  haze_run python3 ./tools/gn/bootstrap/bootstrap.py \
    -o "${gn}" \
    --skip-generate-buildfiles \
    -j "$(haze_jobs)"
}

write_args() {
  haze_step "writing args.gn"
  mkdir -p "${OUT_DIR}"
  {
    printf '# Generated by scripts/build.sh for the %s config. Do not edit.\n' "${CONFIG}"
    printf '# Edit flags/%s.gn instead.\n\n' "${CONFIG}"
    printf '# --- ungoogled-chromium %s: flags.gn ---\n' "$(haze_ungoogled_tag)"
    cat "${HAZE_UNGOOGLED_DIR}/flags.gn"
    printf '\n# --- Haze: flags/%s.gn ---\n' "${CONFIG}"
    cat "${FLAGS_FILE}"
  } > "${OUT_DIR}/args.gn"
  haze_info "$(grep -cvE '^[[:space:]]*(#|$)' "${OUT_DIR}/args.gn") args in ${OUT_DIR}/args.gn"
}

generate() {
  haze_step "gn gen"
  cd "${HAZE_SRC_DIR}"
  # --fail-on-unused-args turns a stale or misspelled arg into an error instead
  # of a silently ignored line.
  haze_run "${OUT_DIR}/gn" gen "${OUT_DIR}" --fail-on-unused-args
}

compile() {
  haze_step "ninja: $*"
  cd "${HAZE_SRC_DIR}"
  haze_run ninja -C "${OUT_DIR}" -j "$(haze_jobs)" "$@"
}

main "$@"
