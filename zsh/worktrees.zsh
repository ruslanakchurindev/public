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

# Internal: name a repository from its own MAIN worktree path ($1), never from
# whichever directory a scan entered. Under $CODE_BASE the repo *is* the
# directory; under $WORKTREE_BASE the layout is <base>/<repo>/<branch>, so a
# clone rooted at ~/Worktrees/keyter-canary/integration is "keyter-canary".
# Answers in $REPLY: this is the picker's hot path, and $(...) forks per repo.
_wt_repo_label() {
  local main="$1" code="${CODE_BASE%/}" base="${WORKTREE_BASE%/}" rest
  case "$main" in
    "$code"/*) REPLY="${main:t}" ;;
    "$base"/*) rest="${main#"$base"/}"; REPLY="${rest%%/*}" ;;
    *)         REPLY="${main:t}" ;;
  esac
}

# Internal: format one repository's worktrees for the picker, given any one of
# its worktrees ($1). Prints the repo's MAIN worktree path on the first line,
# then one row per worktree; non-zero if $1 is not in a repository. Identity,
# label and rows all come from a SINGLE `worktree list` (the main worktree is its
# first entry) — asking git separately doubles the forks behind a picker open.
_wt_emit_worktrees() {
  local line wt_path head branch tag main label
  while IFS= read -r -d '' line; do
    case "$line" in
      'worktree '*)
        wt_path="${line#worktree }"
        if [[ -z "$main" ]]; then
          main="$wt_path"
          _wt_repo_label "$main"; label="$REPLY"
          print -r -- "$main"
        fi
        # Plain assignment, not $(...): this runs per worktree, not per repo.
        if [[ "$wt_path" == */.(claude|codex)/worktrees/* ]]; then tag=' ⚙'; else tag=''; fi
        ;;
      'HEAD '*) head="${line#HEAD }"; head="${head[1,7]}" ;;
      'branch refs/heads/'*)
        branch="${line#branch refs/heads/}"
        print -r -- "$wt_path :: $label/$branch$tag"
        ;;
      detached) print -r -- "$wt_path :: $label/(detached @ $head)$tag" ;;
    esac
  done < <("$_WT_GIT" -C "$1" worktree list --porcelain -z 2>/dev/null)
  [[ -n "$main" ]]
}

# Internal: list all worktrees across all repos under $WORKTREE_BASE and
# $CODE_BASE. Keyed by MAIN worktree path, not by the directory it was found in:
# ~/Worktrees/keyter and ~/Code/deriul-keyter are the same repo, and keying on
# the directory name emitted every worktree twice under two labels.
_wt_list_all() {
  local repo_dir gitdir anchor main
  local -a scan
  local -A seen

  # Take one repository's scan output (main path on line 1, rows after) and
  # print the rows only the first time that repository is seen.
  _wt_take() {
    scan=("${(@f)$(_wt_emit_worktrees "$1")}")
    main="$scan[1]"
    [[ -n "$main" && -z "${seen[$main]-}" ]] || return
    seen[$main]=1
    (( $#scan > 1 )) && print -rl -- "${(@)scan[2,-1]}"
  }

  {
    # Every .git under the base dir, not just the first: one base dir can hold
    # worktrees of several repos, and `find` returns directory order, so stopping
    # at the first hit silently drops the rest. Surplus hits are free — repos
    # already listed collapse on the identity check. -print0/read -d '' so a
    # newline in a pathname cannot split a row.
    for repo_dir in "$WORKTREE_BASE"/*(N/); do
      while IFS= read -r -d '' gitdir; do
        # Scan from the worktree we found, not from $main — the main worktree is
        # still listed after its directory is deleted (prunable).
        _wt_take "${gitdir:h}"
      done < <(find "$repo_dir" -name .git -maxdepth 4 -print0 2>/dev/null)
    done

    # Repos in $CODE_BASE not already reached above (typically no worktrees yet)
    for repo_dir in "$CODE_BASE"/*(N/); do
      [[ -d "$repo_dir/.git" || -f "$repo_dir/.git" ]] || continue
      _wt_take "$repo_dir"
    done
  } | sort -t'/' -k2
}

# Internal: for the repo that owns worktree $1, print its MAIN worktree path.
# Never cds into $1, so it works when $1's directory is already gone (prunable):
# scan the same bases as _wt_list_all and ask each repo whether it lists $1.
# Returns the *main* worktree, which outlives the removal of $1 — so a later
# `git -C` (branch -D) cannot land on a dir `worktree remove` just deleted.
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
  local out key selected wt_path repo_main rows
  local -a query
  # Repo name from the MAIN worktree, labelled exactly as _wt_list_all does, or
  # the prefilled query matches no row: inside a linked worktree the current
  # toplevel basename is the worktree's own directory name.
  repo_main=$(_wt_main_path "$PWD")
  [[ -n "$repo_main" ]] && { _wt_repo_label "$repo_main"; query=(--query "'$REPLY/"); }
  # Build the list BEFORE starting fzf; do NOT stream it in. _wt_list_all forks
  # ~35 short-lived processes, and while those compete with fzf for the CPU an
  # arriving escape sequence can be split across fzf's reads: fzf takes the lone
  # ESC as a bare Escape and types the rest ("[D") into the query. Buffering
  # costs ~0.3s before the picker paints and removes the race.
  rows=$(_wt_list_all)
  # A here-string turns "no rows" into one empty line, unlike a pipe — bail
  # rather than show a picker holding a single blank entry.
  [[ -z "$rows" ]] && { echo "wt: no worktrees found" >&2; return 1; }
  out=$(fzf "${query[@]}" \
    --prompt="worktree> " \
    --header="enter: cd   ^o: VS Code   ^x: remove   ^y: copy path" \
    --expect=ctrl-o,ctrl-x,ctrl-y \
    --delimiter=' :: ' \
    --preview='git -C {1} status --short --branch 2>/dev/null' \
    --preview-window=down,40% <<< "$rows")
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

  # _wt_owner returns the MAIN worktree. If that is what was picked, git refuses
  # ("is a main working tree") — bail with a clear message instead.
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

  # Drain anything already buffered from the picker before asking. A key mashed
  # while fzf was up must not silently answer a question about deleting a branch.
  local junk
  while read -t 0 -k 1 junk 2>/dev/null; do :; done

  # read -q (single keypress), not a bare `read`: zsh's `read` runs outside zle,
  # so arrow keys deposit raw escape bytes that backspace cannot erase. Anything
  # other than y/Y counts as no.
  local confirm
  if read -q "confirm?Delete branch too? [y/N] "; then confirm=y; else confirm=n; fi
  print ""   # read -q leaves the cursor on the prompt line

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
  local selected rows
  # Buffered before fzf starts, for the same reason as _wt_picker.
  rows=$(_wt_list_all)
  [[ -z "$rows" ]] && { echo "wt rm: no worktrees found" >&2; return 1; }
  selected=$(fzf --prompt="remove worktree> " <<< "$rows")
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

# Internal (wt sync): stash (incl. untracked) → fetch → ff local main in its own
# checkout → rebase onto origin/main → stash pop.
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

# Internal (wt pr [commit-message]): rebase onto origin/main, push, open a PR.
# With a message, `git add -A` + commit first. A conflicting rebase aborts
# cleanly (no leftover state, no markers) — resolve with wt sync and re-run. An
# existing PR is opened rather than duplicated.
_wt_pr() {
  local root branch msg="$1"
  root=$("$_WT_GIT" rev-parse --show-toplevel 2>/dev/null) \
    || { echo "wt pr: not inside a git repo"; return 1; }
  branch=$("$_WT_GIT" -C "$root" symbolic-ref --short HEAD 2>/dev/null) \
    || { echo "wt pr: detached HEAD; bailing"; return 1; }
  [[ "$branch" == "main" || "$branch" == "master" ]] \
    && { echo "wt pr: refusing to open a PR from $branch"; return 1; }

  # A bare `gh` runs as whichever account is globally active, so on a machine
  # holding several it opens the PR under the wrong identity — invisibly, until
  # someone reads the author. Define a `wt_gh_alias` function and every gh call
  # below becomes `gh <alias> ...`; leave it undefined and nothing changes.
  # Resolved here, before anything is committed, rebased or pushed, so a failure
  # costs nothing. No fallback: continuing as the active account is the mistake.
  local -a gh_acct
  if (( $+functions[wt_gh_alias] )); then
    local acct
    acct=$(wt_gh_alias "$root") || {
      echo "wt pr: wt_gh_alias failed for $root — refusing to run gh as the active account"
      return 1
    }
    if [[ ! "$acct" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ]]; then
      echo "wt pr: wt_gh_alias did not return a usable account alias — refusing to run gh as the active account"
      return 1
    fi
    gh_acct=("$acct")
  fi

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
  if pr_url=$(cd "$root" && gh "${gh_acct[@]}" pr view --json url -q .url 2>/dev/null) && [[ -n "$pr_url" ]]; then
    echo "→ PR already exists"
  else
    echo "→ creating PR"
    pr_url=$(cd "$root" && gh "${gh_acct[@]}" pr create --fill) || return 1
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
