# Haze patches

Every change to an existing Chromium file is a patch in `patches/`. New code
lives in `overlay/` and needs no patch. Patches are applied in the order given
by `patches/series`; this table lists them in that same order.

Rules are in `CLAUDE.md`: one patch = one concern, each with a `Subject`, a
`Why` of one to three sentences and `Security-relevant: yes/no` in its header.
Touching `sandbox/`, `content/browser/renderer_host/`, `net/cert/`,
`components/permissions/` or `third_party/blink/` needs a reason in the header.

Regenerate patches from `build/src` with `scripts/patch.sh export`, and verify
that they apply with `scripts/patch.sh check`.

## Patch table

| # | Patch | Area | Subject | Security-relevant |
|---|---|---|---|---|
| — | — | — | _no patches yet_ | — |

## Areas

| Area | What belongs there |
|---|---|
| `core/` | Build files, GN wiring, branding, version plumbing |
| `privacy/` | Hooks for the content blocker, fingerprinting and tracking-parameter stripping |
| `security/` | Hardening hooks; never weakens upstream protections |
| `ui/` | Shared desktop UI hooks (sidebar, frame, tabs) |
| `mac/` | macOS-only hooks (AppKit, window material, native menus) |
| `win/` | Windows-only hooks (Mica, DWM, frame) |
| `linux/` | Linux-only hooks (Wayland, X11, KWin blur) |
