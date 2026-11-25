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

  haze_exclude_generated
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

  # Pruning removed Chromium's bundled python, node and gperf, but the build
  # still looks for them at these paths, so point them at the host's copies.
  # .gn sets script_executable to the cpython3 path, so gn gen fails with exit
  # 127 without that one.
  link_host_tool python3 "${HAZE_SRC_DIR}/third_party/cpython3/host/bin/python3"
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

# ungoogled prunes the prebuilt gn, so build it from the tree once and share it
# between configs. It lands in out/, which Chromium's own .gitignore excludes.
#
# This does what tools/gn/bootstrap/bootstrap.py does, but calls GN's gen.py
# directly to pass --no-static-libstdc++. bootstrap.py does not forward that
# flag, and GN's gen.py links the tool with -static-libstdc++ on Linux, which
# needs libstdc++.a — a separate package on Fedora and several other distros.
# Static linking only matters for shipping the gn binary around; a locally
# built tool is fine against the shared library.
ensure_gn() {
  if [ -x "${HAZE_GN}" ]; then
    haze_info "gn present: $("${HAZE_GN}" --version)"
    return 0
  fi
  haze_step "building gn"
  cd "${HAZE_SRC_DIR}"

  # gn is a host tool, so build it with the toolchain the rest of the build uses.
  local clang_bin="${HAZE_SRC_DIR}/third_party/llvm-build/Release+Asserts/bin"
  if [ -x "${clang_bin}/clang++" ]; then
    export CC="${clang_bin}/clang" CXX="${clang_bin}/clang++"
  fi

  local gn_build
  gn_build=$(dirname "${HAZE_GN}")
  haze_run python3 ./tools/gn/build/gen.py \
    --no-last-commit-position \
    --no-static-libstdc++ \
    --out-path="${gn_build}"
  # bootstrap.py supplies this stub instead of deriving a real commit position.
  cp ./tools/gn/bootstrap/last_commit_position.h "${gn_build}/"
  haze_run ninja -C "${gn_build}" gn -j "$(haze_jobs)"
  haze_info "built $("${HAZE_GN}" --version)"
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
  haze_run "${HAZE_GN}" gen "${OUT_DIR}" --fail-on-unused-args
}

compile() {
  haze_step "ninja: $*"
  cd "${HAZE_SRC_DIR}"
  haze_run ninja -C "${OUT_DIR}" -j "$(haze_jobs)" "$@"
}

main "$@"
