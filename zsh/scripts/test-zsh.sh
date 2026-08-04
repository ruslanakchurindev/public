#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
zsh_dir="$(cd "$script_dir/.." && pwd)"
caffeinate_script="$zsh_dir/caffeinate.zsh"
worktrees_script="$zsh_dir/worktrees.zsh"

fail() {
  printf 'test failed: %s\n' "$*" >&2
  exit 1
}

mode_of() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

command -v zsh >/dev/null 2>&1 || fail "zsh is required"
[[ -f "$caffeinate_script" ]] || fail "caffeinate.zsh not found"
[[ -f "$worktrees_script" ]] || fail "worktrees.zsh not found"

zsh -n "$caffeinate_script"
zsh -n "$worktrees_script"

tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# caf/decaf validation and dispatch are tested without starting caffeinate.
CAF_SCRIPT="$caffeinate_script" TMPDIR="$tmp" zsh -f <<'ZSH'
source "$CAF_SCRIPT"

(( $+functions[caf] )) || exit 1
(( $+functions[decaf] )) || exit 1

if caf nope >/dev/null 2>&1; then
  print -u2 'caf accepted a non-numeric duration'
  exit 1
fi
if caf 0 >/dev/null 2>&1; then
  print -u2 'caf accepted a zero-hour duration'
  exit 1
fi
if caf 1 2 >/dev/null 2>&1; then
  print -u2 'caf accepted too many arguments'
  exit 1
fi
if decaf extra >/dev/null 2>&1; then
  print -u2 'decaf accepted an argument'
  exit 1
fi

_caf_stop() { print -r -- "stop:${1:-0}"; }
_caf_start() { print -r -- "start:$1:$2"; }
[[ "$(caf)" == $'stop:1\nstart::0' ]] || exit 1
[[ "$(caf 2)" == $'stop:1\nstart:2:2' ]] || exit 1

_caf_track 4242 || exit 1
[[ "$(<"$_CAF_PID_FILE")" == 4242 ]] || exit 1
ZSH

caf_pid_file="$tmp/caf-$(id -u)/pid"
caf_state_dir="$tmp/caf-$(id -u)"
[[ -f "$caf_pid_file" ]] || fail "caf did not create its PID file"
[[ "$(mode_of "$caf_pid_file")" == "600" ]] || fail "caf PID file is not private"
[[ "$(mode_of "$caf_state_dir")" == "700" ]] || fail "caf state directory is not private"

unsafe_tmp="$tmp/unsafe"
unsafe_target="$tmp/unsafe-target"
mkdir "$unsafe_tmp" "$unsafe_target"
ln -s "$unsafe_target" "$unsafe_tmp/caf-$(id -u)"
CAF_SCRIPT="$caffeinate_script" TMPDIR="$unsafe_tmp" zsh -f <<'ZSH'
source "$CAF_SCRIPT"
if _caf_track 4242 >/dev/null 2>&1; then
  print -u2 'caf accepted an unsafe state directory'
  exit 1
fi
ZSH
[[ ! -e "$unsafe_target/pid" ]] || fail "caf wrote through an unsafe state directory"

# Worktree discovery, lifecycle, sync, and publication use disposable local repos.
code_base="$tmp/Code"
worktree_base="$tmp/Worktrees"
repo="$code_base/demo repo"
origin="$tmp/origin.git"
upstream="$tmp/upstream"
fake_bin="$tmp/bin"
fake_git="$tmp/wt-git"
git_log="$tmp/wt-git.log"
gh_log="$tmp/gh.log"
mkdir -p "$repo" "$worktree_base"
GIT_CONFIG_GLOBAL=/dev/null git -C "$repo" init -q
GIT_CONFIG_GLOBAL=/dev/null git -C "$repo" symbolic-ref HEAD refs/heads/main
GIT_CONFIG_GLOBAL=/dev/null git -C "$repo" config user.name "Zsh Test"
GIT_CONFIG_GLOBAL=/dev/null git -C "$repo" config user.email "zsh-test@example.invalid"
printf 'fixture\n' > "$repo/file.txt"
printf 'base\n' > "$repo/conflict.txt"
GIT_CONFIG_GLOBAL=/dev/null git -C "$repo" add file.txt
GIT_CONFIG_GLOBAL=/dev/null git -C "$repo" add conflict.txt
GIT_CONFIG_GLOBAL=/dev/null git -C "$repo" commit -q -m "Initial fixture"
GIT_CONFIG_GLOBAL=/dev/null git init --bare -q "$origin"
GIT_CONFIG_GLOBAL=/dev/null git -C "$origin" symbolic-ref HEAD refs/heads/main
GIT_CONFIG_GLOBAL=/dev/null git -C "$repo" remote add origin "$origin"
GIT_CONFIG_GLOBAL=/dev/null git -C "$repo" push -q -u origin main
GIT_CONFIG_GLOBAL=/dev/null git clone -q "$origin" "$upstream"
GIT_CONFIG_GLOBAL=/dev/null git -C "$upstream" config user.name "Zsh Test"
GIT_CONFIG_GLOBAL=/dev/null git -C "$upstream" config user.email "zsh-test@example.invalid"

