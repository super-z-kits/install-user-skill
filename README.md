# install-user-skill

> Canonical install/update process for public-repo skills into `/home/user_skills/`.
> Used by the z-container-kit and secrets-vault-kit onboarding flows.

## What this is

A single Markdown file (`install-user-skill.md`) documenting the robust procedure for installing or updating any public-repo skill into the Super Z container's `/home/user_skills/` directory (the per-user, cross-chat-persistent namespace).

It's not a script — it's a loadable skill that an AI agent reads when the user asks "install/refresh/update a skill." The agent then follows the procedure with safety rails: backup-before-overwrite, atomic replace, VCS-strip, mode preservation, provenance tracking.

## Self-installing

This skill is itself installable by its own procedure. First-time bootstrap:

```bash
mkdir -p /home/user_skills/install-user-skill
curl -sS -o /home/user_skills/install-user-skill/install-user-skill.md \
  https://raw.githubusercontent.com/super-z-kits/install-user-skill/main/install-user-skill.md
chmod 0644 /home/user_skills/install-user-skill/install-user-skill.md
```

After bootstrap, future chats reference the local copy: `cat /home/user_skills/install-user-skill/install-user-skill.md` — no GitHub fetch needed.

## When to use

- **Install** a skill that's not yet in `/home/user_skills/` (e.g. user pastes a handover pointing at a public skill repo).
- **Update** an existing install to the latest upstream version.
- **Override** an existing install with a specific fork/branch (e.g. testing a PR before merging).

## Safety rails

1. Always backup before overwrite (keep last 3 backups, auto-prune older).
2. Atomic replace (backup → wipe → move new into place).
3. Strip VCS metadata (no `.git` dirs leak into `/home/user_skills/`).
4. Mask PATs in any echoed output.
5. Set executable modes explicitly (don't trust source repo modes).
6. Verify after install (SKILL.md readable, scripts present, no .git leaked).
7. Record provenance (`.installed-from` file with repo/branch/timestamp).
8. Don't auto-update without asking.

## Related

- [z-container-kit](https://github.com/super-z-kits/z-container-kit) — survival guide for the Z.ai Code sandbox container.
- [secrets-vault-kit](https://github.com/super-z-kits/secrets-vault-kit) — Doppler-based secrets management for AI agents.

## License

Public domain / CC0. Use it, fork it, ship it.
