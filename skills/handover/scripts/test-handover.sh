#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
handover="$script_dir/handover.sh"

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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
home="$tmp/handovers"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name "Handover Test"
git -C "$repo" config user.email "handover-test@example.invalid"
printf 'fixture\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m "Initial fixture"
repo_root="$(git -C "$repo" rev-parse --show-toplevel)"

expected_help="$(cat <<'EOF'
usage: handover.sh <command> [options]

Commands:
  path [target-dir]                  Print and create the repo handover store dir
  save [target-dir] [--name NAME]    Read markdown on stdin and save an artifact
  latest [target-dir] [--name NAME]  Print the latest artifact path
  list [target-dir] [--name NAME]    List artifact paths, newest first
  state [target-dir] [since-ref]     Print a workspace snapshot

target-dir defaults to ".". NAME must be 1-64 chars starting with a letter
or digit, then letters, digits, dots, underscores, or hyphens.
Names starting with "latest" are reserved.
EOF
)"
actual_help="$("$handover" --help)"
[[ "$actual_help" == "$expected_help" ]] || fail "help output changed"

store_dir="$(HANDOVER_HOME="$home" "$handover" path "$repo")"
[[ -d "$store_dir" ]] || fail "path did not create store dir"
[[ "$(mode_of "$home")" == "700" ]] || fail "store root is not private"
[[ "$(mode_of "$store_dir")" == "700" ]] || fail "repo store dir is not private"

artifact="$(printf '# Handover\n' | HANDOVER_HOME="$home" HANDOVER_REPO_NAME="billing-api" HANDOVER_WORKSPACE_NAME="billing-workspace" HANDOVER_MODEL_NAME="sonnet-test" "$handover" save "$repo")"
[[ -f "$artifact" ]] || fail "default artifact was not written"
[[ "$(mode_of "$artifact")" == "600" ]] || fail "artifact is not private"
[[ "$(HANDOVER_HOME="$home" "$handover" latest "$repo")" == "$artifact" ]] || fail "latest did not point at default artifact"
[[ "$(HANDOVER_HOME="$home" "$handover" list "$repo")" == "$artifact" ]] || fail "list did not return default artifact"
grep -q '^repo: billing-api$' "$artifact" || fail "artifact metadata missing repo"
grep -q '^workspace: billing-workspace$' "$artifact" || fail "artifact metadata missing workspace"
grep -q '^model: sonnet-test$' "$artifact" || fail "artifact metadata missing model"
grep -q '^name: default$' "$artifact" || fail "artifact metadata missing default name"

named_artifact="$(printf '# Named Handover\n' | HANDOVER_HOME="$home" "$handover" save "$repo" --name sprint-1)"
[[ -f "$named_artifact" ]] || fail "named artifact was not written"
[[ "$(HANDOVER_HOME="$home" "$handover" latest "$repo")" == "$artifact" ]] || fail "named save should not update default latest"
[[ "$(HANDOVER_HOME="$home" "$handover" latest "$repo" --name sprint-1)" == "$named_artifact" ]] || fail "named latest did not point at named artifact"
[[ "$(HANDOVER_HOME="$home" "$handover" list "$repo" --name sprint-1)" == "$named_artifact" ]] || fail "named list did not return named artifact"
grep -q '^name: sprint-1$' "$named_artifact" || fail "named artifact metadata missing name"

second_named_artifact="$(printf '# Named Handover 2\n' | HANDOVER_HOME="$home" "$handover" save "$repo" --name sprint-1)"
[[ -f "$second_named_artifact" ]] || fail "second named artifact was not written"
[[ "$second_named_artifact" != "$named_artifact" ]] || fail "second named artifact overwrote first named artifact"
[[ "$(HANDOVER_HOME="$home" "$handover" latest "$repo")" == "$artifact" ]] || fail "second named save should not update default latest"
[[ "$(HANDOVER_HOME="$home" "$handover" latest "$repo" --name sprint-1)" == "$second_named_artifact" ]] || fail "named latest did not update"
named_count="$(HANDOVER_HOME="$home" "$handover" list "$repo" --name sprint-1 | wc -l | tr -d ' ')"
[[ "$named_count" == "2" ]] || fail "named list did not include both named artifacts"

all_count="$(HANDOVER_HOME="$home" "$handover" list "$repo" | wc -l | tr -d ' ')"
[[ "$all_count" == "3" ]] || fail "all list did not include every artifact"

if printf '# Bad\n' | HANDOVER_HOME="$home" "$handover" save "$repo" --name '../bad' >/dev/null 2>&1; then
  fail "invalid names should be rejected"
fi

if printf '# Bad\n' | HANDOVER_HOME="$home" "$handover" save "$repo" --name 'latest' >/dev/null 2>&1; then
  fail "names starting with 'latest' should be rejected"
fi

if printf '# Bad\n' | HANDOVER_HOME="$home" "$handover" save "$repo" --name 'latest-foo' >/dev/null 2>&1; then
  fail "names starting with 'latest' should be rejected"
fi

sprint_artifact="$(printf '# Sprint\n' | HANDOVER_HOME="$home" "$handover" save "$repo" --name sprint)"
sprint2_artifact="$(printf '# Sprint2\n' | HANDOVER_HOME="$home" "$handover" save "$repo" --name sprint-2)"
sprint_list="$(HANDOVER_HOME="$home" "$handover" list "$repo" --name sprint)"
if printf '%s\n' "$sprint_list" | grep -qF "$sprint2_artifact"; then
  fail "listing --name sprint should not include sprint-2 artifacts"
