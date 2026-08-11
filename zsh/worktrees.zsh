# Worktree tooling — one entry point: `wt`
# Bare `wt` opens an fzf picker over all worktrees (enter: cd, ^o: VS Code,
# ^x: remove, ^y: copy path); verbs run as subcommands (wt new/rm/sync/pr/open).
# Convention: manual worktrees live at ~/Worktrees/<repo>/<branch>; agent
# worktrees (Claude Code / Codex) are discovered wherever they live, tagged ⚙.
export WORKTREE_BASE="${WORKTREE_BASE:-$HOME/Worktrees}"
export CODE_BASE="${CODE_BASE:-$HOME/Code}"

_WT_GIT=$(command -v git)

# Internal: print a worktree path by branch, without splitting pathname spaces.
_wt_branch_path() {
  local line wt_path
  while IFS= read -r -d '' line; do
    case "$line" in
      'worktree '*) wt_path="${line#worktree }" ;;
      "branch refs/heads/$2") print -r -- "$wt_path"; return 0 ;;
    esac
  done < <("$_WT_GIT" -C "$1" worktree list --porcelain -z 2>/dev/null)
  return 1
}

# Internal: print the first (main) worktree path for a repository.
_wt_main_path() {
  local line
  while IFS= read -r -d '' line; do
    [[ "$line" == 'worktree '* ]] && { print -r -- "${line#worktree }"; return 0; }
  done < <("$_WT_GIT" -C "$1" worktree list --porcelain -z 2>/dev/null)
  return 1
}

# Internal: print the main worktree only when $2 belongs to the repository at $1.
_wt_owner_path() {
  local line wt_path main found=0
  while IFS= read -r -d '' line; do
    case "$line" in
      'worktree '*)
        wt_path="${line#worktree }"
        [[ -z "$main" ]] && main="$wt_path"
        [[ "$wt_path" == "$2" ]] && found=1
        ;;
    esac
  done < <("$_WT_GIT" -C "$1" worktree list --porcelain -z 2>/dev/null)
  (( found )) && print -r -- "$main"
}

