#!/usr/bin/env bash
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Applies ungoogled-chromium to the extracted tree in build/src, then makes it
# a git repo whose first commit is the baseline every Haze patch sits on:
#
#   prune binaries -> ungoogled patches -> domain substitution -> baseline
#
# Haze's own patches are NOT applied here; scripts/patch.sh does that on top of
# the baseline commit.
#
# Idempotent: each stage is guarded by a stamp in build/stamps/, which matters
# because none of ungoogled's utils are idempotent on their own. prune_binaries
# exits 1 when a file it wants to delete is already gone, patches.py fails on
# an already-patched tree, and domain_substitution refuses to run when its
# cache exists. A second run also never touches an existing baseline repo, so
# Haze patch commits survive it.

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HAZE_SCRIPT_NAME="prepare.sh"

main() {
  haze_require_python
  haze_require_cmd git patch
  haze_require_dir "${HAZE_UG_UTILS}"
  haze_assert_version_match
  haze_drop_stale_stamps

  if [ ! -f "${HAZE_SRC_DIR}/chrome/VERSION" ]; then
    haze_die "no Chromium tree at ${HAZE_SRC_DIR}; run scripts/fetch.sh first"
  fi
  haze_assert_src_version

  local version started
  version=$(haze_chromium_version)
  started=$(haze_now)

  haze_step "prepare Chromium ${version} (ungoogled $(haze_ungoogled_tag))"

  prune
  apply_ungoogled_patches
  substitute_domains
  baseline "${version}"

  haze_step "prepare done in $(haze_elapsed "${started}")"
  haze_info "source tree  $(haze_disk_usage "${HAZE_SRC_DIR}")"
  haze_info "next: scripts/build.sh dev"
}

prune() {
  if haze_stamp_done prune; then
    haze_info "binaries already pruned; skipping"
    return 0
  fi
  haze_step "pruning bundled binaries"
  haze_run "${HAZE_PYTHON}" "${HAZE_UG_UTILS}/prune_binaries.py" \
    "${HAZE_SRC_DIR}" \
    "${HAZE_UNGOOGLED_DIR}/pruning.list"
  haze_stamp_mark prune
}

apply_ungoogled_patches() {
  if haze_stamp_done patches; then
    haze_info "ungoogled patches already applied; skipping"
    return 0
  fi
  haze_step "applying ungoogled-chromium patches"
  haze_run "${HAZE_PYTHON}" "${HAZE_UG_UTILS}/patches.py" apply \
    "${HAZE_SRC_DIR}" \
    "${HAZE_UNGOOGLED_DIR}/patches"
  haze_stamp_mark patches
}

substitute_domains() {
  if haze_stamp_done domsub; then
    haze_info "domains already substituted; skipping"
    return 0
  fi
  haze_step "substituting domains"
  # The cache holds the pre-substitution originals. domain_substitution.py
  # refuses to run if it already exists, and rebases need it to revert.
  if [ -e "${HAZE_DOMSUB_CACHE}" ]; then
    haze_die "${HAZE_DOMSUB_CACHE} exists but the domsub stamp does not; remove the cache to redo substitution"
  fi
  haze_run "${HAZE_PYTHON}" "${HAZE_UG_UTILS}/domain_substitution.py" apply \
    -r "${HAZE_UNGOOGLED_DIR}/domain_regex.list" \
    -f "${HAZE_UNGOOGLED_DIR}/domain_substitution.list" \
    -c "${HAZE_DOMSUB_CACHE}" \
    "${HAZE_SRC_DIR}"
  haze_stamp_mark domsub
}

# Turn build/src into a git repo whose first commit is the prepared tree. Haze
# patches become commits on top, which is what lets scripts/patch.sh export
# them as a quilt series.
baseline() {
  local version="$1"

  if [ -d "${HAZE_SRC_DIR}/.git" ]; then
    if git -C "${HAZE_SRC_DIR}" rev-parse -q --verify refs/tags/baseline >/dev/null; then
      local head_desc
      head_desc=$(git -C "${HAZE_SRC_DIR}" log --oneline -1)
      haze_info "baseline commit already exists; leaving the repo alone"
      haze_info "  HEAD: ${head_desc}"
      if [ -n "$(git -C "${HAZE_SRC_DIR}" status --porcelain)" ]; then
        haze_info "  tree has uncommitted changes (expected while working on a patch)"
      fi
      return 0
    fi
    haze_die "${HAZE_SRC_DIR} is a git repo without a 'baseline' tag; refusing to touch it"
  fi

  haze_step "committing baseline ${version}"
  haze_run git init --quiet "${HAZE_SRC_DIR}"
  git -C "${HAZE_SRC_DIR}" symbolic-ref HEAD refs/heads/haze

  # A fixed local identity. This repo is never pushed, but the identity ends up
  # in the From: line of every exported patch, so it has to be the same on every
  # machine or scripts/patch.sh export would produce a diff elsewhere.
  git -C "${HAZE_SRC_DIR}" config user.name 'Haze'
  git -C "${HAZE_SRC_DIR}" config user.email 'patches@haze.invalid'
  git -C "${HAZE_SRC_DIR}" config commit.gpgsign false
  # Chromium is ~400k files: keep git from garbage-collecting mid-patch and use
  # the index features that make status on a tree this size bearable.
  git -C "${HAZE_SRC_DIR}" config gc.auto 0
  haze_src_git_settings
  git -C "${HAZE_SRC_DIR}" config core.untrackedCache true
  git -C "${HAZE_SRC_DIR}" config index.version 4

  # --force because Chromium's own .gitignore excludes directories that gclient
  # would normally manage but the tarball really ships. The baseline has to be
  # the whole tree, or exported patches would be measured against a partial one.
  haze_run git -C "${HAZE_SRC_DIR}" add --all --force
  haze_run git -C "${HAZE_SRC_DIR}" commit --quiet \
    -m "baseline ${version}" \
    -m "Chromium ${version} with ungoogled-chromium $(haze_ungoogled_tag) applied: pruning, patches and domain substitution. Haze patches sit on top of this commit."
  git -C "${HAZE_SRC_DIR}" tag baseline
  haze_info "baseline: $(git -C "${HAZE_SRC_DIR}" log --oneline -1)"
  haze_info "tracked files: $(git -C "${HAZE_SRC_DIR}" ls-files | wc -l | tr -d ' ')"
}

main "$@"
