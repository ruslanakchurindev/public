---
name: gh-identity
description: Selects and verifies the correct GitHub account before any GitHub CLI operation on a machine that holds several GitHub identities. One account is always "active", so a bare `gh` command silently acts as that account regardless of which repository you are in — which is how a personal pull request ends up authored by the work account. Use whenever a task touches the GitHub CLI or writes to GitHub: opening, merging, reviewing or commenting on a pull request; creating or editing issues, releases, labels, secrets, workflows or repos; calling `gh api`; forking. Also use when a `gh` command fails with a 404, permission or wrong-account error, when a PR or comment shows up under an unexpected author, or when the user asks which GitHub account a repository belongs to.
license: MIT
---

# GitHub identity per repository

Several accounts can share one `gh` config, each reached through an alias. One is
*active*, and it is usually the wrong one — so `gh pr create` in a personal
repository opens the pull request **as the work account**, invisibly, until
someone looks at the author.

## The rule

Never run bare `gh` for anything that touches a repository. Always name the
account: `gh <alias> ...`. A `PreToolUse` hook enforces this in Claude Code and
Codex, but a tool hook is a guardrail, not a complete boundary — resolve first,
do not rely on being blocked. (Hook not firing? See [INSTALL.md](INSTALL.md).)

## Resolve, then verify

One command answers both. Run it by absolute path, naming the repository:

```bash
/absolute/path/to/dev-public/skills/gh-identity/scripts/gh-identity-guard.sh --check <repo>
```

```
repo:     /absolute/path/to/some-repo
remote:   github-personal (octocat)
use:      gh personal ...
expect:   octocat
verified: octocat
```

`--resolve` stops after `use:`/`expect:` and makes no network call; `--check` also
runs `gh <alias> api user --jq .login`. Both default to the current directory. Run
`--check` once before the first GitHub write in a session, and once per repository
when the task spans several. Use the alias it prints for **every** `gh` command in
that repository for the rest of the session.

The mapping lives in one file (`~/.config/gh-identity/identities.tsv` by default),
which the hook resolves through as well. Do not restate the table in a
repository's `AGENTS.md`; point at this skill.

## Invocation contract

Each enforcement layer matches on the *literal* command string, so spelling
decides whether it fires:

- **Invoke the guard by its absolute path**, exactly as above, with the repository
  as an argument. A `~/` prefix, a relative path, and a `bash <script>` prefix are
  different strings — each misses the sandbox exemption, so the guard runs
  sandboxed and reports `UNVERIFIED` on an empty token while `gh auth status`
  still shows the account logged in.
- **Name the target repository in the command: `cd <repo> && gh <alias> ...`.** The
  hook resolves identity from the tool call's `cwd`, or from a leading
  `cd <path> &&` — that inline `cd` is the directory `gh` will actually run in.
  Spell the path literally: the hook never expands `$VAR` or `$(...)`, and a path
  it cannot read falls back to `cwd`, which usually means a block. A standalone
  `cd` in an earlier tool call does not carry; Codex reports the session directory
  for every call.
- **Pass pull request and issue bodies as `--body-file <path>`.** The
  `--body "$(cat <<'EOF' ...)"` idiom is command substitution, which some
  sandboxes reject before `gh` runs.

## Verification states

Treat the `--check` exit status as a state contract:

- **`verified` (exit 0)** — the live login matches. Continue with that alias.
- **`MISMATCH` (exit 1)** — the call succeeded and returned the wrong login.
- **`UNVERIFIED` (exit 2)** — no identity was determined. An empty token means the
  run was sandboxed: check the invocation form above, then the sandbox exemption
  in [INSTALL.md](INSTALL.md). Leave credentials unchanged.

Both failure states stop the task: make no GitHub writes. Also stop and report
when the repository's host/owner is missing from the identity table (ask which
account owns it — adding a row is operator work), and when a `gh` command 404s on
a repository you know exists, the signature of querying a private repository as
the wrong account.

Preserve account configuration in every case. Never run `gh auth switch`,
`gh auth login` or `gh auth logout` (they re-point every other repository and
session; the hook blocks them), never print or write a token, and never fall back
to another account because the right one failed.

## Scope

This covers `gh` only. `git` identity is a separate mechanism — `includeIf` and
`insteadOf` in the user's gitconfig pick `user.email`, the signing key and the SSH
host alias from the remote URL — so use the repository's configured remote and
leave its auth config alone unless asked. Background, configuration and
troubleshooting: [README.md](README.md).
