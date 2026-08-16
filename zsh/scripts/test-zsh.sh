#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
zsh_dir="$(cd "$script_dir/.." && pwd)"
caffeinate_script="$zsh_dir/caffeinate.zsh"
gpull_script="$zsh_dir/gpull.zsh"
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
[[ -f "$gpull_script" ]] || fail "gpull.zsh not found"
[[ -f "$worktrees_script" ]] || fail "worktrees.zsh not found"

zsh -n "$caffeinate_script"
zsh -n "$gpull_script"
zsh -n "$worktrees_script"

# Explicit template: BSD mktemp ignores $TMPDIR for the bare `mktemp -d` form,
# which strands the suite in sandboxes that only allow a specific temp root.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/zsh-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
cleanup() {
  if [[ -n "${gpull_unreadable_base:-}" && -d "$gpull_unreadable_base" ]]; then
    chmod 700 "$gpull_unreadable_base" 2>/dev/null || :
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

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

# gpull validates configuration, caps its own workers, and ignores unrelated jobs.
gpull_fake_base="$tmp/gpull-fake"
gpull_empty_base="$tmp/gpull-empty"
gpull_missing_base="$tmp/gpull-missing"
gpull_unreadable_base="$tmp/gpull-unreadable"
gpull_events="$tmp/gpull-events.log"
mkdir -p "$gpull_empty_base" "$gpull_unreadable_base"
chmod 000 "$gpull_unreadable_base"
for name in alpha beta delta epsilon gamma zeta; do
  mkdir -p "$gpull_fake_base/$name/.git"
done

GPULL_SCRIPT="$gpull_script" \
GPULL_FAKE_BASE="$gpull_fake_base" \
GPULL_EMPTY_BASE="$gpull_empty_base" \
GPULL_MISSING_BASE="$gpull_missing_base" \
GPULL_UNREADABLE_BASE="$gpull_unreadable_base" \
GPULL_EVENTS="$gpull_events" \
zsh -f <<'ZSH'
typeset -g _GPULL_CODE_BASE="$GPULL_EMPTY_BASE"
source "$GPULL_SCRIPT"

(( $+functions[gpull] )) || exit 1
[[ "$(_GPULL_JOBS=2 gpull)" == "no repos under $GPULL_EMPTY_BASE" ]] || exit 1
[[ "$(_GPULL_JOBS=1000000 gpull)" == "no repos under $GPULL_EMPTY_BASE" ]] || {
  print -u2 'gpull rejected a valid large worker count'
  exit 1
}
for invalid_base in "$GPULL_MISSING_BASE" "$GPULL_UNREADABLE_BASE"; do
  invalid_output=$(_GPULL_CODE_BASE="$invalid_base" gpull 2>&1)
  invalid_rc=$?
  [[ $invalid_rc == 2 ]] || {
    print -u2 "gpull accepted an unreadable code root: $invalid_base"
    exit 1
  }
  [[ "$invalid_output" == *'gpull: _GPULL_CODE_BASE is not a readable directory:'* ]] || {
    print -u2 "gpull did not report the invalid code root: $invalid_output"
    exit 1
  }
done
if _GPULL_JOBS=0 gpull >/dev/null 2>&1; then
  print -u2 'gpull accepted zero workers'
  exit 1
fi
if _GPULL_JOBS=lots gpull >/dev/null 2>&1; then
  print -u2 'gpull accepted a non-numeric worker count'
  exit 1
fi

_GPULL_CODE_BASE="$GPULL_FAKE_BASE"
_GPULL_JOBS=2
_gpull_one() {
  print -r -- "start:${1:t}" >> "$GPULL_EVENTS"
  if [[ "${1:t}" == alpha ]]; then
    sleep 0.35
  else
    sleep 0.05
  fi
  print -r -- "end:${1:t}" >> "$GPULL_EVENTS"
  print -r -- "→ ${1:t}"
  print -r -- '    up to date'
}

unsetopt bg_nice
sleep 2 &
unrelated=$!
setopt bg_nice
output=$(gpull) || exit 1
kill -0 "$unrelated" 2>/dev/null || {
  print -u2 'gpull waited for an unrelated background job'
  exit 1
}
kill "$unrelated" 2>/dev/null || :
wait "$unrelated" 2>/dev/null || :

[[ "$output" == *$'6 ok  0 skipped  0 failed  (jobs=2)'* ]] || exit 1
repo_headers=$(print -r -- "$output" | sed -n '/^→ /p')
[[ "$repo_headers" == $'→ alpha\n→ beta\n→ delta\n→ epsilon\n→ gamma\n→ zeta' ]] || {
  print -u2 'gpull did not print repositories in directory order'
  exit 1
}
ZSH
chmod 700 "$gpull_unreadable_base"

event_stats=$(awk -F: '
  $1 == "start" { active++; starts++; if (active > max) max = active }
  $1 == "end" { active--; ends++ }
  END { printf "%d %d %d %d", starts, ends, max, active }
' "$gpull_events")
[[ "$event_stats" == "6 6 2 0" ]] || fail "gpull worker cap was not respected: $event_stats"
if ! awk '
  $0 == "start:delta" { delta_start = NR }
  $0 == "end:alpha" { alpha_end = NR }
  END { exit !(delta_start && alpha_end && delta_start < alpha_end) }
' "$gpull_events"; then
  fail "gpull left a worker slot idle behind the oldest repository"
fi

# Discovery is explicit about hidden directories and follows symlinks to direct
# repository directories, independent of the caller's GLOB_DOTS option.
gpull_discovery_base="$tmp/gpull-discovery"
gpull_symlink_target="$tmp/gpull-symlink-target"
mkdir -p "$gpull_discovery_base/.hidden/.git" "$gpull_symlink_target/.git"
ln -s "$gpull_symlink_target" "$gpull_discovery_base/linked"
discovery_output=$(
  GPULL_SCRIPT="$gpull_script" \
  GPULL_DISCOVERY_BASE="$gpull_discovery_base" \
  zsh -f <<'ZSH'
typeset -g _GPULL_CODE_BASE="$GPULL_DISCOVERY_BASE"
typeset -g _GPULL_JOBS=2
source "$GPULL_SCRIPT"
unsetopt glob_dots
_gpull_one() {
  print -r -- "→ ${1:t}"
  print -r -- '    up to date'
}
gpull
ZSH
)
discovery_headers=$(printf '%s\n' "$discovery_output" | sed -n '/^→ /p')
[[ "$discovery_headers" == $'→ .hidden\n→ linked' ]] ||
  fail "gpull omitted hidden or symlinked repositories: $discovery_output"

# Operational Git probe errors stay distinct from semantic absence, detached
# HEAD, and divergence.
GPULL_SCRIPT="$gpull_script" zsh -f <<'ZSH'
source "$GPULL_SCRIPT"

fake_git() {
  case "$3" in
    fetch)
      return 0
      ;;
    rev-parse)
      local ref="${@[-1]}"
      if [[ "$ref" == refs/heads/main ]]; then
        case "$_GPULL_FAKE_MODE" in
          local-error) return 128 ;;
          no-main) return 1 ;;
          *) print -r -- local; return 0 ;;
        esac
      fi
      [[ "$_GPULL_FAKE_MODE" == ancestry-error ]] && print -r -- remote || print -r -- local
      return 0
      ;;
    symbolic-ref)
      [[ "$_GPULL_FAKE_MODE" == head-error ]] && return 128
      print -r -- topic
      return 0
      ;;
    merge-base)
      if [[ "$_GPULL_FAKE_MODE" == ancestry-error ]]; then
        [[ "$5" == local ]] && return 1
        return 128
      fi
      return 0
      ;;
  esac
  return 128
}

