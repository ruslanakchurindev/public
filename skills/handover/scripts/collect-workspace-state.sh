#!/usr/bin/env bash
set -euo pipefail

target="${1:-.}"
since="${2:-}"

section() {
  printf '\n## %s\n' "$1"
}

if [[ ! -d "$target" ]]; then
  printf 'error: target is not a directory: %s\n' "$target" >&2
  exit 2
fi

cd "$target"

section "Location"
printf 'path: %s\n' "$(pwd)"

if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]]; then
  section "Workspace"
  printf 'not a git worktree\n'
  section "Top-level entries"
  find . -maxdepth 2 -mindepth 1 -print | sed 's#^\./##' | sort | awk 'NR <= 200 { print }'
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

section "Git"
printf 'repo: %s\n' "$repo_root"
printf 'branch: %s\n' "$(git branch --show-current 2>/dev/null || true)"
printf 'head: %s %s\n' "$(git rev-parse --short HEAD 2>/dev/null || true)" "$(git log -1 --pretty=%s 2>/dev/null || true)"
printf 'generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [[ -n "$upstream" ]]; then
  printf 'upstream: %s\n' "$upstream"
  printf 'ahead/behind: %s\n' "$(git rev-list --left-right --count HEAD..."$upstream" 2>/dev/null | awk '{print "ahead "$1", behind "$2}' || true)"
fi

section "In-progress operations"
git_dir="$(git rev-parse --git-dir)"
ops=""
[[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]] && ops="${ops}rebase "
[[ -f "$git_dir/MERGE_HEAD" ]] && ops="${ops}merge "
[[ -f "$git_dir/CHERRY_PICK_HEAD" ]] && ops="${ops}cherry-pick "
[[ -f "$git_dir/REVERT_HEAD" ]] && ops="${ops}revert "
[[ -f "$git_dir/BISECT_LOG" ]] && ops="${ops}bisect "
printf '%s\n' "${ops:-none}"

section "Status"
git status --short

section "Changed files"
git diff --name-status

section "Staged files"
git diff --cached --name-status

section "Untracked files"
git ls-files --others --exclude-standard

section "Diff stats"
git diff --stat --find-renames

section "Staged diff stats"
git diff --cached --stat --find-renames

section "Stashes"
git stash list

section "Worktrees"
git worktree list

if [[ -n "$since" ]]; then
  section "Commits since $since"
  git log --oneline "$since..HEAD" 2>/dev/null || printf 'error: cannot resolve range %s..HEAD\n' "$since"
fi

section "Recent commits"
git log --oneline -5 2>/dev/null || printf 'none\n'

if command -v gh >/dev/null 2>&1; then
  section "Open PR for branch"
  gh pr view --json title,state,url -q '.title + " (" + .state + ") " + .url' 2>/dev/null || printf 'none\n'
fi
