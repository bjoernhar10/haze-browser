#!/usr/bin/env bash
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Downloads the pinned Chromium source tarball, verifies its checksums and
# extracts it to build/src. It does not modify the tree; scripts/prepare.sh
# applies ungoogled-chromium on top.
#
# Idempotent: download and extraction are each guarded by a stamp in
# build/stamps/, so a second run does no work. ungoogled's downloads.py
# verifies md5 through sha512 during "retrieve" and exits non-zero on a
# mismatch; "unpack" does not re-verify, despite what its --help says.

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HAZE_SCRIPT_NAME="fetch.sh"

main() {
  haze_require_cmd python3 curl tar
  haze_require_dir "${HAZE_UG_UTILS}"
  haze_assert_version_match
  haze_drop_stale_stamps

  local version started
  version=$(haze_chromium_version)
  started=$(haze_now)

  haze_step "fetch Chromium ${version}"
  haze_info "tarball cache  ${HAZE_DOWNLOAD_DIR}"
  haze_info "source tree    ${HAZE_SRC_DIR}"

  download "${version}"
  extract
  haze_assert_src_version

  haze_step "fetch done in $(haze_elapsed "${started}")"
  haze_info "tarball cache  $(haze_disk_usage "${HAZE_DOWNLOAD_DIR}")"
  haze_info "source tree    $(haze_disk_usage "${HAZE_SRC_DIR}")"
  haze_info "next: scripts/prepare.sh"
}

download() {
  if haze_stamp_done download; then
    haze_info "tarball already downloaded and verified; skipping"
    return 0
  fi

  haze_step "downloading and verifying tarball (~945 MiB)"
  # Show the progress bar only on a terminal; in a log it is noise.
  local hide_progress=''
  if [ ! -t 2 ]; then
    hide_progress='--hide-progress-bar'
  fi
  mkdir -p "${HAZE_DOWNLOAD_DIR}"
  # shellcheck disable=SC2086  # hide_progress is a single literal flag or empty
  haze_run "${HAZE_UG_UTILS}/downloads.py" retrieve \
    -i "${HAZE_UNGOOGLED_DIR}/downloads.ini" \
    -c "${HAZE_DOWNLOAD_DIR}" \
    ${hide_progress}
  haze_stamp_mark download
}

extract() {
  if haze_stamp_done unpack; then
    haze_info "source tree already extracted; skipping"
    return 0
  fi

  # A half-extracted tree from an aborted run would make pruning and patching
  # fail in confusing ways, so start clean. But never throw away committed
  # work: a git repo in build/src means the baseline, and possibly Haze
  # patches, live there.
  if [ -d "${HAZE_SRC_DIR}/.git" ]; then
    haze_error "${HAZE_SRC_DIR} is a git repo, but the unpack stamp is gone."
    haze_error "Re-extracting would destroy the baseline and any Haze patch commits."
    haze_die "inspect it, then either 'touch ${HAZE_STAMP_DIR}/unpack' or remove the tree yourself"
  fi
  if [ -e "${HAZE_SRC_DIR}" ]; then
    haze_warn "removing incomplete ${HAZE_SRC_DIR} from an earlier run"
    rm -rf "${HAZE_SRC_DIR}"
  fi

  haze_step "extracting to build/src"
  mkdir -p "${HAZE_SRC_DIR}"
  haze_run "${HAZE_UG_UTILS}/downloads.py" unpack \
    -i "${HAZE_UNGOOGLED_DIR}/downloads.ini" \
    -c "${HAZE_DOWNLOAD_DIR}" \
    -- "${HAZE_SRC_DIR}"
  haze_stamp_mark unpack
}

main "$@"
