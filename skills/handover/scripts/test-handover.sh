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

# Explicit template: BSD mktemp ignores $TMPDIR for the bare `mktemp -d` form,
# which strands the suite in sandboxes that only allow a specific temp root.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/handover-test.XXXXXX")"
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
# Bare latest means "the newest handover for this worktree", named or not: a
# resuming session does not know which name a past session happened to use, and
# a stale unnamed pointer is the whole bug this contract closes.
[[ "$(HANDOVER_HOME="$home" "$handover" latest "$repo")" == "$named_artifact" ]] || fail "bare latest must return the newest artifact, including named ones"
[[ "$(HANDOVER_HOME="$home" "$handover" latest "$repo" | head -1)" == "$(HANDOVER_HOME="$home" "$handover" list "$repo" | head -1)" ]] || fail "latest and list disagree about the newest artifact"
[[ "$(readlink "$store_dir/latest.md")" == "$(basename "$artifact")" ]] || fail "unnamed latest symlink should still track unnamed saves"
[[ "$(HANDOVER_HOME="$home" "$handover" latest "$repo" --name sprint-1)" == "$named_artifact" ]] || fail "named latest did not point at named artifact"
[[ "$(HANDOVER_HOME="$home" "$handover" list "$repo" --name sprint-1)" == "$named_artifact" ]] || fail "named list did not return named artifact"
grep -q '^name: sprint-1$' "$named_artifact" || fail "named artifact metadata missing name"

second_named_artifact="$(printf '# Named Handover 2\n' | HANDOVER_HOME="$home" "$handover" save "$repo" --name sprint-1)"
[[ -f "$second_named_artifact" ]] || fail "second named artifact was not written"
[[ "$second_named_artifact" != "$named_artifact" ]] || fail "second named artifact overwrote first named artifact"
[[ "$(HANDOVER_HOME="$home" "$handover" latest "$repo")" == "$second_named_artifact" ]] || fail "bare latest did not follow the newest named save"
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

# Linked worktrees of one repo must share a single store: a handover saved in a
# worktree is found by latest/list run from the main checkout, and vice versa.
# Keying off the worktree path (the old bug) scattered them into separate stores.
wt_home="$tmp/wt-handovers"
wt_main="$tmp/wt-main"
mkdir -p "$wt_main"
git -C "$wt_main" init -q
git -C "$wt_main" config user.name "Handover Test"
git -C "$wt_main" config user.email "handover-test@example.invalid"
printf 'fixture\n' > "$wt_main/file.txt"
git -C "$wt_main" add file.txt
git -C "$wt_main" commit -q -m "Initial fixture"
wt_linked="$tmp/wt-linked"
git -C "$wt_main" worktree add -q "$wt_linked" -b feature

main_store="$(HANDOVER_HOME="$wt_home" "$handover" path "$wt_main")"
linked_store="$(HANDOVER_HOME="$wt_home" "$handover" path "$wt_linked")"
[[ "$main_store" == "$linked_store" ]] || fail "worktree and main checkout resolved to different stores: $main_store vs $linked_store"

wt_artifact="$(printf '# From worktree\n' | HANDOVER_HOME="$wt_home" "$handover" save "$wt_linked")"
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_main" 2>/dev/null)" == "$wt_artifact" ]] || fail "handover saved in linked worktree not found from main checkout"
grep -q "^workspace-path: $wt_linked$" "$wt_artifact" || fail "artifact metadata missing originating worktree path"
grep -q "^worktree: $wt_linked$" "$wt_artifact" || fail "artifact metadata missing worktree field"

# A worktree with no handover of its own falls back to the repo's newest, but
# says so: branch, HEAD, and uncommitted work are per-worktree, so the next
# agent must know the artifact came from somewhere else.
fallback_note="$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_main" 2>&1 >/dev/null)"
[[ "$fallback_note" == *"no handover from this worktree"* ]] || fail "cross-worktree fallback did not warn: $fallback_note"
[[ "$fallback_note" == *"$wt_linked"* ]] || fail "fallback note did not name the originating worktree: $fallback_note"
[[ "$fallback_note" == *"still present"* ]] || fail "fallback note did not report the worktree as present: $fallback_note"

# Each worktree now resolves to its own newest, and the preference beats
# recency: main's artifact is older than the one saved in the linked worktree
# below, yet each side keeps its own.
main_artifact="$(printf '# From main\n' | HANDOVER_HOME="$wt_home" "$handover" save "$wt_main")"
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_main")" == "$main_artifact" ]] || fail "main checkout did not resolve to its own handover"
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_linked")" == "$wt_artifact" ]] || fail "linked worktree did not resolve to its own handover"
[[ -z "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_main" 2>&1 >/dev/null)" ]] || fail "resolving to this worktree's own handover must not warn"

newer_wt_artifact="$(printf '# Newer from worktree\n' | HANDOVER_HOME="$wt_home" "$handover" save "$wt_linked")"
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_main")" == "$main_artifact" ]] || fail "a newer handover from another worktree must not win over this worktree's own"
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_linked")" == "$newer_wt_artifact" ]] || fail "linked worktree did not follow its own newest handover"

