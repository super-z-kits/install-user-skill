#!/usr/bin/env bash
# update.sh — one-command update flow for an installed skill
#
# Wraps the install-user-skill procedure for the update case (skill already
# installed). Handles:
#   1. Pre-update local-modification check (warns if user has edited files)
#   2. Step 1 backup (mandatory on update — preserves the previous version)
#   3. Steps 2-7 of the canonical procedure (fetch, strip, replace, verify,
#      provenance)
#   4. Post-update verification (asserts install succeeded)
#   5. Reports what changed (commit messages between old and new)
#
# For rollback, see the doc's "Update flow → Rollback" section, or:
#   ls -dt $USER_SKILLS_DIR/<skill>.pre-update-backup-* | head -1
#
# Usage:
#   update.sh <skill-name> [repo] [branch]
#     - if repo/branch omitted, reads from .installed-from (updates in place)
#     - if repo/branch provided, switches to that source (e.g. testing a fork)
#
#   update.sh z-container-kit                    # update from same source
#   update.sh z-container-kit super-z-kits/z-container-kit v2.3.3   # pin to tag
#   update.sh z-container-kit zikomolapoutl/z-container-kit-v2 audit/foo  # test fork
#
# Env vars:
#   USER_SKILLS_DIR        default /home/user_skills
#   SKILL_REPO_PRIVATE=1  set if the repo is private (resolves GH_PAT from Doppler)
#   GH_PAT                pre-resolved PAT (skips Doppler fetch)
#   SKILL_COMMIT           pin to a specific SHA (overrides branch)
#   DRY_RUN=1              check + report what would change, don't actually update

set -euo pipefail

USER_SKILLS_DIR="${USER_SKILLS_DIR:-/home/user_skills}"

# ─── arg parsing ──────────────────────────────────────────────────────────────
SKILL_NAME="${1:-}"
SKILL_REPO="${2:-}"
SKILL_BRANCH="${3:-main}"
SKILL_COMMIT="${SKILL_COMMIT:-}"

if [ -z "$SKILL_NAME" ]; then
  cat <<EOF >&2
update.sh — one-command update flow for an installed skill

Usage: update.sh <skill-name> [repo] [branch]

If repo/branch are omitted, reads from the existing .installed-from file
(updates from the same source). If provided, switches to that source.

Env vars:
  USER_SKILLS_DIR        default /home/user_skills
  SKILL_REPO_PRIVATE=1   set if the repo is private (resolves GH_PAT from Doppler)
  GH_PAT                 pre-resolved PAT (skips Doppler fetch)
  SKILL_COMMIT=<sha>     pin to a specific SHA (overrides branch)
  DRY_RUN=1               check + report what would change, don't actually update

Examples:
  update.sh z-container-kit                                    # update from same source
  update.sh z-container-kit super-z-kits/z-container-kit v2.3.3 # pin to tag
  update.sh z-container-kit zikomolapoutl/z-container-kit-v2 audit/foo  # test fork
EOF
  exit 2
fi

TARGET="$USER_SKILLS_DIR/$SKILL_NAME"

# ─── pre-flight: read existing install's provenance if present ────────────────
if [ -d "$TARGET" ] && [ -f "$TARGET/.installed-from" ]; then
  if [ -z "$SKILL_REPO" ]; then
    SKILL_REPO=$(awk -F': ' '/^repo:/ {print $2}' "$TARGET/.installed-from")
    SKILL_BRANCH=$(awk -F': ' '/^branch:/ {print $2}' "$TARGET/.installed-from")
    echo "[info] using source from existing .installed-from: $SKILL_REPO@$SKILL_BRANCH"
  fi
  OLD_COMMIT=$(awk -F': ' '/^commit:/ {print $2}' "$TARGET/.installed-from" || true)
  OLD_INSTALLED_AT=$(awk -F': ' '/^installed_at:/ {print $2}' "$TARGET/.installed-from" || true)
else
  OLD_COMMIT=""
  OLD_INSTALLED_AT=""
fi

if [ -z "$SKILL_REPO" ]; then
  echo "[fail] no existing install at $TARGET and no repo provided"
  echo "       usage: update.sh $SKILL_NAME <owner/repo> [branch]"
  exit 2
fi