fi
[[ "$(printf '%s\n' "$sprint_list" | wc -l | tr -d ' ')" == "1" ]] || fail "listing --name sprint should return exactly 1 artifact"
sprint2_list="$(HANDOVER_HOME="$home" "$handover" list "$repo" --name sprint-2)"
[[ "$(printf '%s\n' "$sprint2_list" | wc -l | tr -d ' ')" == "1" ]] || fail "listing --name sprint-2 should return exactly 1 artifact"

pr_artifact="$(printf '# PR\n' | HANDOVER_HOME="$home" "$handover" save "$repo" --name pr)"
pr2026_artifact="$(printf '# PR2026\n' | HANDOVER_HOME="$home" "$handover" save "$repo" --name pr-2026)"
[[ -f "$pr_artifact" && -f "$pr2026_artifact" ]] || fail "pr/pr-2026 artifacts were not written"
pr_list="$(HANDOVER_HOME="$home" "$handover" list "$repo" --name pr)"
if printf '%s\n' "$pr_list" | grep -qF "$pr2026_artifact"; then
  fail "listing --name pr must not include pr-2026 artifacts (4-digit suffix collision)"
fi
[[ "$(printf '%s\n' "$pr_list" | wc -l | tr -d ' ')" == "1" ]] || fail "listing --name pr should return exactly 1 artifact"

if printf '# Bad\n' | HANDOVER_HOME="$home" "$handover" save "$repo" --name= >/dev/null 2>&1; then
  fail "empty --name value should be rejected"
fi

empty_repo="$tmp/empty-repo"
mkdir -p "$empty_repo"
git -C "$empty_repo" init -q
git -C "$empty_repo" config user.name "Handover Test"
git -C "$empty_repo" config user.email "handover-test@example.invalid"
printf 'fixture\n' > "$empty_repo/file.txt"
git -C "$empty_repo" add file.txt
git -C "$empty_repo" commit -q -m "Initial fixture"
HANDOVER_HOME="$home" "$handover" path "$empty_repo" >/dev/null
empty_err="$(HANDOVER_HOME="$home" "$handover" list "$empty_repo" 2>&1 || true)"
case "$empty_err" in
  *"unbound variable"*) fail "list on an empty store dir crashed instead of clean error" ;;
esac
if HANDOVER_HOME="$home" "$handover" list "$empty_repo" >/dev/null 2>&1; then
  fail "list on an empty store dir should exit non-zero"
fi

bare_repo="$tmp/bare.git"
git init -q --bare "$bare_repo"
bare_state="$(HANDOVER_HOME="$home" "$handover" state "$bare_repo" 2>&1 || true)"
case "$bare_state" in
  *fatal*) fail "state on a bare repo should degrade, not emit a git fatal" ;;
esac

# Concurrent same-second saves must not clobber: the hardlink claim gives each its own -N name.
for i in 1 2 3 4 5; do
  printf '# concurrent %s\n' "$i" | HANDOVER_HOME="$home" "$handover" save "$repo" --name race >/dev/null &
done
wait
race_count="$(HANDOVER_HOME="$home" "$handover" list "$repo" --name race | wc -l | tr -d ' ')"
[[ "$race_count" == "5" ]] || fail "concurrent saves clobbered: expected 5 race artifacts, got $race_count"

since_ref="$(git -C "$repo" rev-parse HEAD~1 2>/dev/null || true)"
if [[ -n "$since_ref" ]]; then
  state_since="$(HANDOVER_HOME="$home" "$handover" state "$repo" "$since_ref")"
  [[ "$state_since" == *"## Commits since"* ]] || fail "state with since-ref missing commits section"
fi

state_output="$(HANDOVER_HOME="$home" "$handover" state "$repo")"
[[ "$state_output" == *"## Git"* ]] || fail "state output missing git section"
[[ "$state_output" == *"repo: $repo_root"* ]] || fail "state output missing repo path"

# --- Skill documentation contract -------------------------------------------
# The skill's whole point is preserving irrecoverable conversation state, not
# repo mechanics the next agent can re-derive. These checks lock that contract
# into SKILL.md/EXAMPLES.md so a later edit can't quietly regress the handover
# back to a repo-state-only artifact.
skill_root="$(cd "$script_dir/.." && pwd)"
skill_md="$skill_root/SKILL.md"
examples_md="$skill_root/EXAMPLES.md"
[[ -f "$skill_md" ]] || fail "SKILL.md not found at $skill_md"
[[ -f "$examples_md" ]] || fail "EXAMPLES.md not found at $examples_md"

grep -q '^## Conversation state that matters$' "$skill_md" \
  || fail "SKILL.md output format lost the 'Conversation state that matters' section"

# Irrecoverable conversation state must precede recoverable repo mechanics.
conv_line="$(grep -n '^## Conversation state that matters$' "$skill_md" | head -1 | cut -d: -f1)"
ws_line="$(grep -n '^## Workspace state$' "$skill_md" | head -1 | cut -d: -f1)"
[[ -n "$conv_line" && -n "$ws_line" ]] || fail "could not locate ordering anchors in SKILL.md"
[[ "$conv_line" -lt "$ws_line" ]] || fail "Conversation state must appear before Workspace state in SKILL.md"

grep -qi 'could not be reconstructed from Git' "$skill_md" \
  || fail "SKILL.md lost the pre-save sanity check (irrecoverable items go first)"

grep -qi 'what should I tell X' "$skill_md" \
  || fail "SKILL.md lost the reasoning-session capture trigger"

grep -q 'Conversation state that matters.*remain valid' "$skill_md" \
  || fail "resume drift guidance must list 'Conversation state that matters' as still-valid"

grep -q '^## Conversation state that matters$' "$examples_md" \
  || fail "EXAMPLES.md no longer demonstrates the conversation-state section"

printf 'handover script tests passed\n'
