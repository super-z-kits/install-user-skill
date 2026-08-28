#!/usr/bin/env bash
# check-update.sh — check if an installed skill is up-to-date with upstream
#
# Reads $USER_SKILLS_DIR/<skill>/.installed-from to find the upstream repo+branch,
# fetches the upstream HEAD via GitHub API, and reports drift.
#
# Also lists available backups (for rollback).
#
# Usage:
#   check-update.sh <skill-name>                  # check a specific skill
#   check-update.sh --all                         # check all installed skills
#   USER_SKILLS_DIR=/tmp/test check-update.sh foo  # override target dir
#
# Exit codes:
#   0 = up-to-date (or no install found)
#   1 = drift detected (installed != upstream)
#   2 = error (couldn't read provenance, network failure, etc.)

set -euo pipefail

USER_SKILLS_DIR="${USER_SKILLS_DIR:-/home/user_skills}"

# ─── arg parsing ──────────────────────────────────────────────────────────────
SKILL_NAME=""
ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    -h|--help)
      cat <<EOF >&2
check-update.sh — check if an installed skill is up-to-date with upstream

Usage: check-update.sh <skill-name> [--all]

Reads \$USER_SKILLS_DIR/<skill>/.installed-from to find the upstream repo+branch,
fetches the upstream HEAD, and reports drift.

Options:
  --all                Check all installed skills
  --help, -h           Show this help

Env vars:
  USER_SKILLS_DIR      Default: /home/user_skills

Exit codes:
  0 = up-to-date (or no install found)
  1 = drift detected (installed != upstream)
  2 = error
EOF
      exit 0 ;;
    *) SKILL_NAME="$1"; shift ;;
  esac
done

# ─── helpers ──────────────────────────────────────────────────────────────────
check_one() {
  local skill="$1"
  local target="$USER_SKILLS_DIR/$skill"
  local prov="$target/.installed-from"

  if [ ! -d "$target" ]; then
    echo "  $skill: not installed (no dir at $target)"
    return 0
  fi
  if [ ! -f "$prov" ]; then
    echo "  $skill: installed but no .installed-from (pre-v1.0 install?)"
    return 0
  fi

  # Parse provenance
  local repo branch installed_commit
  repo=$(awk -F': ' '/^repo:/ {print $2}' "$prov")
  branch=$(awk -F': ' '/^branch:/ {print $2}' "$prov")
  installed_commit=$(awk -F': ' '/^commit:/ {print $2}' "$prov")

  if [ -z "$repo" ] || [ -z "$branch" ]; then
    echo "  $skill: incomplete provenance (repo=$repo branch=$branch)"
    return 2
  fi

  # Fetch upstream HEAD via GitHub API.
  # Always prefer authenticated requests if GH_PAT is available — even for public
  # repos, anonymous calls are limited to 60/hour (easily exhausted in a session
  # with sub-agents). Authenticated calls get 5000/hour.
  local auth_header=()
  if [ -z "${GH_PAT:-}" ] && [ -f /home/user_skills/zk-doppler.env ]; then
    # Try to resolve GH_PAT from Doppler (best-effort, silent on failure)
    set -a; source /home/user_skills/zk-doppler.env 2>/dev/null; set +a
    if [ -n "${DOPPLER_PT:-}" ]; then
      GH_PAT=$(curl -sS -H "Authorization: Bearer $DOPPLER_PT" \
        "https://api.doppler.com/v3/configs/config/secrets?project=${DOPPLER_PROJECT:-agent-bootstrap}&config=${DOPPLER_CONFIG:-prd}" 2>/dev/null \
        | jq -r '.secrets.GH_PAT.computed // empty')
      export GH_PAT
    fi
  fi
  if [ -n "${GH_PAT:-}" ]; then
    auth_header=(-H "Authorization: Bearer $GH_PAT")
  fi

  local upstream_sha upstream_msg upstream_resp
  upstream_resp=$(curl -fsSL "${auth_header[@]}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${repo}/commits/${branch}" 2>/dev/null || true)
  upstream_sha=$(printf '%s' "$upstream_resp" | jq -r '.sha // empty')
  if [ -z "$upstream_sha" ]; then
    # Distinguish rate-limit from network error
    local http_code
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" "${auth_header[@]}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${repo}/commits/${branch}" 2>/dev/null || echo "000")
    case "$http_code" in
      403) echo "  $skill: GitHub API rate limited (anonymous limit exhausted). Set GH_PAT or retry later." ;;
      404) echo "  $skill: repo or branch not found ($repo@$branch)" ;;
      *)   echo "  $skill: couldn't fetch upstream HEAD (HTTP $http_code)" ;;
    esac
    return 2
  fi
  upstream_msg=$(printf '%s' "$upstream_resp" | jq -r '.commit.message // "?"' | head -1 | cut -c1-70)

  # If installed_commit is set (SHA pin), compare directly
  if [ -n "$installed_commit" ]; then
    if [ "$installed_commit" = "$upstream_sha" ]; then
      echo "  $skill: up-to-date (pinned to commit ${installed_commit:0:8})"
      return 0
    else
      echo "  $skill: drift detected (pinned ${installed_commit:0:8} != upstream ${upstream_sha:0:8})"
      echo "    upstream: $upstream_msg"
      return 1
    fi
  fi

  # No commit pin — assume installed from main, can't tell which commit; just report upstream HEAD
  # (this is the conservative case: we don't know the installed SHA without re-cloning)
  local backups
  backups=$(ls -dt "${target}.pre-update-backup-"* 2>/dev/null | wc -l)
  echo "  $skill:"
  echo "    installed from: $repo@$branch (commit not recorded in provenance)"
  echo "    upstream HEAD:  ${upstream_sha:0:8} $upstream_msg"
  echo "    backups:        $backups"
  echo "    status:         drift-check-incomplete (re-install + check-update again to record commit)"

  # Suggest running update.sh to refresh + record the commit
  cat <<HINT
    hint: to record the installed commit and get drift detection, run:
      bash $(dirname "$0")/update.sh $skill
HINT
  return 0
}

# ─── main ────────────────────────────────────────────────────────────────────
if [ "$ALL" = 1 ]; then
  echo "=== checking all installed skills in $USER_SKILLS_DIR ==="
  for d in "$USER_SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    skill=$(basename "$d")
    # skip backup dirs and the install-user-skill self-install
    case "$skill" in
      *.pre-update-backup-*|*.pre-rollback-*|*.pre-round-*-backup*|*.pre-export-refresh-*) continue ;;
    esac
    check_one "$skill" || true
  done
else
  if [ -z "$SKILL_NAME" ]; then
    echo "error: skill-name required (or use --all)" >&2
    exit 2
  fi
  check_one "$SKILL_NAME"
fi