mkdir "$fake_bin"
real_git="$(command -v git)"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$*" >> "$WT_GIT_LOG"' 'exec "$REAL_GIT" "$@"' > "$fake_git"
printf '%s\n' '#!/usr/bin/env bash' 'printf "gh %s\\n" "$*" >> "$WT_GH_LOG"' 'if [[ "$1 $2" == "pr view" ]]; then' '  [[ "${GH_MODE:-create}" == view ]] && { printf "https://example.invalid/pr/1\\n"; exit 0; }' '  exit 1' 'fi' 'if [[ "$1 $2" == "pr create" ]]; then printf "https://example.invalid/pr/1\\n"; exit 0; fi' 'exit 1' > "$fake_bin/gh"
chmod +x "$fake_git" "$fake_bin/gh"

WT_SCRIPT="$worktrees_script" \
CODE_BASE="$code_base" \
WORKTREE_BASE="$worktree_base" \
REPO="$repo" \
UPSTREAM="$upstream" \
FAKE_GIT="$fake_git" \
REAL_GIT="$real_git" \
WT_GIT_LOG="$git_log" \
WT_GH_LOG="$gh_log" \
FAKE_BIN="$fake_bin" \
GIT_CONFIG_GLOBAL=/dev/null \
zsh -f <<'ZSH'
source "$WT_SCRIPT"

remote_main_commit() {
  print -r -- "$1" >> "$UPSTREAM/$2"
  "$REAL_GIT" -C "$UPSTREAM" add "$2" || return 1
  "$REAL_GIT" -C "$UPSTREAM" commit -q -m "$3" || return 1
  "$REAL_GIT" -C "$UPSTREAM" push -q origin main
}

[[ "$CODE_BASE" == "${REPO:h}" ]] || exit 1
[[ "$WORKTREE_BASE" == "${REPO:h:h}/Worktrees" ]] || exit 1
(( $+functions[wt] )) || exit 1

help="$(wt help)"
[[ "$help" == *'wt new <branch> [base]'* ]] || exit 1
[[ "$help" == *'wt sync'* ]] || exit 1
[[ "$help" == *'wt pr [msg]'* ]] || exit 1
if wt unknown >/dev/null 2>&1; then
  print -u2 'wt accepted an unknown subcommand'
  exit 1
fi

_wt_picker() { print picker; }
[[ "$(wt)" == picker ]] || exit 1

before="$(_wt_list_all)"
[[ "$before" == *"$REPO :: demo repo/main"* ]] || exit 1
[[ "$(_wt_main_path "$REPO")" == "$REPO" ]] || exit 1
[[ "$(_wt_branch_path "$REPO" main)" == "$REPO" ]] || exit 1

_wt_open() { :; }
cd "$REPO"
_wt_new feature HEAD >/dev/null || exit 1
linked="$WORKTREE_BASE/demo repo/feature"
[[ -f "$linked/.git" ]] || exit 1
after="$(_wt_list_all)"
[[ "$after" == *"$linked :: demo repo/feature"* ]] || exit 1
[[ "$(_wt_owner "$linked")" == "$REPO" ]] || exit 1

