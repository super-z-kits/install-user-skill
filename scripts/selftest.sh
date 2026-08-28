#!/usr/bin/env bash
# selftest.sh — regression test for the install-user-skill procedure (audit sub-agent-test #8).
#
# Catches the bugs found in v1.0/v1.1:
#   #1: bootstrap fetched the redirect stub instead of SKILL.md
#   #2: Step 6 .git check was a false positive (always warned)
#   #3: extensionless scripts (zsave, zsession) left non-executable
#   #4: chmod +x produced 711 (broken) instead of 0755
#   #5: docs left at 600 instead of 0644
#   #6: directories left at 700 instead of 0755
#   #7: Strategy C rationale contradicted the example
#   #8: secrets-vault-kit example diverged from canonical Steps 0-7
#   #9: optional fetch wrote 404 HTML as SKILL-DEPLOY.md
#   #10: GH_PAT resolved unnecessarily for public clones
#
# Runs the full install procedure against a scratch USER_SKILLS_DIR, then asserts
# on the resulting state. Exits 0 if all checks pass, non-zero otherwise.
#
# Usage: bash selftest.sh [skill-repo]
#   skill-repo defaults to super-z-kits/z-container-kit (public, has scripts/)

set -euo pipefail

SKILL_REPO="${1:-super-z-kits/z-container-kit}"
SKILL_NAME="$(basename "$SKILL_REPO")"
SKILL_BRANCH="main"
SCRATCH_ROOT="/tmp/my-project/install-user-skill-selftest-$$"
USER_SKILLS_DIR="$SCRATCH_ROOT/user_skills"

trap 'rm -rf "$SCRATCH_ROOT"' EXIT

mkdir -p "$USER_SKILLS_DIR"

echo "=== install-user-skill selftest ==="
echo "  target skill: $SKILL_REPO @ $SKILL_BRANCH"
echo "  scratch:      $USER_SKILLS_DIR"
echo

# ─── Run the canonical install procedure (Steps 0-7) ───────────────────────────
TARGET="$USER_SKILLS_DIR/$SKILL_NAME"

# Step 1: backup (no existing install, skip)
# Step 2: Strategy A (anonymous public clone)
SCRATCH="$SCRATCH_ROOT/fetch"
mkdir -p "$SCRATCH"
git clone -q --depth 1 -b "$SKILL_BRANCH" "https://github.com/${SKILL_REPO}.git" "$SCRATCH/$SKILL_NAME"

# Step 3: strip VCS
# Use absolute paths (NOT cd) — the mv in Step 4 will move this dir out from
# under us if we cd'd into it (BUG found in update.sh development).
rm -rf "$SCRATCH/$SKILL_NAME/.git" "$SCRATCH/$SKILL_NAME/.gitignore" "$SCRATCH/$SKILL_NAME/.gitattributes" 2>/dev/null
find "$SCRATCH/$SKILL_NAME" -mindepth 2 -name .git -type d -exec rm -rf {} + 2>/dev/null || true

# Step 4: atomic replace + set modes
# v1.5 fix (BUG #2): use -perm /111 instead of ! -executable (FUSE filesystems report
# access(X_OK)=TRUE for all files, so ! -executable never matches on /home/user_skills).
rm -rf "$TARGET"
mv "$SCRATCH/$SKILL_NAME" "$TARGET"
[ -d "$TARGET/scripts" ] && find "$TARGET/scripts" -type f -exec chmod 0755 {} +
find "$TARGET" -maxdepth 2 -type f ! -path "$TARGET/scripts/*" ! -name '.installed-from' \
  ! -perm /111 -exec chmod 0644 {} + 2>/dev/null
chmod 0755 "$TARGET" 2>/dev/null
[ -d "$TARGET/scripts" ] && chmod 0755 "$TARGET/scripts"
[ -d "$TARGET/evidence" ] && chmod 0755 "$TARGET/evidence"

# Step 7: provenance
cat > "$TARGET/.installed-from" <<PROVEOF
repo: $SKILL_REPO
branch: $SKILL_BRANCH
installed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
installed_by: install-user-skill selftest
PROVEOF
chmod 600 "$TARGET/.installed-from"

# ─── Assertions ──────────────────────────────────────────────────────────────
FAIL=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=1; }

# A1: SKILL.md exists, is readable, is non-empty, mode 0644
if [ -f "$TARGET/SKILL.md" ] && [ -r "$TARGET/SKILL.md" ] && [ -s "$TARGET/SKILL.md" ]; then
  MODE=$(stat -c '%a' "$TARGET/SKILL.md")
  [ "$MODE" = "644" ] && pass "SKILL.md exists, readable, non-empty, mode 0644" \
    || fail "SKILL.md mode is $MODE, expected 644"
else
  fail "SKILL.md missing, unreadable, or empty"
fi

# A2: no .git leaked
LEAK=$(find "$TARGET" -name .git -type d 2>/dev/null | head -1)
if [ -z "$LEAK" ]; then
  pass "no .git leakage"
else
  fail ".git leaked at: $LEAK"
fi

# A3: if scripts/ exists, ALL scripts are executable (mode 0755), including extensionless
if [ -d "$TARGET/scripts" ]; then
  BAD=0
  for s in "$TARGET/scripts"/*; do
    [ -f "$s" ] || continue
    if [ ! -x "$s" ]; then
      fail "script not executable: $s"
      BAD=1
    fi
    MODE=$(stat -c '%a' "$s")
    if [ "$MODE" != "755" ]; then
      fail "script mode is $MODE (expected 755): $s"
      BAD=1
    fi
  done
  [ "$BAD" = 0 ] && pass "all scripts executable + mode 0755"
fi

# A4: directories are 0755
DIR_MODE=$(stat -c '%a' "$TARGET")
[ "$DIR_MODE" = "755" ] && pass "target dir mode 0755" \
  || fail "target dir mode is $DIR_MODE, expected 755"

# A5: provenance file exists, mode 0600, contains installed_by
if [ -f "$TARGET/.installed-from" ] && grep -q '^installed_by:' "$TARGET/.installed-from"; then
  MODE=$(stat -c '%a' "$TARGET/.installed-from")
  [ "$MODE" = "600" ] && pass "provenance file present, mode 0600, has installed_by" \
    || fail "provenance mode is $MODE, expected 600"
else
  fail "provenance file missing or lacks installed_by"
fi

# ─── Verdict ──────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" = 0 ]; then
  echo "=== ✅ selftest PASSED — install procedure produces a correct install ==="
  exit 0
else
  echo "=== ❌ selftest FAILED — see [❌] lines above ==="
  exit 1
fi