# Internal: format one repository's worktrees for the picker.
_wt_emit_worktrees() {
  local line wt_path head branch tag
  while IFS= read -r -d '' line; do
    case "$line" in
      'worktree '*)
        wt_path="${line#worktree }"
        tag=$([[ "$wt_path" == */.(claude|codex)/worktrees/* ]] && print ' ⚙')
        ;;
      'HEAD '*) head="${line#HEAD }"; head="${head[1,7]}" ;;
      'branch refs/heads/'*)
        branch="${line#branch refs/heads/}"
        print -r -- "$wt_path :: $2/$branch$tag"
        ;;
      detached) print -r -- "$wt_path :: $2/(detached @ $head)$tag" ;;
    esac
  done < <("$_WT_GIT" -C "$1" worktree list --porcelain -z 2>/dev/null)
}

# Internal: name a repository from its own MAIN worktree path ($1), never from
# whichever directory a scan happened to enter — a base dir may be named
# anything. Under $CODE_BASE the repo *is* the directory, so basename. Under
# $WORKTREE_BASE the convention is <base>/<repo>/<branch>, so the first
# component below the base names the repo: a clone rooted at
# ~/Worktrees/keyter-canary/integration is "keyter-canary", not "integration".
_wt_repo_label() {
  local main="$1" code="${CODE_BASE%/}" base="${WORKTREE_BASE%/}" rest
  case "$main" in
    "$code"/*) print -r -- "${main:t}" ;;
    "$base"/*) rest="${main#"$base"/}"; print -r -- "${rest%%/*}" ;;
    *)         print -r -- "${main:t}" ;;
  esac
}

# Internal: list all worktrees across all repos under $WORKTREE_BASE and $CODE_BASE.
# A repository is keyed by its MAIN worktree path (the first `worktree list`
# entry), not by the name of the directory it was found in: ~/Worktrees/keyter
# and ~/Code/deriul-keyter are the same repo, and keying on the directory name
# emitted every one of its worktrees twice under two labels. Keying on identity
# means each repo is emitted exactly once, under one label, however many
# directories under either base point at it.
_wt_list_all() {
  local repo_dir gitdir anchor main
  local -A seen

  {
    # Repos reachable through $WORKTREE_BASE — git gives the full list
    # (main + linked) from any one worktree of the repo. Every .git under the
    # base dir is tried, not just the first: one base dir can hold worktrees of
    # several repos, and `find` returns directory order, so stopping at the
    # first hit emits an arbitrary one and silently drops the rest. Surplus
    # hits are free — repos already listed collapse on the identity check.
    # -print0/read -d '' so a newline in a pathname can't split a row.
    for repo_dir in "$WORKTREE_BASE"/*(N/); do
      while IFS= read -r -d '' gitdir; do
        # Emit from the worktree we actually found, not from $main — the main
        # worktree is still listed after its directory is deleted (prunable).
        anchor="${gitdir:h}"
        main=$(_wt_main_path "$anchor") || continue
        [[ -n "${seen[$main]-}" ]] && continue
        seen[$main]=1
        _wt_emit_worktrees "$anchor" "$(_wt_repo_label "$main")"
      done < <(find "$repo_dir" -name .git -maxdepth 4 -print0 2>/dev/null)
    done

    # Repos in $CODE_BASE not already reached above (typically no worktrees yet)
    for repo_dir in "$CODE_BASE"/*(N/); do
      [[ -d "$repo_dir/.git" || -f "$repo_dir/.git" ]] || continue
      main=$(_wt_main_path "$repo_dir") || continue
      [[ -n "${seen[$main]-}" ]] && continue
      seen[$main]=1
      _wt_emit_worktrees "$repo_dir" "$(_wt_repo_label "$main")"
    done
  } | sort -t'/' -k2
}

# Internal: for the repo that owns worktree $1, print its MAIN worktree path.
# Works even when $1's own directory has been deleted (a "prunable" entry):
# we never cd into $1, we scan the same bases _wt_list_all does and ask each
# repo whether it lists $1. We return the repo's *main* worktree (the first
# `worktree` entry) rather than any matching one — it always outlives the
# removal of $1, so later `git -C` calls (branch -D) don't land on a dir that
# `worktree remove` just deleted.
_wt_owner() {
  local target="$1" repo_dir gitdir anchor main
  for repo_dir in "$WORKTREE_BASE"/*(N/); do
    gitdir=$(find "$repo_dir" -name .git -maxdepth 4 -print -quit 2>/dev/null)
    [[ -z "$gitdir" ]] && continue
    anchor=$(dirname "$gitdir")
    main=$(_wt_owner_path "$anchor" "$target")
    [[ -n "$main" ]] && { echo "$main"; return 0; }
  done
  for repo_dir in "$CODE_BASE"/*(N/); do
    [[ -d "$repo_dir/.git" || -f "$repo_dir/.git" ]] || continue
    main=$(_wt_owner_path "$repo_dir" "$target")
    [[ -n "$main" ]] && { echo "$main"; return 0; }
  done
  return 1
}

# Internal: open path in VS Code. Falls back to the app when the `code`
# CLI shim isn't on PATH (VS Code: Cmd+Shift+P → "Install 'code' command").
_wt_open() {
  if command -v code >/dev/null; then
    code "$1"
  else
    open -a "Visual Studio Code" "$1"
  fi
}

# Internal: fzf picker over all worktrees; the verb is chosen at selection time.
# Inside a repo the query is prefilled to that repo — clear it to widen.
_wt_picker() {
  local out key selected wt_path repo_main
  local -a query
  # Repo name comes from the MAIN worktree (first `worktree list` entry), not
  # the current toplevel — inside a linked worktree the toplevel basename is
  # the worktree's dir name, and the prefilled query would match nothing.
  # Label it exactly as _wt_list_all does, or the query matches no row.
  repo_main=$(_wt_main_path "$PWD")
  [[ -n "$repo_main" ]] && query=(--query "'$(_wt_repo_label "$repo_main")/")
  out=$(_wt_list_all | fzf "${query[@]}" \
    --prompt="worktree> " \
    --header="enter: cd   ^o: VS Code   ^x: remove   ^y: copy path" \
    --expect=ctrl-o,ctrl-x,ctrl-y \
    --delimiter=' :: ' \
    --preview='git -C {1} status --short --branch 2>/dev/null' \
    --preview-window=down,40%)
  [[ -z "$out" ]] && return
  key=${out%%$'\n'*}
  selected=${out#*$'\n'}
  [[ -z "$selected" || "$selected" == "$key" ]] && return
  wt_path="${selected%% ::*}"
  case "$key" in
    ctrl-o) _wt_open "$wt_path" ;;
    ctrl-x) _wt_rm_path "$wt_path" ;;
    ctrl-y) if print -rn -- "$wt_path" | pbcopy 2>/dev/null; then
              echo "copied: $wt_path"
            else
              print -r -- "$wt_path"
            fi ;;
    *) cd "$wt_path" ;;
  esac
}

# wt — worktree interface. Bare `wt` opens the picker; verbs are subcommands.
wt() {
  case "$1" in
    "") _wt_picker ;;
    new) shift; _wt_new "$@" ;;
    rm) _wt_rm ;;
    sync) _wt_sync ;;
    pr) shift; _wt_pr "$@" ;;
    open) _wt_open_root ;;
    help|-h|--help) _wt_help ;;
    *) echo "wt: unknown subcommand '$1' (try: wt help)" >&2; return 1 ;;
  esac
}

# Internal: open VS Code at current worktree root (wt open)
_wt_open_root() {
  local root
  root=$("$_WT_GIT" rev-parse --show-toplevel 2>/dev/null)
  [[ -z "$root" ]] && { echo "not inside a git worktree"; return 1; }
  _wt_open "$root"
}

# Internal: create worktree at ~/Worktrees/<repo>/<branch> (wt new)
_wt_new() {
  local branch="$1"
  local base="${2:-HEAD}"
  [[ -z "$branch" ]] && { echo "usage: wt new <branch> [base]"; return 1; }

  local repo
  repo=$(basename "$("$_WT_GIT" rev-parse --show-toplevel 2>/dev/null)")
  [[ -z "$repo" ]] && { echo "not inside a git repo"; return 1; }

  local dest="$WORKTREE_BASE/$repo/$branch"
  mkdir -p "$(dirname "$dest")"
  "$_WT_GIT" worktree add -b "$branch" "$dest" "$base" && echo "→ $dest" && _wt_open "$dest"
}

# Internal: remove the worktree at $1, optionally deleting its branch.
# Used by `wt rm` and the picker's ^x binding.
_wt_rm_path() {
  # NB: not "path" — that's a special var tied to $PATH in zsh; assigning it
  # here would wipe the command search path for the rest of the function.
  local wt_path="$1"

  # Run git from the owning repo, never from $wt_path — the worktree dir may
  # already be gone (prunable), and "git -C <gone>" dies before doing anything.
  local owner
  owner=$(_wt_owner "$wt_path") || {
    echo "wt rm: no repo owns $wt_path (already removed?)" >&2
    return 1
  }

  # _wt_owner returns the repo's MAIN worktree. If that's what was picked, git
  # would refuse ("is a main working tree") — bail early with a clear message
  # instead of the raw fatal.
  if [[ "$wt_path" == "$owner" ]]; then
    echo "wt rm: $wt_path is the main working tree — refusing to remove it" >&2
    return 1
  fi

  # Take the branch from git, not the picker label (which is "repo/branch").
  local branch
  local line current
  while IFS= read -r -d '' line; do
    case "$line" in
      'worktree '*) current="${line#worktree }" ;;
      'branch refs/heads/'*)
        [[ "$current" == "$wt_path" ]] && { branch="${line#branch refs/heads/}"; break; }
        ;;
    esac
  done < <("$_WT_GIT" -C "$owner" worktree list --porcelain -z)

  echo "Removing worktree: $wt_path${branch:+ (branch: $branch)}"
  printf "Delete branch too? [y/N] "
  read confirm

  "$_WT_GIT" -C "$owner" worktree remove --force "$wt_path" || {
    echo "wt rm: worktree remove failed" >&2
    return 1
  }
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    if [[ -n "$branch" ]]; then
      "$_WT_GIT" -C "$owner" branch -D "$branch"
    else
      echo "wt rm: no branch to delete (detached HEAD)" >&2
    fi
  fi
}

# Internal: fzf picker → remove selected worktree (wt rm; skips main checkouts)
_wt_rm() {
  local selected
  selected=$(_wt_list_all | fzf --prompt="remove worktree> ")
  [[ -z "$selected" ]] && return
  _wt_rm_path "${selected%% ::*}"
}

# Internal: restore stash if a wt sync step failed mid-flow.
_wtsync_restore() {
  local root="$1" stashed="$2"
  (( stashed )) || return
  echo "→ restoring stash after failure"
  "$_WT_GIT" -C "$root" stash pop \
    || echo "  stash kept; recover via: git stash list"
}

# Internal (wt sync): rebase current worktree onto latest origin/main, preserving uncommitted work.
#   1. stash anything dirty (incl. untracked) with a recoverable label
#   2. git fetch origin
#   3. update local main in its own checkout (pull --ff-only)
#   4. git rebase origin/main
#   5. stash pop
_wt_sync() {
  local root branch main_path
  root=$("$_WT_GIT" rev-parse --show-toplevel 2>/dev/null) \
    || { echo "wt sync: not inside a git repo"; return 1; }
  branch=$("$_WT_GIT" -C "$root" symbolic-ref --short HEAD 2>/dev/null) \
    || { echo "wt sync: detached HEAD; bailing"; return 1; }
  [[ "$branch" == "main" ]] && { echo "wt sync: already on main — just git pull"; return 1; }

  main_path=$(_wt_branch_path "$root" main)
  [[ -z "$main_path" ]] && { echo "wt sync: main is not checked out in any worktree"; return 1; }

  local stashed=0 stash_msg
  if [[ -n $("$_WT_GIT" -C "$root" status --porcelain) ]]; then
    stash_msg="wt sync: WIP on $branch $(date +%Y-%m-%dT%H:%M:%S)"
    echo "→ stashing local changes: $stash_msg"
    "$_WT_GIT" -C "$root" stash push --include-untracked -m "$stash_msg" >/dev/null \
      || { echo "wt sync: stash failed; aborting"; return 1; }
    stashed=1
  fi

  echo "→ fetching origin"
  if ! "$_WT_GIT" -C "$root" fetch origin; then
    echo "wt sync: fetch failed"
    _wtsync_restore "$root" "$stashed"
    return 1
  fi

  echo "→ pulling main in $main_path"
  if ! "$_WT_GIT" -C "$main_path" pull --ff-only origin main; then
    echo "wt sync: main pull --ff-only failed (diverged?)"
    _wtsync_restore "$root" "$stashed"
    return 1
  fi

  echo "→ rebasing $branch onto origin/main"
  if ! "$_WT_GIT" -C "$root" rebase origin/main; then
    echo ""
    echo "wt sync: rebase has conflicts. Resolve, then:"
    echo "  git rebase --continue   (or --abort)"
    (( stashed )) && echo "Your stash is preserved: $stash_msg"
    (( stashed )) && echo "After rebase finishes: git stash pop"
    return 1
  fi

  if (( stashed )); then
    echo "→ restoring stash"
    if ! "$_WT_GIT" -C "$root" stash pop; then
      echo "wt sync: stash pop had conflicts — resolve in worktree."
      echo "  (recover anytime with: git stash list)"
      return 1
    fi
  fi

  echo "✓ $branch synced with origin/main"
}

# Internal (wt pr [commit-message]): rebase onto origin/main, push, and open a PR.
#   wt pr              push already-committed work, then open PR
#   wt pr "msg"        git add -A + commit "msg" + push + open PR
# Always rebases the branch onto origin/main first. If the rebase would
# conflict, aborts cleanly (no leftover rebase state, no conflict markers)
# and exits — resolve manually (e.g. wt sync) and re-run wt pr.
# If a PR already exists for the branch, opens it instead of creating a
# duplicate.
_wt_pr() {
  local root branch msg="$1"
  root=$("$_WT_GIT" rev-parse --show-toplevel 2>/dev/null) \
    || { echo "wt pr: not inside a git repo"; return 1; }
  branch=$("$_WT_GIT" -C "$root" symbolic-ref --short HEAD 2>/dev/null) \
    || { echo "wt pr: detached HEAD; bailing"; return 1; }
  [[ "$branch" == "main" || "$branch" == "master" ]] \
    && { echo "wt pr: refusing to open a PR from $branch"; return 1; }

  if [[ -n "$msg" ]]; then
    if [[ -z $("$_WT_GIT" -C "$root" status --porcelain) ]]; then
      echo "wt pr: nothing to commit"
      return 1
    fi
    echo "→ git add -A && git commit -m \"$msg\""
    "$_WT_GIT" -C "$root" add -A || return 1
    "$_WT_GIT" -C "$root" commit -m "$msg" || return 1
  elif [[ -n $("$_WT_GIT" -C "$root" status --porcelain) ]]; then
    echo "wt pr: uncommitted changes present — refusing to rebase. Commit, stash, or pass a commit message:"
    "$_WT_GIT" -C "$root" status --short
    return 1
  fi

  echo "→ fetching origin"
  "$_WT_GIT" -C "$root" fetch origin || { echo "wt pr: fetch failed"; return 1; }

  local pre_head post_head
  pre_head=$("$_WT_GIT" -C "$root" rev-parse HEAD)

  echo "→ rebasing $branch onto origin/main"
  if ! "$_WT_GIT" -C "$root" rebase origin/main; then
    echo "wt pr: rebase has conflicts — aborting cleanly. Resolve manually (e.g. wt sync), then re-run wt pr."
    "$_WT_GIT" -C "$root" rebase --abort 2>/dev/null
    return 1
  fi

  post_head=$("$_WT_GIT" -C "$root" rev-parse HEAD)

  echo "→ pushing $branch"
  if "$_WT_GIT" -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    if [[ "$pre_head" != "$post_head" ]]; then
      "$_WT_GIT" -C "$root" push --force-with-lease || return 1
    else
      "$_WT_GIT" -C "$root" push || return 1
    fi
  else
    "$_WT_GIT" -C "$root" push -u origin "$branch" || return 1
  fi

  local pr_url
  if pr_url=$(cd "$root" && gh pr view --json url -q .url 2>/dev/null) && [[ -n "$pr_url" ]]; then
    echo "→ PR already exists"
  else
    echo "→ creating PR"
    pr_url=$(cd "$root" && gh pr create --fill) || return 1
  fi
  echo "$pr_url"
}

# Internal: show usage (wt help)
_wt_help() {
  echo "wt — worktree interface (agent worktrees tagged ⚙)"
  echo ""
  printf "  %-26s %s\n" "wt"                       "picker over all worktrees, query prefilled to current repo"
  printf "  %-26s %s\n" ""                         "  enter: cd   ^o: VS Code   ^x: remove   ^y: copy path"
  printf "  %-26s %s\n" "wt new <branch> [base]"   "create worktree at ~/Worktrees/<repo>/<branch> + open in VS Code"
  printf "  %-26s %s\n" "wt rm"                    "picker → remove worktree (optionally delete branch)"
  printf "  %-26s %s\n" "wt sync"                  "rebase current worktree onto latest origin/main"
  printf "  %-26s %s\n" "wt pr [msg]"              "rebase on origin/main + push + create PR (aborts on rebase conflict)"
  printf "  %-26s %s\n" "wt open"                  "open VS Code at current worktree root"
  printf "  %-26s %s\n" "wt help"                  "show this help"
}