echo "=== update $SKILL_NAME ==="
echo "  target:  $TARGET"
echo "  source:  $SKILL_REPO@$SKILL_BRANCH${SKILL_COMMIT:+ @ $SKILL_COMMIT}"
[ -n "$OLD_INSTALLED_AT" ] && echo "  old install: $OLD_INSTALLED_AT${OLD_COMMIT:+ (commit ${OLD_COMMIT:0:8})}"
echo

# ─── GH_PAT resolution ───────────────────────────────────────────────────────
# Always try to resolve GH_PAT (even for public repos — anonymous API calls are
# limited to 60/hour, easily exhausted; authenticated gets 5000/hour).
GH_PAT="${GH_PAT:-}"
if [ -z "$GH_PAT" ] && [ -f /home/user_skills/zk-doppler.env ]; then
  echo "[info] resolving GH_PAT from Doppler (avoids anonymous API rate limits)..."
  set -a; source /home/user_skills/zk-doppler.env 2>/dev/null; set +a
  if [ -n "${DOPPLER_PT:-}" ]; then
    GH_PAT=$(curl -sS -H "Authorization: Bearer $DOPPLER_PT" \
      "https://api.doppler.com/v3/configs/config/secrets?project=${DOPPLER_PROJECT:-agent-bootstrap}&config=${DOPPLER_CONFIG:-prd}" \
      | jq -r '.secrets.GH_PAT.computed // empty')
    [ -n "$GH_PAT" ] && echo "  [ok] GH_PAT resolved (length ${#GH_PAT})"
  fi
fi

# Helper: authenticated GitHub API call (uses GH_PAT if available)
gh_api() {
  if [ -n "${GH_PAT:-}" ]; then
    curl -fsSL -H "Authorization: Bearer $GH_PAT" -H "Accept: application/vnd.github+json" "$@"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" "$@"
  fi
}

# ─── pre-update local-modification check ──────────────────────────────────────
if [ -d "$TARGET" ] && [ -n "$OLD_COMMIT" ]; then
  echo "--- pre-update: local-modification check ---"
  # Re-clone the upstream version the install claims to be from, then diff
  SCRATCH_CHECK="/tmp/my-project/update-check-$$"
  mkdir -p "$SCRATCH_CHECK"
  # Use || true to prevent set -e from killing the script if clone fails
  # (we handle the failure by checking [ -d "$SCRATCH_CHECK/upstream" ] below)
  if [ -n "${GH_PAT:-}" ]; then
    git clone -q --depth 1 -b "$SKILL_BRANCH" \
      "https://${GH_PAT}@github.com/${SKILL_REPO}.git" "$SCRATCH_CHECK/upstream" 2>/dev/null || true
  else
    git clone -q --depth 1 -b "$SKILL_BRANCH" \
      "https://github.com/${SKILL_REPO}.git" "$SCRATCH_CHECK/upstream" 2>/dev/null || true
  fi
  if [ -d "$SCRATCH_CHECK/upstream" ]; then
    # Strip VCS from the upstream clone before diffing (the .git dir would show as a diff)
    rm -rf "$SCRATCH_CHECK/upstream/.git" 2>/dev/null
    DIFF=$(diff -qr "$SCRATCH_CHECK/upstream" "$TARGET" 2>/dev/null \
      | grep -v -E '\.installed-from|\.pre-update-backup|\.pre-rollback|\.pre-export-refresh|\.pre-round|\.git/' \
      | head -20 || true)
    if [ -n "$DIFF" ]; then
      echo "  [WARN] local modifications detected (will be LOST on update):"
      printf '%s\n' "$DIFF" | sed 's/^/    /'
      echo "  to preserve: cancel this update, cp the modified files aside, then re-run."
      if [ "${DRY_RUN:-0}" != "1" ]; then
        # Use </dev/tty to read from terminal even when stdin is redirected
        # (non-interactive runs get EOF → ans="" → abort branch)
        read -r -p "  proceed with update (local mods will be backed up but overwritten)? [y/N] " ans </dev/tty || ans=""
        case "$ans" in
          y|Y) echo "  proceeding..." ;;
          *)   echo "  aborted."; rm -rf "$SCRATCH_CHECK"; exit 0 ;;
        esac
      fi
    else
      echo "  no local modifications — safe to update."
    fi
  else
    echo "  [note] couldn't clone upstream for diff check — skipping local-modification check"
  fi
  rm -rf "$SCRATCH_CHECK"
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo
  echo "[dry-run] would update $SKILL_NAME from $SKILL_REPO@$SKILL_BRANCH. Stopping."
  exit 0
