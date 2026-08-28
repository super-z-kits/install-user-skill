# install-user-skill

> Canonical process for installing or updating a public-repo skill into `/home/user_skills/`.
> Reusable across kits (z-container-kit, secrets-vault-kit, or any future skill shipped as a GitHub repo).
> Load this whenever the user asks you to "install" / "update" / "refresh" / "copy over" a skill.
>
> **Canonical raw URL:** `https://raw.githubusercontent.com/super-z-kits/install-user-skill/main/SKILL.md`
>
> **Self-installing:** this skill is itself installable by its own procedure — see "Self-bootstrap" below.

## Why this exists

`/home/user_skills/` is the only per-user, cross-chat-persistent directory in the Super Z container (see z-container-kit persistence map). Fetching a SKILL.md from `raw.githubusercontent.com` per chat works but adds friction: you must reconstruct the raw URL from GitHub-title shorthand (audit m1), and you re-fetch the same content every chat. Installing the skill once into `/home/user_skills/<skill-name>/` makes future chats just `cat /home/user_skills/<skill-name>/SKILL.md` — no URL reconstruction, no network round-trip, no fetch failures.

This file documents the install/update process so it's done consistently every time, with safety rails (backup before overwrite, atomic replace, VCS-strip, mode preservation).

## Self-bootstrap