typeset -g _GPULL_GIT=fake_git
check_probe() {
  local mode="$1" expected_rc="$2" expected_text="$3"
  local output rc
  _GPULL_FAKE_MODE="$mode"
  output=$(_gpull_one /tmp/example)
  rc=$?
  [[ $rc == $expected_rc && "$output" == *"$expected_text"* ]] || {
    print -u2 "gpull misclassified $mode (rc=$rc): $output"
    exit 1
  }
}

check_probe no-main 1 'no local main — skipped'
check_probe local-error 2 'could not inspect local main — failed'
check_probe head-error 2 'could not inspect HEAD — failed'
check_probe ancestry-error 2 'could not compare main with origin/main — failed'
ZSH

# A caller's ERR_EXIT option must not prevent safe-skip status artifacts from
# being written by background workers.
gpull_err_exit_base="$tmp/gpull-err-exit"
mkdir -p "$gpull_err_exit_base/skipped/.git"
set +e
err_exit_output=$(
  GPULL_SCRIPT="$gpull_script" \
  GPULL_ERR_EXIT_BASE="$gpull_err_exit_base" \
  zsh -f <<'ZSH' 2>&1
typeset -g _GPULL_CODE_BASE="$GPULL_ERR_EXIT_BASE"
typeset -g _GPULL_JOBS=1
source "$GPULL_SCRIPT"
_gpull_one() {
  print -r -- "→ ${1:t}"
  print -r -- '    no local main — skipped'
  return 1
}
setopt err_exit
gpull
ZSH
)
err_exit_rc=$?
set -e
(( err_exit_rc == 0 )) || fail "ERR_EXIT changed a safe skip into failure: $err_exit_output"
[[ "$err_exit_output" == *'0 ok  1 skipped  0 failed  (jobs=1)'* ]] ||
  fail "ERR_EXIT lost the worker result: $err_exit_output"

