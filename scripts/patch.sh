#!/usr/bin/env bash
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Haze's patch workflow.
#
#   scripts/patch.sh apply     reset build/src to the baseline and apply patches/series
#   scripts/patch.sh export    write the commits after the baseline back to patches/
#   scripts/patch.sh check     apply the whole series onto a clean baseline
#
# A Haze patch is a git commit on top of the `baseline` tag in build/src, and a
# git-format-patch mailbox in patches/, listed in patches/series. `git am`
# recreates one commit per file, keeping its author and date, which is what
# makes the round trip stable: export of an unchanged tree rewrites the same
# bytes. The format-patch flags below exist for that reason — a commit hash, a
# git version signature or a terminal-width-dependent diffstat would all make
# export produce a diff on every run.
#
# Each commit message carries the header from CLAUDE.md:
#
#   <subject>
#
#   Why: one to three sentences.
#   Security-relevant: yes|no
#   Area: core|privacy|security|ui|mac|win|linux
#
# Area decides which patches/<area>/ directory the patch is written to; series
# decides the order patches are applied in.

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HAZE_SCRIPT_NAME="patch.sh"

HAZE_PATCH_AREAS='core privacy security ui mac win linux'

# Deterministic patch rendering. Every one of these flags removes a source of
# churn that would otherwise make an unchanged export show up as a diff.
format_patch_flags() {
  printf '%s\n' \
    --zero-commit \
    --no-signature \
    --no-numbered \
    --no-renames \
    --binary \
    --stat=72 \
    --stat-graph-width=10
}

usage() {
  cat >&2 <<'USAGE'
usage: scripts/patch.sh apply|export|check

  apply   reset build/src to the baseline commit and apply patches/series in
          order, one commit per patch. Refuses to run on a dirty tree.
  export  write every commit after the baseline back to patches/ and rewrite
          patches/series. Exporting an unchanged tree produces no diff.
  check   apply the whole series onto a clean baseline in a scratch worktree.
          Exits 1 naming the first patch that does not apply.
USAGE
  exit 2
}

main() {
  haze_require_cmd git
  case "${1:-}" in
    apply) require_repo; cmd_apply ;;
    export) require_repo; cmd_export ;;
    check) require_repo; cmd_check ;;
    *) usage ;;
  esac
}

require_repo() {
  if [ ! -d "${HAZE_SRC_DIR}/.git" ]; then
    haze_die "no git repo at ${HAZE_SRC_DIR}; run scripts/fetch.sh and scripts/prepare.sh first"
  fi
  if ! git -C "${HAZE_SRC_DIR}" rev-parse -q --verify refs/tags/baseline >/dev/null; then
    haze_die "${HAZE_SRC_DIR} has no 'baseline' tag; re-run scripts/prepare.sh"
  fi
  haze_exclude_generated
}

src_git() {
  git -C "${HAZE_SRC_DIR}" "$@"
}

# --- apply -------------------------------------------------------------------

cmd_apply() {
  if [ -n "$(src_git status --porcelain)" ]; then
    haze_error "build/src has uncommitted changes; apply would discard them:"
    src_git status --short | head -10 >&2
    haze_die "commit them, or run: git -C build/src reset --hard"
  fi

  haze_step "resetting build/src to the baseline"
  haze_run src_git reset --hard --quiet baseline

  if [ ! -s "${HAZE_SERIES_FILE}" ]; then
    haze_info "patches/series is empty; nothing to apply"
    return 0
  fi

  local count=0 rel abs
  while IFS= read -r rel; do
    abs="${HAZE_PATCHES_DIR}/${rel}"
    haze_require_file "${abs}"
    haze_info "applying ${rel}"
    if ! src_git am --quiet "${abs}"; then
      src_git am --abort >/dev/null 2>&1 || true
      haze_die "patch does not apply: ${rel}"
    fi
    count=$((count + 1))
  done < <(read_series)

  haze_step "applied ${count} patch(es)"
  src_git --no-pager log --oneline "baseline..HEAD" >&2
}

# Series entries, with blank lines and # comments dropped.
read_series() {
  if [ -f "${HAZE_SERIES_FILE}" ]; then
    sed -E 's/[[:space:]]*#.*$//; /^[[:space:]]*$/d' "${HAZE_SERIES_FILE}"
  fi
}

# --- export ------------------------------------------------------------------

