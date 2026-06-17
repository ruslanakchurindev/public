# Handover

An agent skill that packages a working session into a curated, portable handover
artifact — and loads the latest one to pick up where you left off.

The hard part of a handover is not workspace state; the next agent can re-run
`git status` itself. The irrecoverable part is **conversation state**: decisions
and their rationale, rejected alternatives, constraints the user voiced, and dead
ends already explored. This skill captures those in human-readable markdown stored
outside the repo, and lets deterministic scripts capture the recoverable rest.

## Modes

- **Produce** (default) — package the current session into one markdown artifact.
- **Resume** — load the latest artifact for the current repo, summarize the pickup
  point, and wait for you to say to continue.

## Command surface

The scripts do the deterministic work; the skill body (`SKILL.md`) drives them.

```bash
scripts/handover.sh path .                  # print (and create) the store dir
scripts/handover.sh save .                  # stdin -> timestamped artifact; prints saved path
scripts/handover.sh latest .                # print path of newest artifact
scripts/handover.sh list .                  # list artifact paths, newest first
scripts/handover.sh state . [since-ref]     # print workspace snapshot
```

Use `--name NAME` with `save`, `latest`, or `list` only when several workstreams in
the same repo need separate `latest` pointers. `NAME` must be 1–64 characters starting
with a letter or digit, then letters, digits, dots, underscores, or hyphens; names
starting with `latest` are reserved. Named saves update only `latest-NAME.md`; unnamed
saves update only `latest.md`.

## Configuration

All optional environment variables:

- `HANDOVER_HOME` — root for stored artifacts (default `~/.handovers/`).
- `HANDOVER_REPO_NAME` — override the detected repo name in artifact metadata.
- `HANDOVER_WORKSPACE_NAME` — override the detected workspace name.
- `HANDOVER_MODEL_NAME` — override the detected model name.

Artifacts live under `<HANDOVER_HOME>/<repo-basename>-<path-hash>/` with private
permissions (directories `700`, files `600`).

Keep `HANDOVER_HOME` on a private, non-shared path — the store is not hardened against
a symlinked or world-writable location. The `<path-hash>` is derived from the
repository's shared git directory, so **all linked worktrees of one repo share a single
store** — a handover saved in a worktree is found by `latest`/`list` from the main
checkout or any sibling worktree, and the metadata's `workspace` / `workspace-path`
record which worktree produced it. Use `--name` when concurrent worktrees need separate
`latest` pointers. Moving the repo directory starts a fresh store; earlier handovers
remain under the old path.

## Privacy

Handover artifacts are curated summaries, not recordings. By design the skill
instructs the agent **not** to capture raw transcripts, secrets, `.env` values,
tokens, or tool session IDs. Artifacts are written outside the repo with private
permissions (directories `700`, files `600`) enforced by the save script.

## Install

Install through your agent's skill mechanism, or symlink this `skills/handover/`
directory into your agent's skill directory rather than copying it — keep one source
copy so `SKILL.md`, the scripts, and `EXAMPLES.md` don't drift.

Requires `bash`, `git`, and a SHA-1 tool (`shasum` on macOS, `sha1sum` on Linux)
for the per-repo store path. GitHub CLI (`gh`) is optional, used only for open-PR
lookup in workspace snapshots.

Run the tests with `GIT_CONFIG_GLOBAL=/dev/null scripts/test-handover.sh` — the
override keeps a contributor's global git config out of the fixtures.

## License

MIT — see [LICENSE](../../LICENSE).
