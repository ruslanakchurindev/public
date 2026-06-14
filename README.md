# Skills

Public, agent-agnostic skills. Each one is self-contained under `skills/<name>/`
(a `SKILL.md` plus any scripts and references it needs) and works with any agent
that loads the `SKILL.md` skill convention.

## Skills

- **[handover](skills/handover/)** — package a coding session's decisions, failed
  approaches, constraints, and next steps into a portable handover artifact stored
  outside the repo, then load the latest one to pick up later.
  See [skills/handover/README.md](skills/handover/README.md).

## Install

Symlink a skill into your agent's skill directory rather than copying it — keep one
source copy so updates don't drift:

```bash
ln -s "$PWD/skills/handover" ~/.claude/skills/handover
```

## License

MIT — see [LICENSE](LICENSE).
