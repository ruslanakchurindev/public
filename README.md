# Public tools

Small, self-contained command-line helpers and agent skills.

## Zsh customizations

- **[caffeinate](zsh/caffeinate.zsh)** — `caf` and `decaf` manage one tracked
  macOS `caffeinate` session.
- **[gpull](zsh/gpull.zsh)** — fetch every repository under `~/Code` in parallel
  and safely fast-forward each local `main`.
- **[worktrees](zsh/worktrees.zsh)** — `wt` discovers, creates, opens, syncs,
  removes, and publishes Git worktree workspaces.

Requirements, command reference and safety notes: **[zsh/README.md](zsh/README.md)**.

## Command-line tools

- **[sklink](sklink/)** — link one copy of each agent skill into every AI agent
  on the machine (Claude Code, Codex, `.agents`) and into individual repos, from
  one declarative manifest. See [sklink/README.md](sklink/README.md).

## Agent skills

- **[gh-identity](skills/gh-identity/)** — pick and verify the right GitHub
  account before any `gh` command, on a machine that holds several. Ships a
  `PreToolUse` hook that blocks a `gh` call naming the wrong account.
  See [skills/gh-identity/README.md](skills/gh-identity/README.md).
- **[handover](skills/handover/)** — package a session's decisions, failed
  approaches and next steps into a portable artifact stored outside the repo,
  then load the latest one to pick up later.
  See [skills/handover/README.md](skills/handover/README.md).

### Install a skill

Symlink, never copy — one source copy cannot drift:

```bash
ln -s "$PWD/skills/handover" ~/.claude/skills/handover
```

For several skills, or the same skill across several agents, let
[sklink](sklink/) maintain the links:

```bash
sklink add "$PWD/skills/handover" --user
```

## License

MIT — see [LICENSE](LICENSE).