fi

# ─── Step 1: backup ──────────────────────────────────────────────────────────
echo
echo "--- Step 1: backup current install ---"
if [ -d "$TARGET" ]; then
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  BACKUP="${TARGET}.pre-update-backup-${STAMP}"
  cp -r "$TARGET" "$BACKUP"
  echo "  [ok] backed up → $BACKUP"
  # Prune: keep last 3
  ls -dt "${TARGET}.pre-update-backup-"* 2>/dev/null | tail -n +4 | xargs -r rm -rf
else
  echo "  [info] no existing install — this is a fresh install, not an update"
fi

# ─── Step 2: fetch ──────────────────────────────────────────────────────────
echo
echo "--- Step 2: fetch upstream ---"
SCRATCH="/tmp/my-project/update-fetch-$$"
mkdir -p "$SCRATCH"
if [ -n "$SKILL_COMMIT" ]; then
  # Pin to a specific SHA — clone without --branch, then checkout
  if [ -n "$GH_PAT" ]; then
    git clone -q "https://${GH_PAT}@github.com/${SKILL_REPO}.git" "$SCRATCH/$SKILL_NAME" 2>&1 \
      | sed -E 's|(ghp_[A-Za-z0-9]+)|(***PAT***)|g' || true
  else
    git clone -q "https://github.com/${SKILL_REPO}.git" "$SCRATCH/$SKILL_NAME"
  fi
  git -C "$SCRATCH/$SKILL_NAME" checkout -q "$SKILL_COMMIT"
  echo "  [ok] fetched + checked out commit ${SKILL_COMMIT:0:8}"
else
  if [ -n "$GH_PAT" ]; then
    git clone -q --depth 1 -b "$SKILL_BRANCH" \
      "https://${GH_PAT}@github.com/${SKILL_REPO}.git" "$SCRATCH/$SKILL_NAME" 2>&1 \
      | sed -E 's|(ghp_[A-Za-z0-9]+)|(***PAT***)|g' || true
  else
    git clone -q --depth 1 -b "$SKILL_BRANCH" \
      "https://github.com/${SKILL_REPO}.git" "$SCRATCH/$SKILL_NAME"
  fi
  echo "  [ok] fetched branch $SKILL_BRANCH"
fi

# ─── Step 3: strip VCS ───────────────────────────────────────────────────────
echo
echo "--- Step 3: strip VCS metadata ---"
# Use absolute paths (NOT cd) — the mv in Step 4 will move this dir out from
# under us if we cd'd into it, causing "Failed to save initial working directory"
# errors in subsequent find/chmod commands.
rm -rf "$SCRATCH/$SKILL_NAME/.git" "$SCRATCH/$SKILL_NAME/.gitignore" "$SCRATCH/$SKILL_NAME/.gitattributes" 2>/dev/null
find "$SCRATCH/$SKILL_NAME" -mindepth 2 -name .git -type d -exec rm -rf {} + 2>/dev/null || true
echo "  [ok] stripped"

# ─── Step 4: atomic replace + set modes ─────────────────────────────────────
echo
echo "--- Step 4: atomic replace + set modes ---"
rm -rf "$TARGET"
mv "$SCRATCH/$SKILL_NAME" "$TARGET"
[ -d "$TARGET/scripts" ] && find "$TARGET/scripts" -type f -exec chmod 0755 {} +
find "$TARGET" -maxdepth 2 -type f ! -path "$TARGET/scripts/*" ! -name '.installed-from' \
  ! -executable -exec chmod 0644 {} + 2>/dev/null
chmod 0755 "$TARGET" 2>/dev/null
[ -d "$TARGET/scripts" ] && chmod 0755 "$TARGET/scripts"
[ -d "$TARGET/evidence" ] && chmod 0755 "$TARGET/evidence"
chown -R z:z "$TARGET" 2>/dev/null || true
echo "  [ok] installed: $TARGET"

# ─── Step 5: refresh portable zip (kit convention, optional) ────────────────
if [ -d "$TARGET/scripts" ]; then
  STAGE="/tmp/.update-zip-$$"
  mkdir -p "$STAGE"
  cp -r "$TARGET" "$STAGE/$(basename "$TARGET" | sed 's/-kit$//')"
  (cd "$STAGE" && zip -qr "${SKILL_NAME}.zip" "$(basename "$TARGET" | sed 's/-kit$//')")
  mv "${STAGE}/${SKILL_NAME}.zip" "$USER_SKILLS_DIR/${SKILL_NAME}.zip" 2>/dev/null && \
    echo "  [ok] refreshed portable zip: $USER_SKILLS_DIR/${SKILL_NAME}.zip"
  rm -rf "$STAGE"