_wt_rm_path "$linked" <<<n >/dev/null || exit 1
[[ ! -e "$linked" ]] || exit 1
git show-ref --verify --quiet refs/heads/feature || exit 1

_wt_new feature-sync HEAD >/dev/null || exit 1
linked="$WORKTREE_BASE/demo repo/feature-sync"
[[ -f "$linked/.git" ]] || exit 1
cd "$linked"

# Sync handles a clean rebase, then preserves untracked work through a dirty sync.
remote_main_commit clean-sync remote-clean.txt 'Remote clean sync' || exit 1
_wt_sync >/dev/null || exit 1
git merge-base --is-ancestor origin/main HEAD || exit 1
print -r -- dirty-sync > dirty-sync.txt
remote_main_commit dirty-sync remote-dirty.txt 'Remote dirty sync' || exit 1
_wt_sync >/dev/null || exit 1
[[ "$(<dirty-sync.txt)" == dirty-sync ]] || exit 1
git add dirty-sync.txt && git commit -q -m 'Keep dirty sync work' || exit 1

# A conflicting publication must abort its temporary rebase and preserve HEAD.
print -r -- feature-conflict > conflict.txt
git add conflict.txt && git commit -q -m 'Feature conflict' || exit 1
remote_main_commit remote-conflict conflict.txt 'Remote conflict' || exit 1
pre_conflict=$(git rev-parse HEAD)
if _wt_pr >/dev/null 2>&1; then
  print -u2 'wt pr accepted a rebase conflict'
  exit 1
fi
[[ "$(git rev-parse HEAD)" == "$pre_conflict" ]] || exit 1
if git rebase --show-current-patch >/dev/null 2>&1; then
  print -u2 'wt pr left a rebase in progress'
  exit 1
fi

# Publish a new branch with a commit, then exercise the tracked force-with-lease path.
git reset --hard -q origin/main || exit 1
git clean -fdq || exit 1
print -r -- publish > publish.txt
_WT_GIT="$FAKE_GIT"
path=("$FAKE_BIN" $path)
export GH_MODE=create
: > "$WT_GIT_LOG"
: > "$WT_GH_LOG"
_wt_pr 'Publish fixture' >/dev/null || exit 1
[[ "$(git log -1 --format=%s)" == 'Publish fixture' ]] || exit 1
git ls-remote --exit-code origin refs/heads/feature-sync >/dev/null || exit 1
grep -F -- 'push -u origin feature-sync' "$WT_GIT_LOG" >/dev/null || exit 1
grep -F -- 'gh pr view --json url -q .url' "$WT_GH_LOG" >/dev/null || exit 1
grep -F -- 'gh pr create --fill' "$WT_GH_LOG" >/dev/null || exit 1

remote_main_commit tracked-advance remote-tracked.txt 'Remote tracked advance' || exit 1
export GH_MODE=view
: > "$WT_GIT_LOG"
: > "$WT_GH_LOG"
_wt_pr >/dev/null || exit 1
grep -F -- 'push --force-with-lease' "$WT_GIT_LOG" >/dev/null || exit 1
if grep -F -- 'push -u origin feature-sync' "$WT_GIT_LOG" >/dev/null; then
  print -u2 'tracked branch used the untracked push path'
  exit 1
fi
grep -F -- 'gh pr view --json url -q .url' "$WT_GH_LOG" >/dev/null || exit 1
if grep -F -- 'gh pr create --fill' "$WT_GH_LOG" >/dev/null; then
  print -u2 'existing PR used the create path'
  exit 1
fi

# A tracked branch that did not rebase takes Git's ordinary push path.
: > "$WT_GIT_LOG"
: > "$WT_GH_LOG"
_wt_pr >/dev/null || exit 1
grep -E -- ' push$' "$WT_GIT_LOG" >/dev/null || exit 1
if grep -E -- 'push (--force-with-lease|-u origin)' "$WT_GIT_LOG" >/dev/null; then
  print -u2 'unchanged tracked branch used a non-default push path'
  exit 1
fi
grep -F -- 'gh pr view --json url -q .url' "$WT_GH_LOG" >/dev/null || exit 1
ZSH

printf 'zsh customization tests passed\n'
