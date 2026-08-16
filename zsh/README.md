# Zsh customizations

These are sourced Zsh modules rather than standalone executables. Install any
module independently or load all of them.

## Requirements

- Zsh 5.x.
- `caffeinate.zsh` is macOS-only and uses `/usr/bin/caffeinate` and
  `/usr/bin/pgrep`.
- `gpull.zsh` requires Git. It expects repositories immediately below `~/Code`
  to use the remote `origin` and branch `main`.
- `worktrees.zsh` requires Git and uses
  [fzf](https://github.com/junegunn/fzf) for interactive pickers.
- `wt open` and the picker's open action use the `code` CLI when available,
  otherwise macOS `open` with Visual Studio Code.
- The picker's copy action uses macOS `pbcopy`. If it is unavailable, the path is
  printed instead.
- `wt pr` additionally requires the GitHub CLI (`gh`) to find or create a pull
  request.

`wt sync` and `wt pr` fetch and rebase against `origin/main`. An already-tracked
branch pushes to Git's configured push destination; a branch without an upstream
is pushed to `origin`. Repositories with different remote or branch names need
adapting before use.

## Install

### Oh My Zsh

From this repository checkout, symlink the modules into the Oh My Zsh custom
directory. Omit any links for modules you do not want:

```bash
custom_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
mkdir -p "$custom_dir"
ln -s "$PWD/zsh/caffeinate.zsh" "$custom_dir/caffeinate.zsh"
ln -s "$PWD/zsh/gpull.zsh" "$custom_dir/gpull.zsh"
ln -s "$PWD/zsh/worktrees.zsh" "$custom_dir/worktrees.zsh"
exec zsh
```

The commands deliberately do not use `ln -f`; an existing customization will not
be overwritten.

### Plain Zsh

Source the modules from `.zshrc` using the checkout's absolute path:

```zsh
source /absolute/path/to/public/zsh/caffeinate.zsh
source /absolute/path/to/public/zsh/gpull.zsh
source /absolute/path/to/public/zsh/worktrees.zsh
```

## `caf` and `decaf`

`caf` starts `caffeinate -di` as a detached process, so it survives the terminal
that started it. Starting a new session first stops the process tracked by an
earlier invocation.

| Command | Behavior |
| --- | --- |
| `caf` | Caffeinate indefinitely. |
| `caf N` | Caffeinate for `N` positive integer hours; replaces or resets the current session. |
| `decaf` | Stop the tracked session. It is harmless when none is running. |

The module stores its PID file at `${TMPDIR:-/tmp}/caf-$UID/pid` in a per-user,
mode-`700` state directory; the PID file has mode `600`. Before signaling a PID it
rejects unsafe state directories, symlinks, non-regular files, files owned by another
user, stale PIDs, and processes whose name is not `caffeinate`. It does not stop
`caffeinate` processes started by other tools because they are not in its PID file.

## `gpull` repository sync

`gpull` discovers Git repositories immediately below `~/Code`, fetches `origin`
for each one concurrently, and fast-forwards its local `main` when that is safe.
It prints repository results in directory order even though work runs in parallel.

| Command | Behavior |
| --- | --- |
| `gpull` | Sync all discovered repositories with up to eight concurrent workers. |

Set a different root or worker limit before sourcing the module:

```zsh
typeset -g _GPULL_CODE_BASE="$HOME/src"
typeset -g _GPULL_JOBS=4
source /absolute/path/to/public/zsh/gpull.zsh
```

A clean, checked-out `main` is fast-forwarded in place. When another branch (or
a detached HEAD) is checked out, `gpull` advances the local `main` reference
without switching branches. It safely skips dirty checked-out `main` branches,
missing local `main` branches, and histories where local `main` is ahead of or
diverged from `origin/main`. A skip does not make the aggregate command fail;
an operational error such as a failed fetch does.

`gpull` never pushes, stashes, resets, switches branches, creates `main`, or
performs a non-fast-forward update. Its scope is intentionally shallow: nested
repositories are not discovered.

## `wt` worktree workspaces

`wt` treats each Git worktree as a workspace. By default it discovers main
checkouts immediately below `~/Code` and creates manual worktrees below
`~/Worktrees/<repo>/<branch>`. Asking Git for each repository's complete worktree
list also discovers linked Codex and Claude Code worktrees outside those folders;
the picker marks paths under `.codex/worktrees` or `.claude/worktrees` with `⚙`.

Rows read `<repo>/<branch>`, where `<repo>` is derived from the repository's own
main worktree — its basename below `~/Code`, or the first path component below
`~/Worktrees` — never from the name of the directory the scan entered. A
repository is identified by that same main worktree path, so one reachable
through several directories (say `~/Worktrees/keyter` and `~/Code/deriul-keyter`)
is listed once, under one label, and a clone rooted at
`~/Worktrees/keyter-canary/integration` is labelled `keyter-canary`.

Set different roots before sourcing the module if your layout differs:

```zsh
export CODE_BASE="$HOME/src"
export WORKTREE_BASE="$HOME/worktrees"
source /absolute/path/to/public/zsh/worktrees.zsh
```

| Command | Behavior |
| --- | --- |
| `wt` | Open the all-repository fzf picker, prefiltered to the current repository when possible. |
| `wt new <branch> [base]` | Create `<branch>` from `base` (default `HEAD`) under `$WORKTREE_BASE/<repo>/`, then open it in VS Code. |
| `wt rm` | Pick and force-remove a linked worktree, then optionally delete its local branch. |
| `wt sync` | Stash local changes, fetch, fast-forward checked-out `main`, rebase the current branch on `origin/main`, and restore the stash. |
| `wt pr` | Require a clean tree, rebase on `origin/main`, push, and open or show the branch's GitHub PR. |
| `wt pr "message"` | Stage all changes with `git add -A`, commit with the supplied message, then run the same rebase/push/PR flow. |
| `wt open` | Open the current worktree root in VS Code. |
| `wt help` | Print the built-in command summary. |

Picker keys:

| Key | Action |
| --- | --- |
| `enter` | Change the current shell directory to the selected worktree. |
| `ctrl-o` | Open the selected worktree in VS Code. |
| `ctrl-x` | Remove the selected worktree. |
| `ctrl-y` | Copy the selected path, or print it if `pbcopy` is unavailable. |

### Choosing a GitHub account

`wt pr` is the only command that talks to GitHub, and a bare `gh` acts as whichever
account is currently active. On a machine holding one GitHub account that is always
right and nothing below applies. On a machine holding several it is usually wrong:
the pull request opens under the wrong identity, and nothing says so until someone
reads the author.

Define a `wt_gh_alias` function to say which account a repository belongs to. It
receives the repository root and prints the `gh` account alias to use:

```zsh
wt_gh_alias() {
  case "$(command git -C "$1" remote get-url origin)" in
    *github.com:my-org/*) print -r -- work ;;
    *) print -r -- personal ;;
  esac
}
```

Every `gh` call in `wt pr` then runs as `gh <alias> ...`. Leave the function
undefined — the default — and the calls stay bare, exactly as before.

The alias must be 1–64 characters starting with a letter or digit, then letters,
digits, dots, underscores, or hyphens. `wt pr` resolves it before it commits,
rebases, or pushes anything, so a hook that fails or answers with something else
stops the command immediately and costs nothing. There is deliberately no fallback
to a bare `gh`: opening a pull request as the wrong account is the mistake the hook
exists to prevent.

### Safety notes

- `wt rm` refuses to remove a repository's main working tree. It does use
  `git worktree remove --force` for linked worktrees, so uncommitted files in the
  selected worktree can be discarded. Branch deletion is a separate prompt.
- `wt sync` includes untracked files in its temporary stash. If rebase conflicts,
  it leaves the rebase for you to resolve and keeps the stash recoverable. Fetch
  or fast-forward failures restore the stash automatically.
- `wt pr "message"` stages every change in the worktree. Review `git status`
  first. If a rebase changes an already-published branch, the push uses
  `--force-with-lease`, never an unconditional force push.
- Picker previews and discovery suppress Git errors so one broken checkout does
  not prevent other repositories from appearing.

## Test

The local test checks syntax and command dispatch, validates `caf` without
launching `caffeinate`, verifies `gpull` concurrency and safety against disposable
local repositories, and exercises worktree discovery, removal, sync, and PR flows
with a fake `gh` command. It makes no network requests:

```bash
GIT_CONFIG_GLOBAL=/dev/null zsh/scripts/test-zsh.sh
```