fi

# ─── Step 6: verify ─────────────────────────────────────────────────────────
echo
echo "--- Step 6: verify ---"
VERIFY_FAIL=0
[ -f "$TARGET/SKILL.md" ] || { echo "  [FAIL] $TARGET/SKILL.md missing"; VERIFY_FAIL=1; }
if [ -f "$TARGET/SKILL.md" ]; then
  echo "  SKILL.md: $(wc -l < "$TARGET/SKILL.md") lines, $(stat -c '%s' "$TARGET/SKILL.md") bytes"
fi
if [ -d "$TARGET/scripts" ]; then
  for s in "$TARGET/scripts"/*; do
    [ -f "$s" ] || continue
    if [ ! -x "$s" ]; then
      echo "  [FAIL] not executable: $s"
      VERIFY_FAIL=1
    fi
  done
  [ "$VERIFY_FAIL" = 0 ] && echo "  all scripts executable ✅"
fi
LEAK=$(find "$TARGET" -mindepth 2 -name .git -type d 2>/dev/null | head -1)
if [ -n "$LEAK" ]; then
  echo "  [WARN] nested .git leaked: $LEAK"
else
  echo "  no .git leakage ✅"
fi

# ─── Step 7: provenance (record commit if we can) ──────────────────────────
echo
echo "--- Step 7: provenance ---"
NEW_COMMIT="$SKILL_COMMIT"
if [ -z "$NEW_COMMIT" ]; then
  # Try to get the commit SHA from upstream HEAD (uses gh_api for auth + rate-limit handling)
  NEW_COMMIT=$(gh_api "https://api.github.com/repos/${SKILL_REPO}/commits/${SKILL_BRANCH}" 2>/dev/null | jq -r '.sha // ""')
fi
cat > "$TARGET/.installed-from" <<EOF
repo: $SKILL_REPO
branch: $SKILL_BRANCH
${NEW_COMMIT:+commit: $NEW_COMMIT}
installed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
installed_by: super-z install-user-skill update.sh
${OLD_INSTALLED_AT:+previous_install: $OLD_INSTALLED_AT}
EOF
chmod 600 "$TARGET/.installed-from"
echo "  [ok] provenance written"
echo "    new commit: ${NEW_COMMIT:-unknown}${NEW_COMMIT:+ (${NEW_COMMIT:0:8})}"

# ─── report what changed ────────────────────────────────────────────────────
echo
if [ -n "$OLD_COMMIT" ] && [ -n "$NEW_COMMIT" ] && [ "$OLD_COMMIT" != "$NEW_COMMIT" ]; then
  echo "--- what changed ---"
  echo "  old: ${OLD_COMMIT:0:8}"
  echo "  new: ${NEW_COMMIT:0:8}"
  echo "  upstream commits between:"
  # Uses gh_api (authenticated if available)
  COMMITS_BETWEEN=$(gh_api \
    "https://api.github.com/repos/${SKILL_REPO}/compare/${OLD_COMMIT}...${NEW_COMMIT}" 2>/dev/null \
    | jq -r '.commits[]? | "    \(.sha[0:8]) \(.commit.message | split("\n")[0] | .[0:70])"' | head -20)
  if [ -n "$COMMITS_BETWEEN" ]; then
    printf '%s\n' "$COMMITS_BETWEEN"
  else
    echo "    (couldn't fetch commit range — possibly a force-push or different fork)"
  fi
elif [ -n "$OLD_COMMIT" ] && [ "$OLD_COMMIT" = "$NEW_COMMIT" ]; then
  echo "--- no change (already at $NEW_COMMIT) ---"
fi

rm -rf "$SCRATCH"

echo
if [ "$VERIFY_FAIL" = 0 ]; then
  echo "=== ✅ update complete ==="
  echo "  to roll back: ls -dt ${TARGET}.pre-update-backup-* | head -1"
  exit 0
else
  echo "=== ⚠️  update finished with verify failures — see [FAIL] lines above ==="
  echo "  roll back with: ls -dt ${TARGET}.pre-update-backup-* | head -1"
  exit 1
fi
