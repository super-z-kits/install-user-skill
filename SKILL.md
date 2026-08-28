# install-user-skill

Copy a skill from a public GitHub repo into `/home/user_skills/`.

```bash
SKILL="<owner>/<repo>"        # e.g. super-z-kits/z-container-kit
NAME="$(basename $SKILL)"     # e.g. z-container-kit

# clone, strip .git, move into place
git clone --depth 1 "https://github.com/$SKILL.git" "/tmp/$NAME" \
  && rm -rf "/tmp/$NAME/.git" \
  && rm -rf "/home/user_skills/$NAME" \
  && mv "/tmp/$NAME" "/home/user_skills/$NAME"
```

Done. To update, run the same command again (it overwrites).

Notes:
- For private repos, prefix the URL with `<PAT>@` and mask the PAT in any output.
- For single-file skills (no `scripts/`), `curl -o /home/user_skills/<name>/SKILL.md https://raw.githubusercontent.com/<owner>/<repo>/main/SKILL.md` is enough.