wt_all_count="$(HANDOVER_HOME="$wt_home" "$handover" list "$wt_linked" | wc -l | tr -d ' ')"
[[ "$wt_all_count" == "3" ]] || fail "shared worktree store should list every artifact, got $wt_all_count"

# A save from a subdirectory still belongs to its worktree: workspace-path
# records the subdir, so matching has to use the worktree field.
mkdir -p "$wt_linked/nested/deeper"
sub_artifact="$(printf '# From a subdir\n' | HANDOVER_HOME="$wt_home" "$handover" save "$wt_linked/nested/deeper")"
grep -q "^worktree: $wt_linked$" "$sub_artifact" || fail "subdir save did not record the worktree root"
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_linked")" == "$sub_artifact" ]] || fail "subdir save not attributed to its worktree"
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_main")" == "$main_artifact" ]] || fail "subdir save leaked into a sibling worktree"

# Artifacts written before the worktree field existed must still be attributed,
# via their workspace-path.
wt_store="$(HANDOVER_HOME="$wt_home" "$handover" path "$wt_main")"
legacy_artifact="$wt_store/2020-01-01T000000Z.md"
cat > "$legacy_artifact" <<EOF
<!-- handover-metadata
generated: 2020-01-01T00:00:00Z
repo: wt-main
workspace: wt-main
workspace-path: $wt_main
model: legacy
name: default
-->

# Legacy
EOF
legacy_only="$tmp/legacy-only"
git -C "$wt_main" worktree add -q "$legacy_only" -b legacy-only
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_main")" == "$main_artifact" ]] || fail "legacy artifact should not outrank a newer one from the same worktree"
git -C "$wt_main" worktree remove --force "$legacy_only"

# A worktree nested inside the main checkout (the .worktrees/* layout) must not
# have its handovers claimed by the parent, and vice versa.
nested="$wt_main/.worktrees/nested"
git -C "$wt_main" worktree add -q "$nested" -b nested
nested_artifact="$(printf '# From a nested worktree\n' | HANDOVER_HOME="$wt_home" "$handover" save "$nested")"
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$nested")" == "$nested_artifact" ]] || fail "nested worktree did not resolve to its own handover"
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_main")" == "$main_artifact" ]] || fail "parent checkout claimed a nested worktree's handover"
# Same check for a pre-worktree-field artifact, where attribution has to be
# recovered from workspace-path.
nested_legacy="$wt_store/2020-01-02T000000Z.md"
cat > "$nested_legacy" <<EOF
<!-- handover-metadata
generated: 2020-01-02T00:00:00Z
repo: wt-main
workspace: nested
workspace-path: $nested
model: legacy
name: default
-->

# Legacy nested
EOF
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_main")" == "$main_artifact" ]] || fail "parent checkout claimed a nested worktree's legacy handover"
git -C "$wt_main" worktree remove --force "$nested"
rm -f "$nested_legacy"

# A worktree that no longer exists: its handover is still the repo's newest and
# still resolvable, but the fallback note has to say the directory is gone.
wt_gone="$tmp/wt-gone"
git -C "$wt_main" worktree add -q "$wt_gone" -b gone
gone_artifact="$(printf '# From a doomed worktree\n' | HANDOVER_HOME="$wt_home" "$handover" save "$wt_gone")"
git -C "$wt_main" worktree remove --force "$wt_gone"
[[ ! -d "$wt_gone" ]] || fail "fixture worktree was not removed"
wt_fresh="$tmp/wt-fresh"
git -C "$wt_main" worktree add -q "$wt_fresh" -b fresh
[[ "$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_fresh" 2>/dev/null)" == "$gone_artifact" ]] || fail "a handover from a deleted worktree must still be resolvable"
gone_note="$(HANDOVER_HOME="$wt_home" "$handover" latest "$wt_fresh" 2>&1 >/dev/null)"
[[ "$gone_note" == *"no longer present"* ]] || fail "fallback note did not report the deleted worktree: $gone_note"

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

grep -qi 'reconstructible from Git' "$skill_md" \
  || fail "SKILL.md lost the pre-save sanity check (irrecoverable items go first)"

grep -qi 'what should I tell X' "$skill_md" \
  || fail "SKILL.md lost the reasoning-session capture trigger"

grep -q 'Conversation state that matters.*remain valid' "$skill_md" \
  || fail "resume drift guidance must list 'Conversation state that matters' as still-valid"

# Resume has to state which worktree it resolved from; a silent cross-worktree
# pickup hands the next agent the wrong branch and dirty tree.
grep -qi 'current worktree' "$skill_md" \
  || fail "SKILL.md lost the worktree-preference rule for latest"
grep -qi 'warns on stderr' "$skill_md" \
  || fail "SKILL.md resume guidance must surface the cross-worktree fallback warning"

grep -q '^## Conversation state that matters$' "$examples_md" \
  || fail "EXAMPLES.md no longer demonstrates the conversation-state section"

printf 'handover script tests passed\n'
