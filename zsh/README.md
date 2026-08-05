# Zsh customizations

These are sourced Zsh modules rather than standalone executables. Install either
one independently or load both.

## Requirements

- Zsh 5.x.
- `caffeinate.zsh` is macOS-only and uses `/usr/bin/caffeinate` and
  `/usr/bin/pgrep`.
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
directory. Omit either link if you only want one module:

```bash
custom_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
mkdir -p "$custom_dir"
ln -s "$PWD/zsh/caffeinate.zsh" "$custom_dir/caffeinate.zsh"
ln -s "$PWD/zsh/worktrees.zsh" "$custom_dir/worktrees.zsh"
exec zsh
```

The commands deliberately do not use `ln -f`; an existing customization will not
be overwritten.

### Plain Zsh

Source the modules from `.zshrc` using the checkout's absolute path:

```zsh
source /absolute/path/to/public/zsh/caffeinate.zsh
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

## `wt` worktree workspaces

`wt` treats each Git worktree as a workspace. By default it discovers main
checkouts immediately below `~/Code` and creates manual worktrees below
`~/Worktrees/<repo>/<branch>`. Asking Git for each repository's complete worktree
list also discovers linked Codex and Claude Code worktrees outside those folders;
the picker marks paths under `.codex/worktrees` or `.claude/worktrees` with `⚙`.

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
launching `caffeinate`, and exercises worktree discovery, removal, sync, and PR
flows against disposable local repositories and a fake `gh` command. It makes no
network requests:

```bash
GIT_CONFIG_GLOBAL=/dev/null zsh/scripts/test-zsh.sh
```
