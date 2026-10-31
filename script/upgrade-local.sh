#!/usr/bin/env bash
#
# upgrade-local — rebuild our local MiMo (OSC 7501 fix) against the latest
# upstream release, and install it.
#
# Why this exists: PR #2746 (the iTerm2 working/Idle fix) is not merged upstream,
# so we carry it ourselves. This script cherry-picks the fix onto the newest
# upstream tag and builds a binary you can swap in.
#
# Usage:
#   ./script/upgrade-local.sh            # build + install latest upstream + our fix
#   ./script/upgrade-local.sh --check    # report what would happen, change nothing
#   ./script/upgrade-local.sh --force    # rebuild even if already current
#
# Install safety: a build is NEVER written over a binary that is currently
# executing. If the live path is in the way, the build lands as
# mimo-local-<version> and the script tells you when to swap.
#
set -euo pipefail

FIX_BRANCH="fix/iterm2-osc-7501-program-status"
FIX_COMMIT="0476455"
BIN_DIR="$HOME/.mimocode/bin"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE_NAME="mimo-local"

log()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'upgrade-local: %s\n' "$*" >&2; exit 1; }

# --- 1. resolve bun (pinned by packageManager; build refuses any other) --------
bun_bin=""
for cand in \
  "$HOME/.local/share/fnm/node-versions/v24.22.0/installation/bin/bun" \
  "$(command -v bun || true)"; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  if "$cand" --version 2>/dev/null | grep -qx '1\.3\.14'; then bun_bin="$cand"; break; fi
done
[ -n "$bun_bin" ] || die "bun 1.3.14 not found (build requires the pinned version)"

# --- 2. what would we build against? -----------------------------------------
cd "$REPO_DIR"

git fetch --tags --quiet origin 2>/dev/null || true
UPSTREAM_TAG="$(git tag --list 'v*' --sort=-v:refname | head -1)"
[ -n "$UPSTREAM_TAG" ] || die "no v* tags found"

# our fix is on a branch in this repo; make sure the commit is present
git rev-parse --verify --quiet "$FIX_COMMIT^{commit}" >/dev/null \
  || die "fix commit $FIX_COMMIT not found in $REPO_DIR"

UPSTREAM_VER="${UPSTREAM_TAG#v}"
BUILD_VERSION="${UPSTREAM_VER}-local.${FIX_COMMIT}"
DEST="$BIN_DIR/$LIVE_NAME-$BUILD_VERSION"

# --- 3. what's installed right now? ------------------------------------------
CURRENT=""
[ -x "$BIN_DIR/$LIVE_NAME" ] && CURRENT="$("$BIN_DIR/$LIVE_NAME" --version 2>/dev/null | tr -d '\n' || true)"

step "plan"
log "  upstream tag    $UPSTREAM_TAG"
log "  our fix         $FIX_COMMIT ($FIX_BRANCH)"
log "  build version   $BUILD_VERSION"
log "  current         ${CURRENT:-<none>}"
log "  install to      $DEST"

if [ "${1:-}" = "--check" ]; then
  step "check only — nothing changed"
  exit 0
fi

if [ "$CURRENT" = "$BUILD_VERSION" ] && [ "${1:-}" != "--force" ]; then
  step "already current ($BUILD_VERSION) — use --force to rebuild"
  exit 0
fi

if [ -x "$DEST" ] && [ "${1:-}" != "--force" ]; then
  step "build already exists at $DEST — swapping, skipping rebuild"
else
  # --- 4. build in a scratch worktree at the tag, fix applied ----------------
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/mimo-local-build.XXXXXX")"
  cleanup() { git worktree remove --force "$WORK/wt" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
  trap cleanup EXIT

  step "checking out $UPSTREAM_TAG in a scratch worktree"
  git worktree add --quiet --detach "$WORK/wt" "$UPSTREAM_TAG"

  step "cherry-picking our fix ($FIX_COMMIT)"
  if ! git -C "$WORK/wt" cherry-pick --quiet "$FIX_COMMIT" 2>/dev/null; then
    git -C "$WORK/wt" cherry-pick --abort >/dev/null 2>&1 || true
    die "cherry-pick of $FIX_COMMIT failed on $UPSTREAM_TAG — the fix conflicts with upstream. Fix it manually in $REPO_DIR"
  fi

  step "installing deps (bun ci — frozen lockfile)"
  ( cd "$WORK/wt" && "$bun_bin" ci --silent >/dev/null ) \
    || die "bun ci failed"

  step "building $BUILD_VERSION"
  ( cd "$WORK/wt" && \
    MIMOCODE_CHANNEL=local \
    MIMOCODE_VERSION="$BUILD_VERSION" \
    "$bun_bin" run --cwd packages/cli script/build.ts --single ) >/dev/null \
    || die "build failed"

  BUILT="$WORK/wt/packages/cli/dist/mimocode-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/')/bin/mimo"
  [ -x "$BUILT" ] || die "built binary not found at $BUILT"

  step "staging $DEST"
  mkdir -p "$BIN_DIR"
  cp "$BUILT" "$DEST"
  chmod +x "$DEST"
fi

# --- 5. install: never overwrite a live executable ----------------------------
step "install"
LIVE_PID="$(pgrep -x "$LIVE_NAME" 2>/dev/null | head -1 || true)"
if [ -n "$LIVE_PID" ]; then
  log "  LIVE: $LIVE_NAME is running (pid $LIVE_PID) — not touching $BIN_DIR/$LIVE_NAME"
  log "  build is at: $DEST"
  log "  when that session is closed, run:"
  log "      mv $DEST $BIN_DIR/$LIVE_NAME"
else
  # extra guard: resolved exec path of anything named mimo*
  RESOLVED="$(for p in $(pgrep -f 'mimo' 2>/dev/null || true); do lsof -p "$p" 2>/dev/null | awk '$4=="txt"{print $NF; exit}'; done | grep -F "/$LIVE_NAME" | head -1 || true)"
  if [ -n "$RESOLVED" ]; then
    log "  LIVE: $RESOLVED is an executing path — not overwriting it"
    log "  build is at: $DEST"
  else
    cp "$DEST" "$BIN_DIR/$LIVE_NAME"
    chmod +x "$BIN_DIR/$LIVE_NAME"
    log "  installed -> $BIN_DIR/$LIVE_NAME"
  fi
fi

step "done"
"$BIN_DIR/$LIVE_NAME" --version 2>/dev/null || true
log ""
log "verify the fix is present:"
log "  strings -a $BIN_DIR/$LIVE_NAME | grep -c 'Permission needs input'   # want 1"
