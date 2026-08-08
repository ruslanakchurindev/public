# Agent Instructions

Conventions for working in this repo.

- Each skill is self-contained under `skills/<name>/`: a `SKILL.md` plus any `scripts/`,
  `references/`, and `examples/` it needs. Keep `SKILL.md` at the skill root.
- Keep one source copy of each skill. Install a skill by symlinking its directory into
  your agent's skill dir — never copy: `ln -s "$PWD/skills/<name>" ~/.claude/skills/<name>`.
- `SKILL.md` follows the write-a-skill convention: `name` / `description` / `license`
  frontmatter, under 100 lines, with detail pushed to the skill's `README.md` or `references/`.
- Standalone command-line tools live in their own top-level directory (e.g. `sklink/`):
  executables at the directory root, tests under `<tool>/scripts/`, docs in `<tool>/README.md`.
  A tool must write nothing inside this checkout at runtime — user data belongs in
  `$XDG_CONFIG_HOME` / `$XDG_STATE_HOME`, so pulling an update never conflicts with it.
- Shell scripts must stay portable across macOS `bash` 3.2 and Linux (GNU). Run a skill's or
  tool's tests before publishing, e.g. `GIT_CONFIG_GLOBAL=/dev/null skills/handover/scripts/test-handover.sh`
  or `bash sklink/scripts/test-sklink.sh`.
- Root `README.md` is a light index of skills and tools; detailed docs live beside each one.
- Do not commit `.DS_Store` or generated artifacts. Handover artifacts are written outside
  the repo by design — never check them in.
