# Agent Instructions

Conventions for working in this repo.

- A skill is self-contained under `skills/<name>/`: `SKILL.md` at the root, plus any
  `scripts/`, `references/`, `examples/` and `templates/` it needs.
- `SKILL.md` follows the write-a-skill convention: `name` / `description` / `license`
  frontmatter, under 100 lines, detail pushed to the skill's `README.md` or `references/`.
- A standalone command-line tool lives in its own top-level directory (e.g. `sklink/`):
  executables at the root, tests in `<tool>/scripts/`, docs in `<tool>/README.md`,
  config seeds in `<tool>/templates/`.
- Nothing writes inside this checkout at runtime. User data belongs in `$XDG_CONFIG_HOME`
  or `$XDG_STATE_HOME`, so an update never conflicts with it. Never overwrite an existing
  user config; create it only when absent.
- Install by symlink, never by copy: `ln -s "$PWD/skills/<name>" ~/.claude/skills/<name>`.
- Shell must stay portable across macOS `bash` 3.2 and Linux (GNU).
- Run the tests before publishing, e.g.
  `GIT_CONFIG_GLOBAL=/dev/null skills/handover/scripts/test-handover.sh` or
  `bash sklink/scripts/test-sklink.sh`.
- Root `README.md` is an index; detailed docs live beside each skill and tool.
- Do not commit `.DS_Store`, generated artifacts, or handover artifacts.
