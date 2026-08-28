# install-user-skill

> This file is kept for backward compatibility with the original self-bootstrap URL.
> The canonical file is now `SKILL.md` (renamed via GitHub UI on 2026-08-28).
>
> To install this skill:
>
> ```bash
> USER_SKILLS_DIR="${USER_SKILLS_DIR:-/home/user_skills}"
> mkdir -p "$USER_SKILLS_DIR/install-user-skill"
> curl -sS -o "$USER_SKILLS_DIR/install-user-skill/SKILL.md" \
>   https://raw.githubusercontent.com/super-z-kits/install-user-skill/main/SKILL.md
> chmod 0644 "$USER_SKILLS_DIR/install-user-skill/SKILL.md"
> ```
>
> Then `cat $USER_SKILLS_DIR/install-user-skill/SKILL.md` for the full procedure.