cmd_export() {
  local commits
  commits=$(src_git rev-list --reverse baseline..HEAD)
  if [ -z "${commits}" ]; then
    haze_info "no commits after the baseline; nothing to export"
    # Still rewrite an empty series so a removed last patch is noticed.
    : > "${HAZE_SERIES_FILE}"
    prune_stale_patches ''
    return 0
  fi

  local staging
  staging=$(mktemp -d)
  # shellcheck disable=SC2064  # expand the path now, not at trap time
  trap "rm -rf '${staging}'" EXIT

  local sha subject area slug rel kept='' flags
  flags=$(format_patch_flags | tr '\n' ' ')
  for sha in ${commits}; do
    subject=$(src_git log -1 --format='%s' "${sha}")
    area=$(trailer "${sha}" 'Area')
    validate_commit "${sha}" "${subject}" "${area}"
    slug=$(slugify "${subject}")
    rel="${area}/${slug}.patch"
    if printf '%s\n' ${kept} | grep -qxF "${rel}"; then
      haze_die "two commits produce the same patch file ${rel}; give them different subjects"
    fi
    mkdir -p "${staging}/${area}"
    # shellcheck disable=SC2086  # flags is a list of literal options
    src_git format-patch ${flags} -1 "${sha}" --stdout > "${staging}/${rel}"
    kept="${kept} ${rel}"
    haze_info "${rel}"
  done

  # Move the staged files into patches/ and drop any that no longer belong.
  local f
  for f in ${kept}; do
    mkdir -p "${HAZE_PATCHES_DIR}/$(dirname "${f}")"
    cp "${staging}/${f}" "${HAZE_PATCHES_DIR}/${f}"
  done
  prune_stale_patches "${kept}"

  printf '%s\n' ${kept} > "${HAZE_SERIES_FILE}"
  haze_step "exported $(printf '%s\n' ${kept} | wc -l | tr -d ' ') patch(es)"
}

# Remove patch files under patches/ that the current history no longer produces.
prune_stale_patches() {
  local kept="$1" existing
  while IFS= read -r existing; do
    [ -n "${existing}" ] || continue
    if ! printf '%s\n' ${kept} | grep -qxF "${existing}"; then
      haze_info "removing stale ${existing}"
      rm -f "${HAZE_PATCHES_DIR}/${existing}"
    fi
  done < <(cd "${HAZE_PATCHES_DIR}" && find . -name '*.patch' -type f | sed 's|^\./||' | sort)
}

trailer() {
  src_git log -1 --format='%B' "$1" \
    | sed -nE "s/^$2:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" \
    | head -1
}

# The header from CLAUDE.md is not decoration: without it a patch cannot be
# placed in patches/ and its security impact is unrecorded.
validate_commit() {
  local sha="$1" subject="$2" area="$3" why security
  why=$(trailer "${sha}" 'Why')
  security=$(trailer "${sha}" 'Security-relevant')
  local short
  short=$(src_git log -1 --format='%h %s' "${sha}")

  [ -n "${subject}" ] || haze_die "commit ${short} has no subject"
  [ -n "${why}" ] || haze_die "commit ${short} has no 'Why:' line"
  case "${security}" in
    yes | no) ;;
    *) haze_die "commit ${short} needs 'Security-relevant: yes' or 'no', got '${security}'" ;;
  esac
  [ -n "${area}" ] || haze_die "commit ${short} has no 'Area:' line (one of: ${HAZE_PATCH_AREAS})"
  if ! printf '%s\n' ${HAZE_PATCH_AREAS} | grep -qxF "${area}"; then
    haze_die "commit ${short} has unknown Area '${area}'; use one of: ${HAZE_PATCH_AREAS}"
  fi
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e "s/'//g" -e 's/’//g' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-60 \
    | sed -E 's/-+$//'
}

# --- check -------------------------------------------------------------------

# Applies the series to a scratch worktree's index. --no-checkout keeps git
# from materialising half a million files for a check that only has to answer
# "does this still apply".
cmd_check() {
  local wt="${HAZE_BUILD_DIR}/patchcheck"
  cleanup_worktree "${wt}"
  # shellcheck disable=SC2064
  trap "cd '${HAZE_ROOT}'; git -C '${HAZE_SRC_DIR}' worktree remove --force '${wt}' >/dev/null 2>&1 || true" EXIT

  haze_step "checking patches/series against a clean baseline"
  src_git worktree add --no-checkout --detach --quiet "${wt}" baseline
  git -C "${wt}" read-tree baseline

  if [ ! -s "${HAZE_SERIES_FILE}" ]; then
    haze_info "patches/series is empty; nothing to check"
    return 0
  fi

  local rel abs count=0
  while IFS= read -r rel; do
    abs="${HAZE_PATCHES_DIR}/${rel}"
    if [ ! -f "${abs}" ]; then
      haze_error "series lists a patch that does not exist: ${rel}"
      exit 1
    fi
    # pipefail (set in lib.sh) makes the pipeline fail when git apply does.
    if ! git -C "${wt}" apply --cached --whitespace=nowarn "${abs}" 2>&1 | sed 's/^/    /' >&2; then
      haze_error "patch does not apply: ${rel}"
      exit 1
    fi
    count=$((count + 1))
    haze_info "ok  ${rel}"
  done < <(read_series)

  haze_step "all ${count} patch(es) apply cleanly"
}

cleanup_worktree() {
  local wt="$1"
  if [ -e "${wt}" ]; then
    src_git worktree remove --force "${wt}" >/dev/null 2>&1 || rm -rf "${wt}"
  fi
  src_git worktree prune >/dev/null 2>&1 || true
}

main "$@"
