# gh-identity

Pick and verify the right GitHub account before any `gh` command, on a machine
that holds more than one.

The GitHub CLI keeps several accounts in one config and marks exactly one
*active*. A bare `gh` runs as that account whatever repository you are in, so
`gh pr create` in a personal checkout can open the pull request under a work
identity — and nothing reports it; you find out by reading the author.

Both halves of the fix live here, resolving through the same function and the
same table, so they cannot disagree:

- **Guidance** — [`SKILL.md`](SKILL.md), telling an agent to resolve the account
  first and verify it once per repository.
- **Enforcement** — [`scripts/gh-identity-guard.sh`](scripts/gh-identity-guard.sh),
  a `PreToolUse` hook for Claude Code and Codex that blocks a `gh` call not naming
  the required account.

## Requirements

`git` and `bash` 3.2+. [`jq`](https://jqlang.github.io/jq/) for hook mode —
without it the hook fails closed on any payload that could carry a `gh` call, and
passes everything else so the machine stays fixable. The
[GitHub CLI](https://cli.github.com/) for `--check`.

## Install

```bash
# 1. Create the identity table (never overwrites an existing one).
skills/gh-identity/scripts/gh-identity-guard.sh --init

# 2. Edit it: one row per account.
$EDITOR ~/.config/gh-identity/identities.tsv

# 3. Verify against a repository you know the answer for.
skills/gh-identity/scripts/gh-identity-guard.sh --check ~/some/repo

# 4. Symlink the skill into your agent's skill directory.
ln -s "$PWD/skills/gh-identity" ~/.claude/skills/gh-identity
```

Registering the hook and the sandbox exemption `--check` needs:
[INSTALL.md](INSTALL.md).

## The identity table

User data, so it lives at `$XDG_CONFIG_HOME/gh-identity/identities.tsv` (default
`~/.config/gh-identity/identities.tsv`) and never inside this checkout — an update
cannot conflict with it, and this repository carries no account names of its own,
only the commented [template](templates/identities.tsv). Override with
`GH_IDENTITY_TABLE`.

Four whitespace-separated columns; `#` starts a comment:

```
# ssh-host        owner         gh-alias   expected-login
github-personal   octocat       personal   octocat
github-work       example-org   work       octocat-at-example
```

| Column | Meaning |
|--------|---------|
| `ssh-host` | The `Host` alias in `~/.ssh/config` the remote uses. Matched first — the strong signal. |
| `owner` | The org or user that owns the repository. Fallback, for remotes written as plain `github.com`. |
| `gh-alias` | The alias to invoke: `gh <alias> ...`. |
| `expected-login` | What `gh <alias> api user --jq .login` must return. |

Each alias must exist in `~/.config/gh/config.yml` and resolve that account's own
token rather than the active one:

```yaml
aliases:
  personal: '!GH_TOKEN="$(gh auth token --hostname github.com --user octocat)" gh "$@"'
```

Adding an identity is those two steps — the skill, the hook and the `wt`
integration all read the same row.

## Command surface

```bash
gh-identity-guard.sh --resolve [dir]   # which account this repo needs; no network call
gh-identity-guard.sh --check   [dir]   # --resolve, then verify the live login
gh-identity-guard.sh --init            # seed the table from the template
gh-identity-guard.sh --help            # usage
gh-identity-guard.sh                   # PreToolUse hook: reads JSON on stdin
```

`--resolve` and `--check` default to the current directory.

```
$ gh-identity-guard.sh --check ~/some/repo
repo:     /absolute/path/to/some-repo
remote:   github-personal (octocat)
use:      gh personal ...
expect:   octocat
verified: octocat
```

| Exit | State | Meaning |
|------|-------|---------|
| 0 | `verified` | The live login matches. Use the printed alias. |
| 1 | `MISMATCH` | The call succeeded and returned a different login. |
| 2 | `UNVERIFIED` | No identity determined: unresolvable repo, failed call, or empty login. |

Both failures are stop conditions — the account is wrong or unknown, and neither
is a reason to try another one. `--resolve` exits 1 when it cannot resolve, and
never contacts the network.

## What the hook decides

It reads the tool call as JSON on stdin and either stays silent (allow) or prints
a deny with a reason the agent reads.

| Command | Decision |
|---------|----------|
| `gh personal pr create` in an `octocat` repo | allow — the right alias |
| `gh pr create` | deny — bare, so it runs as the active account |
| `gh work pr create` in an `octocat` repo | deny — possible cross-account write |
| `gh --version`, `gh help`, `gh alias list`, `gh auth status` | allow — identity-neutral |
| `gh auth switch` / `login` / `logout` | deny — always, aliased or not |
| `gh` in a repo missing from the table | deny — the account cannot be proven |
| `npm test`, `git push`, `echo highlight` | allow — no `gh` invocation |

- The whole line is scanned: `git push && gh pr create` and `GH_DEBUG=1 gh ...` are
  caught; `gh` inside another word or a path is not.
- Identity comes from a directory — the call's `cwd`, or a leading `cd <path> &&`
  — never from `--repo`, `-R`, or a positional `owner/name`. Nothing is expanded,
  so a `cd` target holding `$VAR`, a second chained `cd`, or a non-directory falls
  back to `cwd`: stricter, never looser.
- Unknown means blocked. No `origin`, or no table row, denies rather than
  defaulting to the active account.
- Only shell tools are inspected — Codex's `apply_patch` also carries its payload
  in `tool_input.command`.

A wrong-alias deny names its directory basis and offers both remedies, because
"wrong alias for this repo" and "right alias, wrong directory" are indistinguishable
from inside the hook.

## Scripts that call `gh` for you

The hook only sees a command string, so a script running `gh` two processes down
passes untouched and that `gh` runs as the active account. The one such script
here is [`handover.sh state`](../handover/README.md), whose snapshot includes an
open-PR lookup. It takes the account through `HANDOVER_GH_ALIAS`, and the hook
requires that name:

```bash
HANDOVER_GH_ALIAS=personal skills/handover/scripts/handover.sh state .
```

Inline on the command — an exported variable is invisible from a command string.
Required only where an identity resolves. Anything else that shells out to `gh`
has the same hole and the same fix.

## `wt pr` integration

[`zsh/worktrees.zsh`](../../zsh/README.md#choosing-a-github-account) calls a
`wt_gh_alias` function, if defined, to learn which account a repository belongs
to. [`scripts/wt-gh-alias.zsh`](scripts/wt-gh-alias.zsh) is that definition,
resolving through `--resolve` so the mapping stays in one file:

```bash
ln -s "$PWD/skills/gh-identity/scripts/wt-gh-alias.zsh" \
      "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/wt-gh-alias.zsh"
```

It finds the guard beside itself; if you copy it elsewhere, export
`GH_IDENTITY_GUARD` with the guard's absolute path before sourcing. A missing
guard makes `wt_gh_alias` fail, and `wt pr` stops rather than falling back to a
bare `gh`.

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| Every `gh` command is blocked, even in a configured repo | The table is missing or has no uncommented rows. `--init` creates it. |
| `--check` says `UNVERIFIED: ... no oauth token found`, but `gh auth status` shows the account logged in | The check ran in a sandbox that cannot reach the credential store. Exemptions match the literal command string — re-run by the guard's canonical absolute path. Still failing? No exemption covers it yet; see [INSTALL.md](INSTALL.md). |
| A `gh` command 404s on a repository you know exists | Querying a private repository as the wrong account. |
| The hook never fires | Not registered, or the agent was not restarted. Codex also needs the hook reviewed and trusted under `/hooks`. |

## Scope

`gh` only. `git` identity is a separate mechanism needing nothing from this skill:
`includeIf` selects `user.email` and the signing key from the repository's
location, and `insteadOf` rewrites `github.com` URLs to the right SSH host alias.

The guard is a guardrail, not an enforcement boundary. Per Codex's own hooks
documentation, *"Some specialized tool paths can opt out of the default hook
path."* The same applies to Claude Code, and a `gh` call typed straight into a
terminal is not intercepted at all. The hook lowers the odds; the habit in
`SKILL.md` is what prevents the mistake.

## Tests

```bash
bash skills/gh-identity/scripts/test-gh-identity.sh
```

Hermetic: throwaway git repositories, a throwaway identity table, and a stub `gh`.
It also asserts that `SKILL.md` and `INSTALL.md` agree on the guard's path, since
the sandbox exemption matches that string literally and nothing at runtime would
catch them drifting.