# Missing or unreadable worker artifacts always count as operational failures.
gpull_artifact_base="$tmp/gpull-artifact-base"
gpull_bad_artifacts="$tmp/gpull-bad-artifacts"
mkdir -p "$gpull_artifact_base/repo/.git" "$gpull_bad_artifacts/0000.out"
set +e
artifact_output=$(
  GPULL_SCRIPT="$gpull_script" \
  GPULL_ARTIFACT_BASE="$gpull_artifact_base" \
  GPULL_BAD_ARTIFACTS="$gpull_bad_artifacts" \
  zsh -f <<'ZSH' 2>&1
typeset -g _GPULL_CODE_BASE="$GPULL_ARTIFACT_BASE"
typeset -g _GPULL_JOBS=1
source "$GPULL_SCRIPT"
mktemp() { print -r -- "$GPULL_BAD_ARTIFACTS"; }
_gpull_one() { return 1; }
gpull
ZSH
)
artifact_rc=$?
set -e
(( artifact_rc != 0 )) || fail "gpull treated a missing output artifact as a safe skip"
[[ "$artifact_output" == *'0 ok  0 skipped  1 failed  (jobs=1)'* ]] ||
  fail "gpull did not fail closed for a missing output artifact: $artifact_output"

# Scoped cleanup runs even when an inherited ERR_EXIT aborts the scheduler.
gpull_cleanup_base="$tmp/gpull-cleanup-base"
gpull_cleanup_tmp="$tmp/gpull-cleanup-tmp"
mkdir -p "$gpull_cleanup_base/alpha/.git" "$gpull_cleanup_base/beta/.git" "$gpull_cleanup_tmp"
set +e
GPULL_SCRIPT="$gpull_script" \
GPULL_CLEANUP_BASE="$gpull_cleanup_base" \
GPULL_CLEANUP_TMP="$gpull_cleanup_tmp" \
zsh -f <<'ZSH' >/dev/null 2>&1
typeset -g _GPULL_CODE_BASE="$GPULL_CLEANUP_BASE"
typeset -g _GPULL_JOBS=1
source "$GPULL_SCRIPT"
mktemp() { print -r -- "$GPULL_CLEANUP_TMP"; }
sleep() { return 1; }
_gpull_one() {
  command sleep 0.2
  print -r -- "→ ${1:t}"
}
setopt err_exit
gpull
ZSH
cleanup_rc=$?
set -e
(( cleanup_rc != 0 )) || fail "gpull cleanup fixture did not trigger its early exit"
[[ ! -e "$gpull_cleanup_tmp" ]] || fail "gpull left its temporary directory after early exit"

