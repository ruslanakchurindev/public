# Public tools

Small, self-contained command-line helpers and agent skills.

## Zsh customizations

- **[caffeinate](zsh/caffeinate.zsh)** — `caf` and `decaf` manage one tracked
  macOS `caffeinate` session, including optional durations in hours.
- **[gpull](zsh/gpull.zsh)** — `gpull` concurrently fetches repositories under
  `~/Code` and safely fast-forwards their local `main` branches.
- **[worktrees](zsh/worktrees.zsh)** — `wt` discovers, creates, opens, syncs,
  removes, and publishes Git worktree-based workspaces.

See the **[Zsh README](zsh/README.md)** for requirements, installation, command
reference, configuration, and safety notes.

## Agent skills

- **[handover](skills/handover/)** — package a coding session's decisions, failed
  approaches, constraints, and next steps into a portable handover artifact stored
  outside the repo, then load the latest one to pick up later.
  See [skills/handover/README.md](skills/handover/README.md).

### Install a skill

Symlink a skill into your agent's skill directory rather than copying it. This
keeps one source copy, so updates do not drift:

```bash
ln -s "$PWD/skills/handover" ~/.claude/skills/handover
```

## License

MIT — see [LICENSE](LICENSE).
