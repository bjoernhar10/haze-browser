#!/usr/bin/env bash
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# scripts/netcheck.sh [dev|release]
#
# The privacy baseline from docs/SPEC.md: a fresh profile sitting idle makes
# zero network requests. This starts Haze with a brand-new profile on
# about:blank, leaves it alone for five minutes (HAZE_NETCHECK_SECONDS), and
# then lists everything that went out, with the Chromium code that sent it.
#
# Two independent views:
#   - a NetLog (--log-net-log), which records every URL request, host name
#     lookup and connection the network service makes, and the traffic
#     annotation that names the code behind each URL request;
#   - `ss`, sampled every second for sockets owned by the browser's processes,
#     which also sees traffic that bypasses the network service.
#
# Exits 0 when nothing went out, 1 otherwise. Everything it writes stays in
# build/profiles/netcheck-<timestamp>/.

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HAZE_SCRIPT_NAME="netcheck.sh"

main() {
  local config="${1:-dev}" out
  case "${config}" in
    dev) out="${HAZE_OUT_DEV}" ;;
    release) out="${HAZE_OUT_RELEASE}" ;;
    *) haze_die "usage: scripts/netcheck.sh [dev|release]" ;;
  esac
  # ss and /proc are Linux; macOS and Windows need their own socket sampling.
  [ "$(haze_platform)" = linux ] || haze_die "netcheck.sh runs on Linux only so far"
  haze_require_python
  haze_require_cmd ss pgrep
  local chrome="${out}/chrome"
  haze_require_file "${chrome}"
  if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
    haze_die "no display: the check runs the real browser UI, not headless mode"
  fi

  local seconds="${HAZE_NETCHECK_SECONDS:-300}"
  local run
  run="${HAZE_PROFILE_DIR}/netcheck-$(date -u +%Y%m%dT%H%M%SZ)"
  local profile="${run}/profile" netlog="${run}/netlog.json"
  local sockets="${run}/sockets.txt" report="${run}/report.txt"
  mkdir -p "${profile}" "${run}/xdg-config" "${run}/xdg-cache"
  : > "${sockets}"

  haze_step "fresh profile, idle on about:blank for ${seconds}s"
  haze_info "run dir ${run}"
  # Crashpad keeps its database in the *default* profile dir whatever
  # --user-data-dir says, so XDG_CONFIG_HOME is redirected too, or the run
  # would touch ~/.config/haze. No --no-first-run: a fresh profile's first
  # run is part of what is being measured.
  XDG_CONFIG_HOME="${run}/xdg-config" XDG_CACHE_HOME="${run}/xdg-cache" \
    "${chrome}" \
    --user-data-dir="${profile}" \
    --log-net-log="${netlog}" \
    --net-log-capture-mode=Default \
    about:blank \
    > "${run}/chrome.log" 2>&1 &
  local pid=$!

  local waited=0
  while [ "${waited}" -lt "${seconds}" ]; do
    kill -0 "${pid}" 2>/dev/null || haze_die "the browser exited early; see ${run}/chrome.log"
    sample_sockets "${profile}" >> "${sockets}"
    sleep 1
    waited=$((waited + 1))
  done

  haze_step "stopping the browser"
  # SIGTERM lets the browser shut down cleanly and close the NetLog; killing
  # its helpers by name instead would leave a truncated log and a dump.
  kill -TERM "${pid}"
  local i
  for i in $(seq 1 30); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "${pid}" 2>/dev/null; then
    haze_warn "the browser did not exit in 30s; killing it"
    kill -KILL "${pid}"
  fi
  wait "${pid}" 2>/dev/null || true

  haze_step "report"
  local status=0
  "${HAZE_PYTHON}" -I "${HAZE_SCRIPTS_DIR}/netlog_report.py" \
    "${netlog}" \
    "${HAZE_SRC_DIR}/tools/traffic_annotation/summary/annotations.xml" \
    "${sockets}" | tee "${report}" || status=$?
  if [ "${status}" -eq 0 ]; then
    haze_info "zero requests"
  else
    haze_warn "requests went out; details in ${report}"
  fi
  return "${status}"
}

# Every TCP/UDP socket owned by a process of this browser instance. Child
# processes carry --user-data-dir on their command line too.
sample_sockets() {
  local profile="$1" pids pattern
  pids=$(pgrep -f -- "--user-data-dir=${profile}" | tr '\n' ',' | sed 's/,$//')
  [ -n "${pids}" ] || return 0
  pattern=$(printf '%s' "${pids}" | sed 's/,/|/g')
  ss -tunapH 2>/dev/null | grep -E "pid=(${pattern})," || true
}

main "$@"
