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

# Chromium keeps clang-format in a per-platform buildtools directory, whose name
# is also the DEPS entry name.
case "$(uname -s)" in
  Darwin) HAZE_FORMAT_DIR='mac-format' ;;
  MINGW* | MSYS* | CYGWIN*) HAZE_FORMAT_DIR='win-format' ;;
  *) HAZE_FORMAT_DIR='linux64-format' ;;
esac

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
  ensure_clang_format
  ensure_libclang
  ensure_esbuild
  ensure_typescript
}

# Tools Chromium downloads from Google Cloud Storage rather than building, and
# which ungoogled prunes. Each is declared in DEPS with a sha256, so this
# verifies what it fetches the same way scripts/fetch.sh verifies the tarball.

# clang-format is not part of the clang package. A Crubit step that generates
# C++ APIs from Rust needs it, and that step cannot be switched off, because
# enable_cpp_api_from_rust is computed from enable_rust and build_with_chromium
# rather than being a gn arg.
ensure_clang_format() {
  local dir="${HAZE_SRC_DIR}/buildtools/${HAZE_FORMAT_DIR}"
  ensure_gcs_dep \
    "src/buildtools/${HAZE_FORMAT_DIR}" \
    "${dir}" \
    "${dir}/clang-format" \
    'clang-format'
}

# V8's metagen imports libclang's python bindings to generate instance types.
ensure_libclang() {
  local dir="${HAZE_SRC_DIR}/third_party/llvm-libclang"
  ensure_gcs_dep \
    'src/third_party/llvm-libclang' \
    "${dir}" \
    "${dir}/bindings/python/clang/cindex.py" \
    'libclang'
}

# ensure_gcs_dep ENTRY DEST SENTINEL LABEL
#
# An entry either names an output_file, which is a single file to install, or it
# does not, which means the object is an archive to unpack into DEST. That is
# the same distinction gclient makes.
ensure_gcs_dep() {
  local entry="$1" dest="$2" sentinel="$3" label="$4"
  if [ -e "${sentinel}" ]; then
    return 0
  fi

  haze_step "fetching ${label}"
  local fields bucket object sha output
  fields=$(deps_entry "${HAZE_SRC_DIR}/DEPS" gcs "${entry}" "$(haze_platform)")
  bucket=$(printf '%s' "${fields}" | cut -d' ' -f1)
  object=$(printf '%s' "${fields}" | cut -d' ' -f2)
  sha=$(printf '%s' "${fields}" | cut -d' ' -f3)
  output=$(printf '%s' "${fields}" | cut -d' ' -f4)

  local archive="${HAZE_DOWNLOAD_DIR}/${object##*/}"
  mkdir -p "${HAZE_DOWNLOAD_DIR}" "${dest}"
  haze_run curl -sSfL -o "${archive}" "https://storage.googleapis.com/${bucket}/${object}"
  if ! printf '%s  %s\n' "${sha}" "${archive}" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "${archive}"
    haze_die "${label} does not match the sha256 DEPS declares for it"
  fi

  case "${object}" in
    *.tar.xz | *.tar.gz | *.tgz)
      haze_run tar -xf "${archive}" -C "${dest}"
      ;;
    *)
      if [ "${output}" = '-' ]; then
        haze_die "${label}: DEPS names no output_file and the object is not an archive"
      fi
      install -m755 "${archive}" "${dest}/${output}"
      ;;
  esac

  if [ ! -e "${sentinel}" ]; then
    haze_die "${label} download did not provide ${sentinel##*/}"
  fi
  haze_info "${label} ready"
}

# Several tools the build needs are cipd packages listed in DEPS that
# ungoogled prunes. cipd serves them as plain zips over HTTPS; Chromium's own
# tools/rust/build_rust.py uses the same endpoint. Versions are read from DEPS
# on every build rather than pinned here, so a rebase picks up the new ones.

# devtools-frontend bundles a node wrapper for esbuild in node_modules, but the
# native binary that wrapper needs is pruned, so fetch the real package.
ensure_esbuild() {
  local dir="${HAZE_SRC_DIR}/third_party/devtools-frontend/src/third_party/esbuild"
  ensure_cipd_package \
    "${HAZE_SRC_DIR}/third_party/devtools-frontend/src/DEPS" \
    'third_party/esbuild' \
    "${dir}" \
    "${dir}/esbuild" \
    'esbuild'
}

# The TypeScript package is more than the compiler: the build also reads the
# lib.*.d.ts standard library out of the same directory, so the whole package
# has to be there, not just a tsc binary.
ensure_typescript() {
  local platform dir
  platform=$(cipd_platform)
  dir="${HAZE_SRC_DIR}/third_party/typescript/${platform}/src"
  ensure_cipd_package \
    "${HAZE_SRC_DIR}/DEPS" \
    "src/third_party/typescript/${platform}/src" \
    "${dir}" \
    "${dir}/lib/tsc" \
    'TypeScript'
}

# ensure_cipd_package DEPS ENTRY DEST SENTINEL LABEL
ensure_cipd_package() {
  local deps="$1" entry="$2" dest="$3" sentinel="$4" label="$5"
  if [ -e "${sentinel}" ]; then
    return 0
  fi

  haze_step "fetching ${label}"
  local fields package version
  fields=$(deps_entry "${deps}" cipd "${entry}")
  package=$(printf '%s' "${fields}" | cut -d' ' -f1)
  version=$(printf '%s' "${fields}" | cut -d' ' -f2)
  # DEPS writes the platform as a placeholder that gclient would expand.
  package=${package//'${{platform}}'/$(cipd_platform)}

  local zip="${HAZE_DOWNLOAD_DIR}/${package##*/}-${version}.zip"
  mkdir -p "${HAZE_DOWNLOAD_DIR}" "${dest}"
  haze_run curl -sSfL -o "${zip}" \
    "https://chrome-infra-packages.appspot.com/dl/${package}/+/${version}"
  # zipfile.extractall drops the executable bit, so restore each member's mode.
  haze_run python3 -I -c 'import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    for member in archive.infolist():
        archive.extract(member, sys.argv[2])
        mode = member.external_attr >> 16
        if mode:
            os.chmod(os.path.join(sys.argv[2], member.filename), mode)' \
    "${zip}" "${dest}"

  if [ ! -e "${sentinel}" ]; then
    haze_die "${label} package did not contain ${sentinel##*/}"
  fi
  haze_info "${label} ${version}"
}

cipd_platform() {
  case "$(haze_platform)" in
    mac) if [ "$(uname -m)" = 'arm64' ]; then printf 'mac-arm64\n'; else printf 'mac-amd64\n'; fi ;;
    win) printf 'windows-amd64\n' ;;
    *) printf 'linux-amd64\n' ;;
  esac
}

# Print one DEPS entry's fields. See scripts/deps_tool.py.
deps_entry() {
  python3 -I "${HAZE_SCRIPTS_DIR}/deps_tool.py" "$@"
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