# Full gpull behavior uses disposable local remotes: two updates, three safe
# skips, and one operational failure that must make the aggregate command fail.
gpull_code_base="$tmp/GpullCode"
gpull_origin="$tmp/gpull-origin.git"
gpull_seed="$tmp/gpull-seed"
mkdir -p "$gpull_code_base" "$gpull_seed"
GIT_CONFIG_GLOBAL=/dev/null git init --bare -q "$gpull_origin"
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_origin" symbolic-ref HEAD refs/heads/main
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" init -q
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" symbolic-ref HEAD refs/heads/main
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" config user.name "Zsh Test"
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" config user.email "zsh-test@example.invalid"
printf 'base\n' > "$gpull_seed/file.txt"
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" add file.txt
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" commit -q -m "Initial gpull fixture"
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" remote add origin "$gpull_origin"
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" push -q -u origin main

for name in clean-main dirty-main diverged no-main other-branch; do
  GIT_CONFIG_GLOBAL=/dev/null git clone -q "$gpull_origin" "$gpull_code_base/$name"
  GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/$name" config user.name "Zsh Test"
  GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/$name" config user.email "zsh-test@example.invalid"
done

old_main=$(GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/clean-main" rev-parse main)
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/other-branch" checkout -q -b topic
printf 'dirty\n' > "$gpull_code_base/dirty-main/untracked.txt"
printf 'local\n' > "$gpull_code_base/diverged/local.txt"
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/diverged" add local.txt
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/diverged" commit -q -m "Local divergence"
diverged_main=$(GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/diverged" rev-parse main)
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/no-main" branch -m trunk

broken_repo="$gpull_code_base/broken-origin"
mkdir -p "$broken_repo"
GIT_CONFIG_GLOBAL=/dev/null git -C "$broken_repo" init -q
GIT_CONFIG_GLOBAL=/dev/null git -C "$broken_repo" symbolic-ref HEAD refs/heads/main
GIT_CONFIG_GLOBAL=/dev/null git -C "$broken_repo" config user.name "Zsh Test"
GIT_CONFIG_GLOBAL=/dev/null git -C "$broken_repo" config user.email "zsh-test@example.invalid"
printf 'broken\n' > "$broken_repo/file.txt"
GIT_CONFIG_GLOBAL=/dev/null git -C "$broken_repo" add file.txt
GIT_CONFIG_GLOBAL=/dev/null git -C "$broken_repo" commit -q -m "Broken origin fixture"
GIT_CONFIG_GLOBAL=/dev/null git -C "$broken_repo" remote add origin "$tmp/missing-origin.git"

printf 'remote\n' > "$gpull_seed/remote.txt"
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" add remote.txt
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" commit -q -m "Remote gpull update"
GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" push -q origin main
remote_main=$(GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_seed" rev-parse main)

set +e
gpull_output=$(
  GPULL_SCRIPT="$gpull_script" \
  GPULL_CODE_BASE="$gpull_code_base" \
  GIT_CONFIG_GLOBAL=/dev/null \
  zsh -f <<'ZSH' 2>&1
typeset -g _GPULL_CODE_BASE="$GPULL_CODE_BASE"
typeset -g _GPULL_JOBS=3
source "$GPULL_SCRIPT"
gpull
ZSH
)
gpull_rc=$?
set -e

(( gpull_rc != 0 )) || fail "gpull hid an operational failure"
[[ "$gpull_output" == *'2 ok  3 skipped  1 failed  (jobs=3)'* ]] ||
  fail "unexpected gpull summary: $gpull_output"
[[ "$gpull_output" == *'dirty main — skipped'* ]] || fail "gpull did not report a dirty main"
[[ "$gpull_output" == *'local main diverged from origin/main — skipped'* ]] ||
  fail "gpull did not report divergence"
[[ "$gpull_output" == *'fetch failed'* ]] || fail "gpull did not report a fetch failure"

[[ "$(GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/clean-main" rev-parse main)" == "$remote_main" ]] ||
  fail "gpull did not fast-forward checked-out main"
[[ "$(GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/other-branch" rev-parse main)" == "$remote_main" ]] ||
  fail "gpull did not update main from another branch"
[[ "$(GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/other-branch" branch --show-current)" == topic ]] ||
  fail "gpull switched the current branch"
[[ "$(GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/dirty-main" rev-parse main)" == "$old_main" ]] ||
  fail "gpull advanced a dirty checked-out main"
[[ "$(GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/diverged" rev-parse main)" == "$diverged_main" ]] ||
  fail "gpull rewrote a diverged main"
if GIT_CONFIG_GLOBAL=/dev/null git -C "$gpull_code_base/no-main" show-ref --verify --quiet refs/heads/main; then
  fail "gpull created a missing local main"
fi

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
printf '%s\n' '#!/usr/bin/env bash' 'printf "gh %s\\n" "$*" >> "$WT_GH_LOG"' 'if [[ "$1" != pr ]]; then shift; fi' 'if [[ "$1 $2" == "pr view" ]]; then''  [[ "${GH_MODE:-create}" == view ]] && { printf "https://example.invalid/pr/1\\n"; exit 0; }' '  exit 1' 'fi' 'if [[ "$1 $2" == "pr create" ]]; then printf "https://example.invalid/pr/1\\n"; exit 0; fi' 'exit 1' > "$fake_bin/gh"
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

# An account hook, once the user defines one, has to name the account on every gh
# call. A bare `gh` runs as whichever account is globally active — that is how a
# personal pull request ends up authored by a work account.
wt_gh_alias() { print -r -- fixture-acct; }

export GH_MODE=view
: > "$WT_GH_LOG"
_wt_pr >/dev/null || exit 1
grep -F -- 'gh fixture-acct pr view --json url -q .url' "$WT_GH_LOG" >/dev/null || exit 1
if grep -E -- '^gh pr ' "$WT_GH_LOG" >/dev/null; then
  print -u2 'wt pr looked up the PR through a bare gh despite wt_gh_alias'
  exit 1
fi

# The create path is the one that writes, so it matters most.
export GH_MODE=create
: > "$WT_GH_LOG"
_wt_pr >/dev/null || exit 1
grep -F -- 'gh fixture-acct pr create --fill' "$WT_GH_LOG" >/dev/null || exit 1
if grep -E -- '^gh pr ' "$WT_GH_LOG" >/dev/null; then
  print -u2 'wt pr created the PR through a bare gh despite wt_gh_alias'
  exit 1
fi

# A hook that cannot answer stops wt pr before it touches the repo or GitHub;
# continuing as the active account is the write this path exists to prevent.
wt_gh_alias() { print -r -- 'not an alias'; }
: > "$WT_GH_LOG"
: > "$WT_GIT_LOG"
if _wt_pr >/dev/null 2>&1; then
  print -u2 'wt pr accepted an invalid account alias'
  exit 1
fi
[[ ! -s "$WT_GH_LOG" ]] || exit 1
if grep -E -- ' push' "$WT_GIT_LOG" >/dev/null; then
  print -u2 'wt pr pushed before discovering it had no usable account'
  exit 1
fi

wt_gh_alias() { return 1; }
: > "$WT_GH_LOG"
if _wt_pr >/dev/null 2>&1; then
  print -u2 'wt pr continued after wt_gh_alias failed'
  exit 1
fi
[[ ! -s "$WT_GH_LOG" ]] || exit 1

# With no hook defined — the default, and every machine holding one GitHub
# account — the calls stay bare and unchanged.
unfunction wt_gh_alias
export GH_MODE=view
: > "$WT_GH_LOG"
_wt_pr >/dev/null || exit 1
grep -F -- 'gh pr view --json url -q .url' "$WT_GH_LOG" >/dev/null || exit 1
ZSH

printf 'zsh customization tests passed\n'
