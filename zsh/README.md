# Zsh customizations

Sourced Zsh modules, not standalone executables. Load any one independently.

## Requirements

- Zsh 5.x.
- `caffeinate.zsh` — macOS only; uses `/usr/bin/caffeinate` and `/usr/bin/pgrep`.
- `gpull.zsh` — Git. Expects repositories directly below `~/Code` to use remote
  `origin` and branch `main`.
- `worktrees.zsh` — Git and [fzf](https://github.com/junegunn/fzf). Opens editors
  with the `code` CLI, else macOS `open` with Visual Studio Code; the picker's copy
  action uses `pbcopy` and prints the path when that is missing. `wt pr` also needs
  the GitHub CLI (`gh`).

`wt sync` and `wt pr` fetch and rebase against `origin/main`, and push to the
branch's configured destination (`origin` when it has no upstream). Repositories
with other remote or branch names need adapting first.

## Install

Symlink the modules you want into the Oh My Zsh custom directory. `ln -f` is
deliberately not used, so an existing customization is never overwritten:

```bash
custom_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
mkdir -p "$custom_dir"
ln -s "$PWD/zsh/caffeinate.zsh" "$custom_dir/caffeinate.zsh"
ln -s "$PWD/zsh/gpull.zsh" "$custom_dir/gpull.zsh"
ln -s "$PWD/zsh/worktrees.zsh" "$custom_dir/worktrees.zsh"
exec zsh
```

Without Oh My Zsh, `source` each module from `.zshrc` by absolute path.

## `caf` and `decaf`

`caf` starts `caffeinate -di` detached, so it outlives the terminal that started
it. A new session first stops the one tracked by an earlier invocation.

| Command | Behavior |
| --- | --- |
| `caf` | Caffeinate indefinitely. |
| `caf N` | Caffeinate for `N` positive integer hours; replaces the current session. |
| `decaf` | Stop the tracked session. Harmless when none is running. |

The PID file is `${TMPDIR:-/tmp}/caf-$UID/pid`, in a per-user mode-`700` directory
(file mode `600`). Before signalling a PID the module rejects unsafe state
directories, symlinks, non-regular files, files owned by another user, stale PIDs,
and processes not named `caffeinate`. It never stops a `caffeinate` started by
another tool.

## `gpull`

Discovers Git repositories directly below `~/Code`, fetches `origin` for each
concurrently (eight workers by default), and fast-forwards local `main` when safe.
Results print in directory order even though work runs in parallel. Nested
repositories are not discovered.

Change the root or the worker limit before sourcing:

```zsh
typeset -g _GPULL_CODE_BASE="$HOME/src"
typeset -g _GPULL_JOBS=4
source /absolute/path/to/public/zsh/gpull.zsh
```

A clean, checked-out `main` is fast-forwarded in place; with another branch (or a
detached HEAD) checked out, the local `main` reference is advanced without
switching. Skipped safely: a dirty checked-out `main`, a missing local `main`, and
a local `main` ahead of or diverged from `origin/main`. A skip does not fail the
command; an operational error such as a failed fetch does. `gpull` never pushes,
stashes, resets, switches branches, creates `main`, or does a non-fast-forward
update.

## `wt` worktree workspaces

`wt` treats each Git worktree as a workspace. It discovers main checkouts directly
below `~/Code` and creates worktrees at `~/Worktrees/<repo>/<branch>`. Asking Git
for each repository's full worktree list also finds Codex and Claude Code
worktrees outside those folders; the picker marks those `⚙`.

Rows read `<repo>/<branch>`. `<repo>` comes from the repository's own main
worktree — its basename below `~/Code`, or the first path component below
`~/Worktrees` — never from the directory the scan entered, so a repository
reachable through several directories is listed once, under one label.

Set different roots before sourcing if your layout differs:

```zsh
export CODE_BASE="$HOME/src"
export WORKTREE_BASE="$HOME/worktrees"
source /absolute/path/to/public/zsh/worktrees.zsh
```

| Command | Behavior |
| --- | --- |
| `wt` | fzf picker over all worktrees, prefiltered to the current repository. |
| `wt new <branch> [base]` | Create `<branch>` from `base` (default `HEAD`) under `$WORKTREE_BASE/<repo>/`, then open it in VS Code. |
| `wt rm` | Pick and force-remove a linked worktree, then optionally delete its local branch. |
| `wt sync` | Stash, fetch, fast-forward checked-out `main`, rebase the current branch on `origin/main`, restore the stash. |
| `wt pr` | Require a clean tree, rebase on `origin/main`, push, and open or show the branch's GitHub PR. |
| `wt pr "message"` | `git add -A`, commit with the message, then the same rebase/push/PR flow. |
| `wt open` | Open the current worktree root in VS Code. |
| `wt help` | Print the built-in command summary. |

Picker keys: `enter` cd, `ctrl-o` VS Code, `ctrl-x` remove, `ctrl-y` copy path.

### Safety notes

- `wt rm` refuses to remove a repository's main working tree. For linked worktrees
  it uses `git worktree remove --force`, so uncommitted files there can be
  discarded. Branch deletion is a separate prompt.
- `wt sync` stashes untracked files too. On a rebase conflict it leaves the rebase
  for you and keeps the stash recoverable; fetch or fast-forward failures restore
  the stash automatically.
- `wt pr "message"` stages every change in the worktree — review `git status`
  first. A push after a rebase uses `--force-with-lease`, never a plain force.
- Picker previews and discovery suppress Git errors, so one broken checkout does
  not hide the other repositories.

### Choosing a GitHub account

`wt pr` is the only command that talks to GitHub, and a bare `gh` acts as whichever
account is currently active. On a machine holding several that is usually wrong,
and nothing says so until someone reads the pull request author.

Define a `wt_gh_alias` function taking the repository root and printing the `gh`
account alias to use; every `gh` call in `wt pr` then runs as `gh <alias> ...`.
Leave it undefined — the default — and the calls stay bare.

```zsh
wt_gh_alias() {
  case "$(command git -C "$1" remote get-url origin)" in
    *github.com:my-org/*) print -r -- work ;;
    *) print -r -- personal ;;
  esac
}
```

A ready-made implementation ships with the
[gh-identity](../skills/gh-identity/README.md#wt-pr-integration) skill, reading the
same identity table the skill and its hook resolve through.

The alias must be 1–64 characters starting with a letter or digit, then letters,
digits, dots, underscores, or hyphens. `wt pr` resolves it before committing,
rebasing or pushing anything, so a function that fails stops the command at no
cost. There is deliberately no fallback to a bare `gh`.

## Test

Checks syntax and dispatch, validates `caf` without launching `caffeinate`,
exercises `gpull` against disposable local repositories, and covers worktree
discovery, removal, sync and PR flows with a fake `gh`. No network requests:

```bash
GIT_CONFIG_GLOBAL=/dev/null zsh/scripts/test-zsh.sh
```
