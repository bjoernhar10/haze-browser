# Haze patches

Every change to an existing Chromium file is a patch in `patches/`. New code
lives in `overlay/` and needs no patch. Patches are applied in the order given
by `patches/series`; this table lists them in that same order.

Rules are in `CLAUDE.md`: one patch = one concern, each with a `Subject`, a
`Why` of one to three sentences and `Security-relevant: yes/no` in its header.
Touching `sandbox/`, `content/browser/renderer_host/`, `net/cert/`,
`components/permissions/` or `third_party/blink/` needs a reason in the header.

## The workflow

A Haze patch exists in two forms, and `scripts/patch.sh` converts between them:

- **a git commit** on top of the `baseline` tag in `build/src`, which is what
  you work with while writing it, and
- **a `git format-patch` mailbox** in `patches/<area>/<slug>.patch`, listed in
  `patches/series`, which is what is committed to this repo.

```sh
scripts/patch.sh apply     # baseline + patches/series -> commits in build/src
scripts/patch.sh export    # commits in build/src -> patches/ + series
scripts/patch.sh check     # does the whole series still apply to a clean baseline?
```

### Writing a patch

1. `scripts/patch.sh apply` so `build/src` holds the baseline plus the current
   series, one commit per patch.
2. Edit the Chromium files in `build/src`. New Haze code does **not** go here:
   it goes in `overlay/`, which `scripts/build.sh` syncs to `build/src/haze/`.
3. Commit in `build/src` with the header below.
4. `scripts/patch.sh export`, then commit the changed files in this repo.

To change an existing patch, `apply`, edit, `git commit --amend` or
`git rebase -i baseline` in `build/src`, then `export` again.

### The patch header

Every commit after the baseline needs this, and `export` refuses to run without
it:

```
Build Haze's sources into the browser

Why: Gives Haze's own code a single entry point in the Chromium build graph,
so later steps only add deps inside //haze instead of touching chrome/.
Security-relevant: no
Area: core
```

- **Subject** — imperative, one line. The patch file name is derived from it.
- **Why** — one to three sentences. What this buys, not what the diff does.
- **Security-relevant** — `yes` or `no`, nothing else.
- **Area** — one of `core`, `privacy`, `security`, `ui`, `mac`, `win`, `linux`.
  It decides which `patches/<area>/` directory the file is written to.

Touching `sandbox/`, `content/browser/renderer_host/`, `net/cert/`,
`components/permissions/` or `third_party/blink/` needs a reason in the header
as well.

### Why export is reproducible

`export` has to be a fixed point: running it on an unchanged tree must produce
no diff, or every step would carry patch churn. Three things would otherwise
change on each run, and `patch.sh` turns all of them off:

- the commit hash in the `From` line (`--zero-commit`),
- the trailing git version signature (`--no-signature`),
- the diffstat width, which depends on the terminal (`--stat=72
  --stat-graph-width=10`).

`apply` uses `git am`, which restores each commit's original author and date
from the patch file, so those round-trip too. `--no-renames` keeps diffs
literal, and `--binary` means a patch that touches a binary file still applies.

`export` also deletes patch files that no longer match any commit, so dropping
a commit and re-exporting really removes the patch.

### What `check` verifies

`check` adds a scratch worktree at `build/patchcheck` with `--no-checkout` and
applies the series to its index with `git apply --cached`. It answers "does
every patch still apply to a clean baseline" without materialising half a
million files, so it is fast enough to run at the end of every step. It is
stricter than `apply`: no 3-way merge fallback. On the first failure it names
the patch and exits 1.

### What is excluded from git in build/src

`build/src` is a git repo whose history *is* the patch series, so generated
files must stay invisible to it. `scripts/patch.sh` and `scripts/build.sh` keep
these in `build/src/.git/info/exclude`:

| Path | Why |
|---|---|
| `/haze/` | A copy of `overlay/`, which is the source of truth |
| `/third_party/node/linux/` | Link to the host `node`; Chromium's copy is pruned |
| `/third_party/gperf/cipd/` | Link to the host `gperf`; same reason |

`out/` is already covered by Chromium's own `.gitignore`.

## Patch table

| # | Patch | Area | Subject | Security-relevant |
|---|---|---|---|---|
| 1 | `core/build-hazes-sources-into-the-browser.patch` | core | Build Haze's sources into the browser | no |

One dep line in `chrome/browser/BUILD.gn` adds `//haze` to the browser's
`deps`, which puts `overlay/BUILD.gn`'s `group("haze")` in the build graph.
`//chrome:chrome` was the wrong place for it: upstream states that `ninja
chrome` builds `chrome_initial` instead, and that target does not exist on
macOS, so a dep there would not work on all three platforms.

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
