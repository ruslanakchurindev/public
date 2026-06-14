# Agent Instructions

Conventions for working in this repo.

- Each skill is self-contained under `skills/<name>/`: a `SKILL.md` plus any `scripts/`,
  `references/`, and `examples/` it needs. Keep `SKILL.md` at the skill root.
- Keep one source copy of each skill. Install a skill by symlinking its directory into
  your agent's skill dir — never copy: `ln -s "$PWD/skills/<name>" ~/.claude/skills/<name>`.
- `SKILL.md` follows the write-a-skill convention: `name` / `description` / `license`
  frontmatter, under 100 lines, with detail pushed to the skill's `README.md` or `references/`.
- Shell scripts must stay portable across macOS `bash` 3.2 and Linux (GNU). Run a skill's
  tests before publishing, e.g. `GIT_CONFIG_GLOBAL=/dev/null skills/handover/scripts/test-handover.sh`.
- Root `README.md` is a light index of skills; per-skill docs live in `skills/<name>/README.md`.
- Do not commit `.DS_Store` or generated artifacts. Handover artifacts are written outside
  the repo by design — never check them in.
