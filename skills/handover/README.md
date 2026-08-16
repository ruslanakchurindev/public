# Handover

An agent skill that packages a working session into a curated, portable artifact
— and loads the latest one to pick up where you left off.

The hard part of a handover is not workspace state; the next agent can re-run
`git status` itself. The irrecoverable part is **conversation state**: decisions
and their rationale, rejected alternatives, constraints the user voiced, dead ends
already explored. This skill captures those in markdown stored outside the repo,
and lets scripts capture the recoverable rest.

- **Produce** (default) — package the current session into one markdown artifact.
- **Resume** — load the latest artifact for the current repo, summarize the pickup
  point, and wait.

## Command surface

The scripts do the deterministic work; `SKILL.md` drives them.

```bash
scripts/handover.sh path .                  # print (and create) the store dir
scripts/handover.sh save .                  # stdin -> timestamped artifact; prints saved path
scripts/handover.sh latest .                # print path of newest artifact
scripts/handover.sh list .                  # list artifact paths, newest first
scripts/handover.sh state . [since-ref]     # print workspace snapshot
```

`latest` and `list` scan the store — every artifact, named or not, ordered by the
UTC stamp in its filename rather than by mtime or by the `latest*.md` symlinks.
Those symlinks are written for convenience only: each tracks one save track, so
following one goes stale as soon as the next save uses a different name.

`latest` prefers the newest artifact produced in the **current worktree**. With
none there it falls back to the repo's newest and notes on stderr which worktree
produced it and whether that directory still exists; stdout stays a bare path.

`--name NAME` works with `save`, `latest` and `list`, for several workstreams in
one repo. `NAME` is 1–64 characters starting with a letter or digit, then letters,
digits, dots, underscores or hyphens; names starting with `latest` are reserved.
Being an explicit thread selector, it skips the worktree preference.

## Configuration

All optional:

| Variable | Purpose |
|----------|---------|
| `HANDOVER_HOME` | root for stored artifacts (default `~/.handovers/`) |
| `HANDOVER_REPO_NAME` | override the detected repo name in artifact metadata |
| `HANDOVER_WORKSPACE_NAME` | override the detected workspace name |
| `HANDOVER_MODEL_NAME` | override the detected model name |
| `HANDOVER_GH_ALIAS` | `gh` account alias for the open-PR lookup in `state` |

`HANDOVER_GH_ALIAS` matters on a machine holding several GitHub accounts: a bare
`gh` runs as whichever is active, so the lookup can answer for the wrong one —
reported as no PR, or as a 404 that reads like a missing repository.

```bash
HANDOVER_GH_ALIAS=work scripts/handover.sh state .
```

Leave it unset on a single-account machine and the call stays bare. The value has
the same character rules as `--name`, is passed to `gh` as one argument, and is
never expanded by a shell. An invalid value skips the lookup and says so rather
than falling back to the bare call. The lookup is read-only and optional either
way.

## Store layout

Artifacts live under `<HANDOVER_HOME>/<repo-basename>-<path-hash>/` with private
permissions (directories `700`, files `600`). Keep `HANDOVER_HOME` on a private,
non-shared path — the store is not hardened against a symlinked or world-writable
location.

The `<path-hash>` comes from the repository's shared git directory, so **all
linked worktrees of one repo share one store**: a handover saved in a worktree is
found from the main checkout or any sibling, the metadata's `worktree` field
records which one produced it, and a deleted worktree leaves its handovers
findable elsewhere. Moving the repo directory starts a fresh store; earlier
handovers stay under the old path and can be recovered by moving that directory to
the new hash printed by `handover.sh path .`.

## Privacy

Artifacts are curated summaries, not recordings. The skill instructs the agent
**not** to capture raw transcripts, secrets, `.env` values, tokens, or tool session
IDs.

## Install

Install through your agent's skill mechanism, or symlink this directory into the
agent's skill directory rather than copying it, so `SKILL.md`, the scripts and
`EXAMPLES.md` cannot drift.

Requires `bash`, `git`, and a SHA-1 tool (`shasum` or `sha1sum`). The GitHub CLI is
optional, used only for the open-PR lookup.

Tests: `GIT_CONFIG_GLOBAL=/dev/null scripts/test-handover.sh` — the override keeps
a contributor's global git config out of the fixtures.

## License

MIT — see [LICENSE](../../LICENSE).
