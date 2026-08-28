# install-user-skill

> Copy a skill from a public GitHub repo into `/home/user_skills/`.

The whole skill is 20 lines of bash. See [SKILL.md](./SKILL.md).

## Why

Fetching a SKILL.md from `raw.githubusercontent.com` per chat works but is friction. Copy the skill once into `/home/user_skills/` and you're done — future chats just `cat /home/user_skills/<skill>/SKILL.md`.

## Use

```bash
# install or update (same command)
SKILL="super-z-kits/z-container-kit"
NAME="$(basename $SKILL)"
git clone --depth 1 "https://github.com/$SKILL.git" "/tmp/$NAME" \
  && rm -rf "/tmp/$NAME/.git" \
  && rm -rf "/home/user_skills/$NAME" \
  && mv "/tmp/$NAME" "/home/user_skills/$NAME"
```

That's it. No install scripts, no version pinning, no drift detection — GitHub is the source of truth. Re-run the command to update.