This skill is itself installable via its own procedure. To bootstrap it (i.e. install it for the first time when it's not already in `/home/user_skills/`):

```bash
USER_SKILLS_DIR="${USER_SKILLS_DIR:-/home/user_skills}"
mkdir -p "$USER_SKILLS_DIR/install-user-skill"
# Fetch the CANONICAL SKILL.md (not install-user-skill.md, which is a backward-compat pointer).
# v1.1 had a bug where bootstrap fetched the pointer instead of the real file.
curl -fsSL -o "$USER_SKILLS_DIR/install-user-skill/SKILL.md" \
  https://raw.githubusercontent.com/super-z-kits/install-user-skill/main/SKILL.md
chmod 0644 "$USER_SKILLS_DIR/install-user-skill/SKILL.md"
# Provenance
cat > "$USER_SKILLS_DIR/install-user-skill/.installed-from" <<EOF
repo: super-z-kits/install-user-skill
branch: main
installed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
installed_by: super-z install-user-skill self-bootstrap
EOF
chmod 0600 "$USER_SKILLS_DIR/install-user-skill/.installed-from"
```

After bootstrap, future chats reference the local copy: `cat /home/user_skills/install-user-skill/SKILL.md` — no GitHub fetch needed (reduces friction per audit m1).

## Layout

```
/home/user_skills/
├── <skill-name>/                 # the installed skill (a directory)
│   ├── SKILL.md                   # always present (the load-at-session-start doc)
│   ├── README.md                  # optional (overview)
│   ├── reference.md               # optional (long-form detail linked from SKILL.md)
│   ├── scripts/                   # optional (helper scripts)
│   │   └── ...
│   └── evidence/                  # optional (forensic notes / experiment logs)
└── <skill-name>.zip               # optional portable zip mirror (kit convention)
```

Skills are flat dirs under `/home/user_skills/`. No nesting, no versioning in the path — the latest install always wins.

## When to use this

**Install** (skill not present in `/home/user_skills/`):
- Fresh chat, user pastes a handover pointing at a public skill repo.
- You discover a useful skill on github.com and want it locally available.

**Update** (skill already present, you want the latest version):
- User says "refresh the kit" / "pull the latest z-container-kit".
- You're tracking a branch with new fixes and want to test them.
- After merging a PR to the upstream skill repo.

**Override** (skill present, you want to replace with a specific fork/branch):
- Testing your own fork before opening an upstream PR.
- Hotfixing a bug locally before it ships upstream.

## The canonical install/update procedure

### Step 0 — pre-flight (always)

```bash
# Define the skill source and target FIRST (so we can decide if GH_PAT is needed)
SKILL_NAME="<skill-name>"                    # e.g. z-container-kit
SKILL_REPO="<owner>/<repo>"                   # e.g. super-z-kits/z-container-kit  OR  zikomolapoutl/z-container-kit-v2 (work repo)
SKILL_BRANCH="${SKILL_BRANCH:-main}"          # default to main; override for testing
USER_SKILLS_DIR="${USER_SKILLS_DIR:-/home/user_skills}"   # override for testing (e.g. /tmp/my-project/test-user-skills)
TARGET="$USER_SKILLS_DIR/$SKILL_NAME"

# GH_PAT resolution: ONLY if the repo is private (audit sub-agent-test #10 — public
# clones don't need a PAT, so resolving it unnecessarily exposes the secret +
# adds a network call). Determine privacy by checking if `git clone https://...`
# would succeed anonymously — or just let the user set SKILL_REPO_PRIVATE=1.
GH_PAT="${GH_PAT:-}"
if [ "${SKILL_REPO_PRIVATE:-0}" = "1" ] && [ -z "$GH_PAT" ] && [ -f /home/user_skills/zk-doppler.env ]; then
  set -a; source /home/user_skills/zk-doppler.env; set +a
  GH_PAT=$(curl -sS -H "Authorization: Bearer $DOPPLER_PT" \
    "https://api.doppler.com/v3/configs/config/secrets?project=${DOPPLER_PROJECT:-agent-bootstrap}&config=${DOPPLER_CONFIG:-prd}" \
    | jq -r '.secrets.GH_PAT.computed')
fi
```

**`USER_SKILLS_DIR` env var (testability):** all paths in this procedure honor `$USER_SKILLS_DIR` (default `/home/user_skills`). Set it to a scratch dir to test the install procedure end-to-end without touching the live install. Hard-coding `/home/user_skills/` was an audit-F-round-5 finding (hard-coding caused the F16 "wrong repo pull" issue); the env var removes that footgun.

**`SKILL_REPO_PRIVATE=1` env var (audit sub-agent-test #10):** set this only when installing from a private repo. Public clones (Strategy A below) don't need a GH_PAT; resolving one unnecessarily exposes the secret and adds a network call. Default is public (no PAT resolution).

### Step 1 — backup the existing install (if present)

**NEVER** overwrite an existing install without backing it up first. The user may have local patches you don't want to lose.

```bash
if [ -d "$TARGET" ]; then
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  BACKUP="${TARGET}.pre-update-backup-${STAMP}"
  cp -r "$TARGET" "$BACKUP"
  echo "[ok] backed up existing install → $BACKUP"
  # Prune: keep only the last 3 backups
  ls -dt "${TARGET}.pre-update-backup-"* 2>/dev/null | tail -n +4 | xargs -r rm -rf
fi
```

### Step 2 — fetch the skill

Two strategies, in order of preference:

**Strategy A — public repo, anonymous clone (preferred for public skills):**

```bash
SCRATCH="/tmp/my-project/install-user-skill-$$"
mkdir -p "$SCRATCH"
git clone -q --depth 1 -b "$SKILL_BRANCH" \
  "https://github.com/${SKILL_REPO}.git" "$SCRATCH/$SKILL_NAME"
```

**Strategy B — private repo, clone with GH_PAT (used when the skill is in a private work repo):**

```bash
SCRATCH="/tmp/my-project/install-user-skill-$$"
mkdir -p "$SCRATCH"
git clone -q --depth 1 -b "$SKILL_BRANCH" \
  "https://${GH_PAT}@github.com/${SKILL_REPO}.git" "$SCRATCH/$SKILL_NAME" 2>&1 \
  | sed -E 's|(ghp_[A-Za-z0-9]+)|(***PAT***)|g'   # mask in case git echoes the URL
```

**Strategy C — single-file install (no git, just fetch SKILL.md):**

For skills that ship as a single SKILL.md (no scripts), fetching the raw file is sufficient and avoids leaving a `.git` dir around:

```bash
SCRATCH="/tmp/my-project/install-user-skill-$$"
mkdir -p "$SCRATCH/$SKILL_NAME"
curl -sS -o "$SCRATCH/$SKILL_NAME/SKILL.md" \
  "https://raw.githubusercontent.com/${SKILL_REPO}/${SKILL_BRANCH}/SKILL.md"
```

### Step 3 — strip VCS metadata (always)

The installed skill should NOT carry git history. A `.git` directory inside `/home/user_skills/<skill-name>/` confuses `git` operations on the workspace, adds weight, and can leak commit messages or remote URLs that contain embedded PATs.

```bash
cd "$SCRATCH/$SKILL_NAME"
rm -rf .git .gitignore .gitattributes 2>/dev/null
find . -name .git -exec rm -rf {} + 2>/dev/null
```

### Step 4 — atomic replace + set modes

Move the new install into place atomically (so a partial install never leaves the target in a broken state). Then set modes explicitly — the source repo's modes are NOT preserved across clone + tar/zip, and `cp -r` inherits umask (often 077), leaving files unreadable.

```bash
# Wipe the old target (we already backed it up in step 1)
rm -rf "$TARGET"

# Move the new install into place
mv "$SCRATCH/$SKILL_NAME" "$TARGET"

# Set modes (audit sub-agent-test #3, #4, #5, #6):
# - All scripts executable AND world-readable (0755, not 711 from `chmod +x` on 600 base).
#   Use `chmod 0755` not `chmod +x` — the latter produces 711 on umask 077 (broken).
# - Include extensionless scripts (z-container-kit's `zsave`, `zsession` have no .sh/.py suffix).
# - All docs 0644 (README, SKILL.md, reference.md, *.md).
# - Directories 0755 (so non-owners can traverse).
if [ -d "$TARGET/scripts" ]; then
  find "$TARGET/scripts" -type f -exec chmod 0755 {} +
fi
find "$TARGET" -maxdepth 2 -type f -name '*.md' -exec chmod 0644 {} +
chmod 0755 "$TARGET" 2>/dev/null
[ -d "$TARGET/scripts" ] && chmod 0755 "$TARGET/scripts"
[ -d "$TARGET/evidence" ] && chmod 0755 "$TARGET/evidence"

# Set ownership (paranoia — should already be `z:z` from the move)
chown -R z:z "$TARGET" 2>/dev/null || true

echo "[ok] installed: $TARGET"
```

### Step 5 — refresh the portable zip (kit convention, optional)

If the skill is a "kit" (has scripts and ships a portable zip), refresh the zip mirror:

```bash
if [ -d "$TARGET/scripts" ]; then
  STAGE="/tmp/.skill-zip-$$"
  mkdir -p "$STAGE"
  cp -r "$TARGET" "$STAGE/$(basename "$TARGET" | sed 's/-kit$//')"   # zip root: drop -kit suffix
  cd "$STAGE"
  zip -qr "${SKILL_NAME}.zip" "$(basename "$TARGET" | sed 's/-kit$//')"
  mv "${SKILL_NAME}.zip" "$USER_SKILLS_DIR/${SKILL_NAME}.zip"
  cd / && rm -rf "$STAGE"
  echo "[ok] refreshed portable zip: $USER_SKILLS_DIR/${SKILL_NAME}.zip"
fi
```

### Step 6 — verify (always)

```bash
# Confirm SKILL.md is readable
[ -f "$TARGET/SKILL.md" ] || { echo "[FAIL] $TARGET/SKILL.md missing"; exit 1; }
echo "  SKILL.md: $(wc -l < "$TARGET/SKILL.md") lines, $(stat -c '%s' "$TARGET/SKILL.md") bytes"

# Confirm scripts are executable (audit sub-agent-test #3: extensionless scripts
# like `zsave`/`zsession` were left non-executable by the v1.0 procedure).
# Verify the executable bit is SET, not just that the file exists.
if [ -d "$TARGET/scripts" ]; then
  echo "  scripts:"
  ls "$TARGET/scripts" | sed 's/^/    /'
  # Audit sub-agent-test #3 fix: verify ALL scripts are executable, including extensionless ones
  FAIL=0
  for s in "$TARGET/scripts"/*; do
    [ -f "$s" ] || continue
    if [ ! -x "$s" ]; then
      echo "  [FAIL] not executable: $s"
      FAIL=1
    fi
  done
  [ "$FAIL" = 0 ] && echo "  all scripts executable ✅"
fi

# Confirm no .git leaked (audit sub-agent-test #2 fix: the old `find | head -1 && echo WARN`
# always exited 0 because head succeeded on empty input — the WARN was a false positive
# and the "no leakage" branch was dead code. Use an explicit `if [ -n ... ]` check.)
LEAK=$(find "$TARGET" -name .git -type d 2>/dev/null | head -1)
if [ -n "$LEAK" ]; then
  echo "  [WARN] .git dir leaked: $LEAK — strip it"
else
  echo "  no .git leakage ✅"
fi

# Clean up scratch
rm -rf "$SCRATCH"
```

### Step 7 — record the install provenance

Write a small provenance file alongside the install so future chats know what version is installed:

```bash
cat > "$TARGET/.installed-from" <<EOF
repo: $SKILL_REPO
branch: $SKILL_BRANCH
installed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
installed_by: super-z install-user-skill process
EOF
chmod 600 "$TARGET/.installed-from"
```

This file is useful for: (a) knowing which fork/branch is installed when debugging, (b) detecting drift between the installed version and the upstream HEAD, (c) telling the user "you have v2.3.3 from zikomolapoutl/z-container-kit-v2@abc1234 installed."

## End-to-end example: install z-container-kit

```bash
# Pre-flight (audit sub-agent-test #10: public clone, NO GH_PAT resolution needed)
USER_SKILLS_DIR="${USER_SKILLS_DIR:-/home/user_skills}"
SKILL_NAME="z-container-kit"
SKILL_REPO="super-z-kits/z-container-kit"     # public export
SKILL_BRANCH="main"
TARGET="$USER_SKILLS_DIR/$SKILL_NAME"

# Backup
[ -d "$TARGET" ] && cp -r "$TARGET" "${TARGET}.pre-update-backup-$(date -u +%Y%m%dT%H%M%SZ)"

# Fetch (Strategy A: anonymous public clone — no PAT needed)
SCRATCH="/tmp/my-project/install-user-skill-$$"
mkdir -p "$SCRATCH"
git clone -q --depth 1 -b "$SKILL_BRANCH" "https://github.com/${SKILL_REPO}.git" "$SCRATCH/$SKILL_NAME"

# Strip VCS
cd "$SCRATCH/$SKILL_NAME"
rm -rf .git .gitignore
find . -name .git -exec rm -rf {} + 2>/dev/null

# Atomic replace + set modes (Step 4 fix: chmod 0755 for ALL scripts, not just *.sh/*.py)
rm -rf "$TARGET"
mv "$SCRATCH/$SKILL_NAME" "$TARGET"
[ -d "$TARGET/scripts" ] && find "$TARGET/scripts" -type f -exec chmod 0755 {} +
find "$TARGET" -maxdepth 2 -type f -name '*.md' -exec chmod 0644 {} +
chmod 0755 "$TARGET" 2>/dev/null
[ -d "$TARGET/scripts" ] && chmod 0755 "$TARGET/scripts"

# Verify (Step 6 fix: assert executable bit, not just file existence)
[ -f "$TARGET/SKILL.md" ] && echo "✅ $TARGET/SKILL.md installed ($(wc -l < "$TARGET/SKILL.md") lines)"
for s in "$TARGET/scripts"/*; do [ -f "$s" ] && [ ! -x "$s" ] && echo "[FAIL] not executable: $s"; done

# Provenance (Step 7: include installed_by + chmod 600)
cat > "$TARGET/.installed-from" <<EOF
repo: $SKILL_REPO
branch: $SKILL_BRANCH
installed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
installed_by: super-z install-user-skill process
EOF
chmod 600 "$TARGET/.installed-from"

# Clean up
rm -rf "$SCRATCH"
```

## End-to-end example: update z-container-kit from the work repo (private)

```bash
USER_SKILLS_DIR="${USER_SKILLS_DIR:-/home/user_skills}"
set -a; source /home/user_skills/zk-doppler.env; set +a
GH_PAT=$(curl -sS -H "Authorization: Bearer $DOPPLER_PT" \
  "https://api.doppler.com/v3/configs/config/secrets?project=$DOPPLER_PROJECT&config=$DOPPLER_CONFIG" \
  | jq -r '.secrets.GH_PAT.computed')

SKILL_NAME="z-container-kit"
SKILL_REPO="zikomolapoutl/z-container-kit-v2"   # private work repo
SKILL_BRANCH="audit/round-5-onboarding-polish"  # testing a branch
TARGET="$USER_SKILLS_DIR/$SKILL_NAME"

# Backup
[ -d "$TARGET" ] && cp -r "$TARGET" "${TARGET}.pre-update-backup-$(date -u +%Y%m%dT%H%M%SZ)"

# Fetch (mask PAT in any echoed output)
SCRATCH="/tmp/my-project/install-user-skill-$$"
mkdir -p "$SCRATCH"
git clone -q --depth 1 -b "$SKILL_BRANCH" \
  "https://${GH_PAT}@github.com/${SKILL_REPO}.git" "$SCRATCH/$SKILL_NAME" 2>&1 \
  | sed -E 's|(ghp_[A-Za-z0-9]+)|(***PAT***)|g'

# Strip VCS, replace, provenance, verify (same as above)...
```

## End-to-end example: install secrets-vault-kit (single-file variant)

This example uses Strategy C (single-file fetch — no git needed). It is a FAITHFUL CONDENSATION of Steps 0–7 (audit sub-agent-test #8 fix: the v1.0 example diverged from the canonical procedure, omitting Step 3 VCS-strip (irrelevant for single-file), Step 4 mode-setting, all of Step 6 verify, and Step 7's chmod 600 + installed_by: line):

```bash
# Pre-flight (public repo — no GH_PAT needed)
USER_SKILLS_DIR="${USER_SKILLS_DIR:-/home/user_skills}"
SKILL_NAME="secrets-vault-kit"
SKILL_REPO="super-z-kits/secrets-vault-kit"
SKILL_BRANCH="main"
TARGET="$USER_SKILLS_DIR/$SKILL_NAME"

# Step 1: Backup
[ -d "$TARGET" ] && cp -r "$TARGET" "${TARGET}.pre-update-backup-$(date -u +%Y%m%dT%H%M%SZ)"

# Step 2 (Strategy C): single-file fetch — no git needed
SCRATCH="/tmp/my-project/install-user-skill-$$"
mkdir -p "$SCRATCH/$SKILL_NAME"
curl -fsSL -o "$SCRATCH/$SKILL_NAME/SKILL.md" \
  "https://raw.githubusercontent.com/${SKILL_REPO}/${SKILL_BRANCH}/SKILL.md"

# Optional: also fetch SKILL-DEPLOY.md if present (audit sub-agent-test #9 fix: use -f to fail
# silently on 404, NOT save a 404 HTML page as the file content)
curl -fsSL -o "$SCRATCH/$SKILL_NAME/SKILL-DEPLOY.md" \
  "https://raw.githubusercontent.com/${SKILL_REPO}/${SKILL_BRANCH}/SKILL-DEPLOY.md" \
  || rm -f "$SCRATCH/$SKILL_NAME/SKILL-DEPLOY.md"

# Step 4: Atomic replace + set modes (Step 4 fix applies even for single-file installs —
# curl preserves umask, so SKILL.md ends up 600 on umask 077 without explicit chmod)
rm -rf "$TARGET"
mv "$SCRATCH/$SKILL_NAME" "$TARGET"
find "$TARGET" -maxdepth 2 -type f -name '*.md' -exec chmod 0644 {} +
chmod 0755 "$TARGET" 2>/dev/null

# Step 6: Verify (audit sub-agent-test #8 fix: include the verify step!)
[ -f "$TARGET/SKILL.md" ] || { echo "[FAIL] $TARGET/SKILL.md missing"; exit 1; }
echo "  SKILL.md: $(wc -l < "$TARGET/SKILL.md") lines, $(stat -c '%s' "$TARGET/SKILL.md") bytes"
LEAK=$(find "$TARGET" -name .git -type d 2>/dev/null | head -1)
[ -n "$LEAK" ] && echo "  [WARN] .git leaked: $LEAK" || echo "  no .git leakage ✅"

# Step 7: Provenance (audit sub-agent-test #8 fix: include installed_by: + chmod 600)
cat > "$TARGET/.installed-from" <<EOF
repo: $SKILL_REPO
branch: $SKILL_BRANCH
installed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
installed_by: super-z install-user-skill process (single-file variant)
EOF
chmod 600 "$TARGET/.installed-from"

# Clean up
rm -rf "$SCRATCH"
```

**Strategy C rationale (audit sub-agent-test #7 fix):** the v1.0 doc claimed Strategy C was for "single SKILL.md only" while the example also fetched SKILL-DEPLOY.md. The actual rationale is: Strategy C avoids leaving a `.git` dir around and avoids the git dependency — useful for skills that ship as a small set of Markdown files. For multi-file skills with scripts, prefer Strategy A (clone) so you get the full repo tree.

## Safety rules

1. **Always backup before overwrite.** Even if you're sure the new version is better, the user may have local patches. Keep the last 3 backups (`${TARGET}.pre-update-backup-<timestamp>`); auto-prune older ones.

2. **Atomic replace.** Never `cp` files one-by-one into the live target — a partial install leaves the skill broken. Always: backup → wipe → move new into place. The `mv` is atomic on the same filesystem.

3. **Strip VCS metadata.** A `.git` dir inside `/home/user_skills/<skill>/` confuses workspace git operations, adds weight, and can leak embedded PATs from `.git/config` remote URLs. Always strip after cloning.

4. **Mask PATs in any echoed output.** `git clone` with an embedded PAT can echo the URL in stderr (on failure, redirect messages, etc.). Pipe through `sed -E 's|(ghp_[A-Za-z0-9]+)|(***PAT***)|g'` if there's any chance of leakage.

5. **Set executable modes explicitly.** (audit sub-agent-test #3, #4, #5, #6 fix) Use `chmod 0755` (NOT `chmod +x` — the latter produces 711 on umask 077, which is broken: group/other can execute but not read, so the shebang load fails). Apply to ALL scripts in `scripts/`, including extensionless ones (z-container-kit's `zsave`/`zsession` have no `.sh`/`.py` suffix). Also `chmod 0644` for `*.md` docs and `chmod 0755` for directories. The source repo's modes are NOT preserved across clone + tar/zip, and `cp -r` inherits umask (often 077), leaving files unreadable.

6. **Verify after install.** (audit sub-agent-test #2, #3 fix) Always `wc -l` the SKILL.md (confirms readable + non-empty), **assert the executable bit is set on every script** (not just file existence — `ls` doesn't show modes), and check no `.git` leaked using `if [ -n "$LEAK" ]` (NOT `find | head -1 && echo WARN` — that always exits 0 because head succeeds on empty input, making the warning a false positive and the "no leakage" branch dead code).

7. **Record provenance.** Write `.installed-from` so future chats know what version is installed. Critical for debugging "is this the patched version or the original?" without re-fetching.

8. **Don't auto-update without asking.** If the user says "install z-container-kit", install once. Don't run a cron-like check for updates. The user rotates their kit versions deliberately; auto-update would surprise them.

## Detecting drift

After install, you can check whether the installed version matches the upstream HEAD:

```bash
USER_SKILLS_DIR="${USER_SKILLS_DIR:-/home/user_skills}"
# What we have installed:
cat "$USER_SKILLS_DIR/z-container-kit/.installed-from"

# What's the upstream HEAD:
curl -sS "https://api.github.com/repos/super-z-kits/z-container-kit/commits/main" | jq -r '.sha[0:8] + " " + .commit.message'

# If they differ and you want the latest, re-run the install procedure.
```

## What NOT to do

- **Don't `cp -r` into the live target.** Use atomic replace (backup → wipe → move).
- **Don't leave `.git` in the install.** Always strip after clone.
- **Don't echo the GH_PAT.** Always mask `ghp_*` in any output that might contain it.
- **Don't install without verifying.** A silent failure leaves an empty target dir.
- **Don't skip the provenance file.** Future you will thank past you.
- **Don't auto-update on a schedule.** The user controls version upgrades.
- **Don't install a fork as the canonical name.** If testing a fork, install it under a different name (`/home/user_skills/z-container-kit-fork-test/`) so the canonical install isn't clobbered.

## Composing with z-container-kit's `install.sh`

The z-container-kit ships its own `install.sh` that handles installing itself into multiple locations (`/home/z/my-project`, `/home/sync`, `/home/user_skills`, plus the portable zip). It's idempotent and follows the same safety rules above.

For z-container-kit specifically, prefer running the kit's own `install.sh` rather than the generic procedure:

```bash
bash /home/user_skills/z-container-kit/scripts/install.sh
```

This file's procedure is the GENERAL case for any skill. The z-container-kit's `install.sh` is the SPECIALIZED case for that kit (knows about its own additional copy locations and zip convention). Use `install.sh` when available; fall back to this procedure for skills that don't ship their own installer.

## See also

- z-container-kit SKILL.md — persistence model, /home/user_skills/ role in cross-chat survival
- secrets-vault-kit SKILL.md — Doppler credential handling (GH_PAT for private repo installs)
- z-container-kit `scripts/install.sh` — the kit's own specialized installer
- friction-audit/05-synthesis-with-other-agent.md — round-5 audit that produced this process
