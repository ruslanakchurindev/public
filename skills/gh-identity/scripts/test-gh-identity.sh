#!/usr/bin/env bash
# Hermetic tests for gh-identity-guard.sh.
#
# Builds throwaway git repos with known remotes and a throwaway identity table
# (GH_IDENTITY_TABLE), so nothing here touches the real GitHub CLI config, the
# real repositories, or the network. Run:
#   bash skills/gh-identity/scripts/test-gh-identity.sh
#
# bash 3.2 compatible (macOS default).

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
GUARD="$script_dir/gh-identity-guard.sh"
TEMPLATE="$skill_dir/templates/identities.tsv"

# Bare `mktemp -d` on macOS ignores TMPDIR and uses the Darwin per-user temp
# dir; honour TMPDIR and refuse to run without a real workspace rather than
# silently operating on the filesystem root.
WS="$(mktemp -d "${TMPDIR:-/tmp}/gh-identity-test.XXXXXX")" || exit 1
[ -n "$WS" ] && [ -d "$WS" ] || { echo "cannot create temp workspace" >&2; exit 1; }
trap 'rm -rf "$WS"' EXIT

# Never let an unset GH_IDENTITY_TABLE fall through to the operator's own file.
export XDG_CONFIG_HOME="$WS/xdg"
unset GH_IDENTITY_TABLE

# `git remote get-url` applies url.<base>.insteadOf rewriting, so an operator's
# own gitconfig would silently change what the fixture remotes below resolve to
# — the plain-github.com fixture especially, which exists to exercise the owner
# fallback. Ignore user and system config for every git call in this file.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1

n=0; fails=0
ok() { n=$((n+1)); printf '  ok %2d - %s\n' "$n" "$1"; }
no() { n=$((n+1)); fails=$((fails+1)); printf 'NOT OK %2d - %s\n' "$n" "$1"; }
check() { if eval "$1"; then ok "$2"; else no "$2 [$1]"; fi; }

TABLE="$WS/identities.tsv"
cat >"$TABLE" <<'EOF'
# comment line must be ignored
github-personal   octocat       personal   octocat
github-work       example-org   work       octocat-at-example
github-lab        labs-user     lab        labs-user
EOF

BIN="$WS/bin"
mkdir -p "$BIN"
cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${STUB_GH_STDOUT:-}"
printf '%s' "${STUB_GH_STDERR:-}" >&2
exit "${STUB_GH_RC:-0}"
EOF
chmod +x "$BIN/gh"

REAL_MKTEMP="$(command -v mktemp)"
cat >"$BIN/mktemp" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_MKTEMP_FAIL:-0}" -eq 1 ]; then
  printf 'mktemp: simulated failure\n' >&2
  exit 1
fi
exec "$REAL_MKTEMP" "$@"
EOF
chmod +x "$BIN/mktemp"

CHECK_OUT="$WS/check.out"
CHECK_ERR="$WS/check.err"
CHECK_RC=0
run_check() {
  local check_dir="${4:-$PERSONAL}" mktemp_fail="${5:-0}"
  STUB_GH_STDOUT="$1" STUB_GH_STDERR="$2" STUB_GH_RC="$3" \
    STUB_MKTEMP_FAIL="$mktemp_fail" REAL_MKTEMP="$REAL_MKTEMP" \
    GH_IDENTITY_TABLE="$TABLE" PATH="$BIN:$PATH" \
    bash "$GUARD" --check "$check_dir" >"$CHECK_OUT" 2>"$CHECK_ERR"
  CHECK_RC=$?
}

mkrepo() {  # mkrepo <name> <remote-url>
  local d="$WS/$1"
  mkdir -p "$d" && git -C "$d" init -q 2>/dev/null
  [ -n "$2" ] && git -C "$d" remote add origin "$2"
  printf '%s' "$d"
}

# decision <cwd> <command> [tool_name]  ->  prints "ALLOW" or the deny reason
decision() {
  local out
  out="$(jq -n --arg c "$2" --arg d "$1" --arg t "${3:-Bash}" \
        '{tool_name:$t,cwd:$d,tool_input:{command:$c}}' \
        | GH_IDENTITY_TABLE="$TABLE" bash "$GUARD")"
  if [ -z "$out" ]; then printf 'ALLOW'
  else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason'; fi
}

# Same, but against an arbitrary identity table — for the table's own states.
decision_with_table() {  # <table> <cwd> <command>
  local out
  out="$(jq -n --arg c "$3" --arg d "$2" \
        '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
        | GH_IDENTITY_TABLE="$1" bash "$GUARD")"
  if [ -z "$out" ]; then printf 'ALLOW'
  else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason'; fi
}

# A full Codex PreToolUse payload: same contract, extra fields.
codex_decision() {
  local out
  out="$(jq -n --arg c "$2" --arg d "$1" '{
          session_id:"thr_123", transcript_path:"/tmp/x.jsonl", cwd:$d,
          hook_event_name:"PreToolUse", model:"gpt-5-codex", turn_id:"turn_1",
          permission_mode:"default", tool_name:"Bash", tool_use_id:"call_1",
          tool_input:{command:$c}}' \
        | GH_IDENTITY_TABLE="$TABLE" bash "$GUARD")"
  if [ -z "$out" ]; then printf 'ALLOW'
  else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason'; fi
}
denied()  { [ "$(decision "$1" "$2")" != "ALLOW" ]; }
allowed() { [ "$(decision "$1" "$2")"  = "ALLOW" ]; }
says()    { decision "$1" "$2" | grep -q "$3"; }

PERSONAL="$(mkrepo personal git@github-personal:octocat/skills.git)"
LAB="$(mkrepo lab git@github-lab:labs-user/public.git)"
PLAIN="$(mkrepo plain https://github.com/example-org/thing.git)"
SSHURL="$(mkrepo sshurl ssh://git@github-work/example-org/other.git)"
NOREMOTE="$(mkrepo noremote '')"
UNKNOWN="$(mkrepo unknown git@github.com:someoneelse/thing.git)"

echo "# 0. usage"
check "$GUARD --help | grep -q -- '--resolve'" "--help lists the modes"
check "$GUARD --help >/dev/null 2>&1" "--help exits 0"
# An unrecognised argument must not fall through to hook mode, where the script
# would block reading a payload that is never coming.
check "$GUARD --nonsense </dev/null >/dev/null 2>&1; [ \$? -eq 2 ]" \
      "an unrecognised flag exits 2 instead of waiting on stdin"
check "$GUARD --nonsense </dev/null 2>&1 >/dev/null | grep -q -- '--resolve'" \
      "an unrecognised flag prints the usage"
check "$GUARD '$WS' </dev/null >/dev/null 2>&1; [ \$? -eq 2 ]" \
      "a bare directory argument is rejected, not guessed at"

echo "# 1. resolves each remote form to the right alias"
check "GH_IDENTITY_TABLE='$TABLE' $GUARD --resolve '$PERSONAL' 2>&1 | grep -q 'gh personal'" \
      "ssh host alias -> personal"
check "GH_IDENTITY_TABLE='$TABLE' $GUARD --resolve '$LAB' 2>&1 | grep -q 'gh lab'" \
      "github-lab -> lab"
check "GH_IDENTITY_TABLE='$TABLE' $GUARD --resolve '$PLAIN' 2>&1 | grep -q 'gh work'" \
      "https owner fallback -> work"
check "GH_IDENTITY_TABLE='$TABLE' $GUARD --resolve '$SSHURL' 2>&1 | grep -q 'gh work'" \
      "ssh:// form -> work"

echo "# 2. unresolvable repos fail, and fail closed"
check "GH_IDENTITY_TABLE='$TABLE' $GUARD --resolve '$NOREMOTE' >/dev/null 2>&1; [ \$? -eq 1 ]" \
      "no origin -> resolve exits 1"
check "GH_IDENTITY_TABLE='$TABLE' $GUARD --resolve '$UNKNOWN' >/dev/null 2>&1; [ \$? -eq 1 ]" \
      "unlisted owner -> resolve exits 1"
check "denied '$NOREMOTE' 'gh pr create'" "no origin -> gh blocked"
check "denied '$UNKNOWN' 'gh pr create'" "unlisted owner -> gh blocked"

run_check '' '' 0 "$NOREMOTE"
check "[ '$CHECK_RC' -eq 2 ]" "no origin -> check exits 2"
check "grep -q '^UNVERIFIED:' '$CHECK_ERR'" "no origin -> check is unverified"
check "grep -q 'Identity unknown.*no GitHub writes' '$CHECK_ERR'" "no origin -> check fails closed"

run_check '' '' 0 "$UNKNOWN"
check "[ '$CHECK_RC' -eq 2 ]" "unlisted owner -> check exits 2"
check "grep -q '^UNVERIFIED:' '$CHECK_ERR'" "unlisted owner -> check is unverified"
check "grep -q 'Identity unknown.*no GitHub writes' '$CHECK_ERR'" "unlisted owner -> check fails closed"

echo "# 3. bare gh is blocked and names the right alias"
check "denied '$PERSONAL' 'gh pr create'" "bare gh blocked"
check "says '$PERSONAL' 'gh pr create' 'gh personal'" "names the correct alias"
check "denied '$LAB' 'gh issue create -t x'" "bare gh blocked in a second repo"
check "says '$LAB' 'gh issue create -t x' 'gh lab'" "names the lab alias"
check "says '$PERSONAL' 'gh pr create' 'resolved from the tool call'" \
      "bare gh names cwd as the basis"
check "says '$PERSONAL' 'gh pr create' '$PERSONAL'" "bare gh prints the cwd value"

echo "# 4. the correct alias passes"
check "allowed '$PERSONAL' 'gh personal pr create'" "right alias allowed"
check "allowed '$LAB' 'gh lab pr list'" "right alias allowed (lab)"

echo "# 5. the WRONG alias is blocked — the cross-account case"
check "denied '$PERSONAL' 'gh work pr create'" "wrong alias blocked"
check "says '$PERSONAL' 'gh work pr create' 'cross-account'" \
      "flagged as a possible cross-account write"
check "denied '$LAB' 'gh personal release create v1'" "wrong alias blocked (lab repo)"

# The block is ambiguous, and the hook cannot tell the two cases apart: identity
# comes from cwd only, never from the command's --repo/-R/positional target. So
# `gh personal repo view octocat/skills` from a lab repo is a *correct* command
# that still trips the guard. A message that only asserts "wrong alias for this
# repo" sends the reader to re-run it as the wrong account, which 404s on a
# private repo — the exact symptom SKILL.md teaches as a wrong-account query.
# The text must therefore name its cwd basis and carry both remedies.
MISMATCH_CMD='gh personal repo view octocat/skills'
check "says '$LAB' '$MISMATCH_CMD' 'resolved from the tool call'" \
      "mismatch names cwd as the basis"
check "says '$LAB' '$MISMATCH_CMD' '$LAB'" "mismatch prints the cwd value"
check "says '$LAB' '$MISMATCH_CMD' 'gh lab'" "mismatch names the resolved alias"
check "says '$LAB' '$MISMATCH_CMD' 'never the command'" \
      "mismatch says the command's own target is not read"
check "says '$LAB' '$MISMATCH_CMD' 'cd <that repo> && gh personal'" \
      "mismatch offers the inline cd form for a target owned by another account"

echo "# 6. gh auth mutations are always blocked, aliased or not"
check "denied '$PERSONAL' 'gh auth switch'" "auth switch blocked"
check "denied '$PERSONAL' 'gh auth login'" "auth login blocked"
check "denied '$PERSONAL' 'gh auth logout'" "auth logout blocked"
check "denied '$NOREMOTE' 'gh auth switch'" "auth switch blocked outside a repo too"
check "allowed '$PERSONAL' 'gh auth status'" "auth status allowed"

echo "# 7. identity-neutral commands pass bare"
check "allowed '$PERSONAL' 'gh --version'" "--version allowed"
check "allowed '$PERSONAL' 'gh help'" "help allowed"
check "allowed '$PERSONAL' 'gh alias list'" "alias list allowed"

echo "# 8. only real gh invocations are inspected"
check "allowed '$PERSONAL' 'npm test'" "unrelated command allowed"
check "allowed '$PERSONAL' 'echo highlight'" "'gh' inside a word is not a match"
check "allowed '$PERSONAL' 'ls ~/gh-pages'" "'gh' inside a path is not a match"
check "allowed '$PERSONAL' 'git push'" "git push untouched"

echo "# 9. gh found later in a compound command is still caught"
check "denied '$PERSONAL' 'git push && gh pr create'" "after && "
check "denied '$PERSONAL' 'git add -A; gh pr create'" "after ;"
check "denied '$PERSONAL' 'make build || gh issue create'" "after ||"
check "denied '$PERSONAL' 'GH_DEBUG=1 gh pr create'" "behind an env assignment"
check "allowed '$PERSONAL' 'git push && gh personal pr create'" \
      "compound with right alias allowed"

echo "# 10. the same script serves Codex — identical PreToolUse contract"
check "[ \"\$(codex_decision '$PERSONAL' 'gh pr create')\" != ALLOW ]" \
      "codex payload: bare gh blocked"
check "codex_decision '$PERSONAL' 'gh pr create' | grep -q 'gh personal'" \
      "codex payload: names the alias"
check "[ \"\$(codex_decision '$PERSONAL' 'gh personal pr create')\" = ALLOW ]" \
      "codex payload: right alias allowed"

echo "# 11. non-shell tools are ignored even under a broad matcher"
# Codex's apply_patch also carries its payload in tool_input.command, so a patch
# whose text merely mentions gh must not be mistaken for a gh invocation.
check "[ \"\$(decision '$PERSONAL' '*** Begin Patch: run gh pr create later' apply_patch)\" = ALLOW ]" \
      "apply_patch payload ignored"
check "[ \"\$(decision '$PERSONAL' 'gh pr create' mcp__fs__read)\" = ALLOW ]" \
      "MCP tool payload ignored"
check "[ \"\$(decision '$PERSONAL' 'gh pr create' Bash)\" != ALLOW ]" "Bash still inspected"

echo "# 12. live verification distinguishes mismatch from an unknown identity"
run_check 'octocat' '' 0
check "[ '$CHECK_RC' -eq 0 ]" "expected login -> exit 0"
check "grep -q '^verified: octocat$' '$CHECK_OUT'" "expected login -> verified"

run_check 'octocat-at-example' '' 0
check "[ '$CHECK_RC' -eq 1 ]" "wrong login -> exit 1"
check "grep -q '^MISMATCH:' '$CHECK_ERR'" "wrong login -> mismatch"
check "! grep -q '^UNVERIFIED:' '$CHECK_ERR'" "wrong login is not unverified"

run_check '' 'no oauth token found for github.com' 1
check "[ '$CHECK_RC' -eq 2 ]" "credential-store failure -> exit 2"
check "grep -q '^UNVERIFIED:' '$CHECK_ERR'" "credential-store failure -> unverified"
check "grep -q 'token came back empty' '$CHECK_ERR'" "credential-store failure -> diagnosed"
check "grep -q 'did not match it' '$CHECK_ERR'" \
      "credential-store failure separates missing exemption from unmatched invocation"
check "grep -qF '$GUARD --check' '$CHECK_ERR'" \
      "diagnosis prints the canonical absolute invocation"
check "grep -q 'Identity unknown.*no GitHub writes' '$CHECK_ERR'" \
      "credential-store failure -> fails closed"
check "! grep -q '^MISMATCH:' '$CHECK_ERR'" "credential-store failure is not a mismatch"

run_check '' 'network unavailable' 4
check "[ '$CHECK_RC' -eq 2 ]" "generic command failure -> exit 2"
check "grep -q '^  stderr: network unavailable$' '$CHECK_ERR'" "generic failure preserves stderr"

run_check 'octocat-at-example' 'request failed' 1
check "[ '$CHECK_RC' -eq 2 ]" "failed call with stdout -> exit 2"
check "grep -q '^UNVERIFIED:' '$CHECK_ERR'" "failed call with stdout -> unverified"

run_check '' '' 0
check "[ '$CHECK_RC' -eq 2 ]" "empty successful response -> exit 2"
check "grep -q 'failed (exit 0).*no account was determined' '$CHECK_ERR'" \
      "empty successful response -> identity unknown"

run_check '' '' 0 "$PERSONAL" 1
check "[ '$CHECK_RC' -eq 2 ]" "stderr capture failure -> exit 2"
check "grep -q '^UNVERIFIED: cannot create stderr capture' '$CHECK_ERR'" \
      "stderr capture failure -> diagnosed"
check "grep -q 'Identity unknown.*no GitHub writes' '$CHECK_ERR'" \
      "stderr capture failure -> fails closed"
check "! grep -q '^MISMATCH:' '$CHECK_ERR'" "stderr capture failure is not a mismatch"

echo "# 13. a leading \`cd <path> &&\` is the target, not cwd"
# cwd is only a proxy for the directory gh runs in; an inline cd IS it. Codex
# reports the session's cwd for every call and has no per-call workdir, so this
# is the only way a call there can reach a repo owned by another account.
check "allowed '$PERSONAL' 'cd $LAB && gh lab pr list'" \
      "cd into a lab repo from a personal cwd -> gh lab allowed"
check "allowed '$LAB' 'cd $PERSONAL && gh personal pr create'" \
      "cd into a personal repo from a lab cwd -> gh personal allowed"
check "allowed '$PERSONAL' 'cd \"$LAB\" && gh lab pr list'" "double-quoted path accepted"
check "allowed '$PERSONAL' \"cd '$LAB' && gh lab pr list\"" "single-quoted path accepted"

# `~` is expanded by string substitution against $HOME, never by the shell.
home_decision() {
  local out
  out="$(jq -n --arg c "$2" --arg d "$1" \
        '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
        | HOME="$WS" GH_IDENTITY_TABLE="$TABLE" bash "$GUARD")"
  if [ -z "$out" ]; then printf 'ALLOW'
  else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason'; fi
}
check "[ \"\$(home_decision '$PERSONAL' 'cd ~/lab && gh lab pr list')\" = ALLOW ]" \
      "~-prefixed path expanded against \$HOME"

# The wrong alias for the *resolved* target still blocks, and the message must
# name that target — never a directory the decision was not based on.
CROSS_CMD="cd $LAB && gh personal pr create"
check "denied '$PERSONAL' '$CROSS_CMD'" "wrong alias for the cd target blocked"
check "says '$PERSONAL' '$CROSS_CMD' '$LAB'" "message names the resolved target"
check "! says '$PERSONAL' '$CROSS_CMD' '$PERSONAL'" "message does not name cwd"
check "says '$PERSONAL' '$CROSS_CMD' 'gh lab'" "message names the target's alias"

# Anything the guard cannot read literally falls back to cwd — stricter, never
# looser.
check "says '$PERSONAL' 'cd /nonexistent/path && gh lab pr list' '$PERSONAL'" \
      "non-directory path falls back to cwd"
EXPAND_CMD='cd "$(cat /tmp/x)" && gh lab pr list'
check "says '$PERSONAL' '$EXPAND_CMD' '$PERSONAL'" "command substitution is not expanded"
VAR_CMD='cd "$REPO" && gh lab pr list'
check "says '$PERSONAL' '$VAR_CMD' '$PERSONAL'" "a \$VAR path is not expanded"
check "says '$PERSONAL' 'cd $PERSONAL && cd $LAB && gh lab pr list' '$PERSONAL'" \
      "a second chained cd is ambiguous -> falls back to cwd"
check "says '$PERSONAL' 'git pull && cd $LAB && gh lab pr list' '$PERSONAL'" \
      "cd that is not the first command -> falls back to cwd"

# Everything ahead of resolution is unchanged by the prefix.
check "denied '$PERSONAL' 'cd $LAB && gh pr create'" "bare gh after a cd still blocked"
check "says '$PERSONAL' 'cd $LAB && gh pr create' 'gh lab'" \
      "bare gh after a cd names the target's alias"
check "says '$PERSONAL' 'cd $LAB && gh pr create' '$LAB'" \
      "bare gh after a cd names the resolved target"
check "denied '$PERSONAL' 'cd $LAB && gh auth switch'" "auth switch after a cd still blocked"
check "denied '$PERSONAL' 'cd $NOREMOTE && gh lab pr list'" \
      "unresolvable cd target still fails closed"
check "says '$PERSONAL' 'cd $NOREMOTE && gh lab pr list' '$NOREMOTE'" \
      "fail-closed message names the resolved target"
check "allowed '$PERSONAL' 'cd $LAB && gh --version'" "identity-neutral command still passes"

echo "# 14. scripts that call gh internally"
# The scan above only sees the command string, so a script that runs `gh` two
# processes down passes it untouched. `handover.sh state` is one: its PR lookup
# would query whichever account is active. It takes the account as an inline
# variable, so require that — but only where an identity actually resolves, since
# the rest of the snapshot is git data that has no account to get wrong.
HS="skills/handover/scripts/handover.sh"
check "denied '$PERSONAL' '$HS state .'" "handover state without an account is blocked"
check "says '$PERSONAL' '$HS state .' 'HANDOVER_GH_ALIAS=personal'" \
      "handover block names the variable and the resolved alias"
check "allowed '$PERSONAL' 'HANDOVER_GH_ALIAS=personal $HS state .'" \
      "handover state naming the account passes"
check "allowed '$PERSONAL' 'HANDOVER_MODEL_NAME=m HANDOVER_GH_ALIAS=personal $HS state .'" \
      "the account may sit among other inline variables"
check "denied '$PERSONAL' 'HANDOVER_GH_ALIAS= $HS state .'" \
      "an empty account variable does not satisfy the rule"
check "allowed '$NOREMOTE' '$HS state .'" \
      "handover state is left alone where no identity resolves"
check "allowed '$UNKNOWN' '$HS state .'" \
      "handover state is left alone for a repo missing from the table"
check "allowed '$PERSONAL' '$HS save .'" "only the snapshot command is gated"
check "allowed '$PERSONAL' '$HS latest .'" "reading a stored handover is not gated"
check "denied '$PERSONAL' 'cd $LAB && $HS state .'" \
      "handover state after a cd is judged by the cd target"
check "says '$PERSONAL' 'cd $LAB && $HS state .' 'HANDOVER_GH_ALIAS=lab'" \
      "handover block after a cd names the target's alias"
check "allowed '$PERSONAL' 'echo $HS state .'" \
      "handover.sh named as an argument is not an invocation"
check "allowed '$PERSONAL' 'grep -n state $HS'" \
      "handover.sh read as a file is not an invocation"

echo "# 15. the identity table's own states are diagnosed, not conflated"
MISSING_TABLE="$WS/absent/identities.tsv"
check "[ ! -f '$MISSING_TABLE' ]" "the missing-table fixture really is absent"
check "[ \"\$(decision_with_table '$MISSING_TABLE' '$PERSONAL' 'gh pr create')\" != ALLOW ]" \
      "a missing table still fails closed"
check "decision_with_table '$MISSING_TABLE' '$PERSONAL' 'gh pr create' | grep -q -- '--init'" \
      "a missing table is diagnosed, naming --init"

EMPTY_TABLE="$WS/empty.tsv"
cp "$TEMPLATE" "$EMPTY_TABLE"
check "! awk '!/^[[:space:]]*(#|\$)/ {f=1} END{exit f?0:1}' '$TEMPLATE'" \
      "the shipped template carries no live identity rows"
check "[ \"\$(decision_with_table '$EMPTY_TABLE' '$PERSONAL' 'gh pr create')\" != ALLOW ]" \
      "a table with no rows still fails closed"
check "decision_with_table '$EMPTY_TABLE' '$PERSONAL' 'gh pr create' | grep -q 'no identity rows yet'" \
      "an unpopulated table is diagnosed as such, not as a missing repo"
check "! decision_with_table '$EMPTY_TABLE' '$PERSONAL' 'gh pr create' | grep -q -- '--init'" \
      "an existing table is not diagnosed as missing"

GH_IDENTITY_TABLE="$MISSING_TABLE" $GUARD --resolve "$PERSONAL" >/dev/null 2>"$WS/r.err"
check "grep -q -- '--init' '$WS/r.err'" "--resolve also names --init when the table is missing"

echo "# 16. --init seeds the table without ever overwriting one"
INIT_TABLE="$WS/init/identities.tsv"
check "GH_IDENTITY_TABLE='$INIT_TABLE' $GUARD --init >/dev/null" "--init exits 0"
check "[ -f '$INIT_TABLE' ]" "--init creates the table"
check "cmp -s '$INIT_TABLE' '$TEMPLATE'" "--init copies the shipped template verbatim"
printf 'github-personal octocat personal octocat\n' >>"$INIT_TABLE"
check "GH_IDENTITY_TABLE='$INIT_TABLE' $GUARD --init | grep -q 'already exists'" \
      "a second --init reports the file is already there"
check "grep -q '^github-personal' '$INIT_TABLE'" "a second --init leaves the edits intact"

# With no override, the table is XDG-scoped and never inside this checkout.
check "$GUARD --init | grep -qF '$XDG_CONFIG_HOME/gh-identity/identities.tsv'" \
      "the default table lives under XDG_CONFIG_HOME"
check "[ -f '$XDG_CONFIG_HOME/gh-identity/identities.tsv' ]" "the default table is created there"
check "[ ! -e '$skill_dir/identities.tsv' ]" "no identity table is written into the checkout"

echo "# 17. without jq the hook fails closed, but only where it must"
NOJQ="$WS/nojq"
mkdir -p "$NOJQ"
for b in git awk cat tr mktemp dirname basename readlink cp mkdir rm chmod sed grep; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$b"
done
check "! PATH='$NOJQ' command -v jq >/dev/null 2>&1" "the jq-free PATH really lacks jq"
jq -n '{tool_name:"Bash",cwd:"/",tool_input:{command:"gh pr create"}}' \
  | PATH="$NOJQ" "$BASH" "$GUARD" >"$WS/nojq.out" 2>"$WS/nojq.err"
NOJQ_RC=$?
check "[ '$NOJQ_RC' -ne 0 ]" "a possible gh call without jq is blocked"
check "grep -q 'jq' '$WS/nojq.err'" "the block says jq is missing"
jq -n '{tool_name:"Bash",cwd:"/",tool_input:{command:"npm test"}}' \
  | PATH="$NOJQ" "$BASH" "$GUARD" >"$WS/nojq2.out" 2>"$WS/nojq2.err"
NOJQ2_RC=$?
check "[ '$NOJQ2_RC' -eq 0 ]" "an unrelated command without jq still runs"
check "[ ! -s '$WS/nojq2.out' ]" "an unrelated command emits no decision"

echo "# 18. docs agree with the sandbox exemption"
# The exemption matches the literal command string, so a tilde-prefixed or
# relative invocation in the docs silently misses it: the guard then runs
# sandboxed and reports an empty token, which reads as "no exemption configured"
# even when one is. Nothing at runtime catches that, so check the strings
# against each other here.
SKILL_MD="$skill_dir/SKILL.md"
INSTALL_MD="$skill_dir/INSTALL.md"
README_MD="$skill_dir/README.md"

pattern="$(grep -oE '"/[^"]*gh-identity-guard\.sh \*"' "$INSTALL_MD" | head -1 | tr -d '"')"
check "[ -n '$pattern' ]" "INSTALL.md declares a sandbox exemption pattern"
check "case '$pattern' in /*) true;; *) false;; esac" "exemption pattern is an absolute path"

skill_cmd="$(grep -oE '[~/][^[:space:]]*gh-identity-guard\.sh --check[^\`]*' "$SKILL_MD" \
             | head -1 | sed 's/[[:space:]]*$//')"
check "[ -n '$skill_cmd' ]" "SKILL.md documents a --check invocation"

# Unquoted on the right of `case` so the trailing * globs. Cannot go through
# check()'s eval, which would quote it.
skill_matches=0
case "$skill_cmd" in $pattern) skill_matches=1 ;; esac
check "[ '$skill_matches' -eq 1 ]" "SKILL.md --check invocation matches the exemption pattern"

hook_cmd="$(grep -oE '"/[^"]*gh-identity-guard\.sh"' "$INSTALL_MD" | head -1 | tr -d '"')"
pattern_path="${pattern% \*}"
check "[ '$hook_cmd' = '$pattern_path' ]" "hook command and exemption pattern name one path"

for doc in "$SKILL_MD" "$INSTALL_MD" "$README_MD"; do
  check "! grep -q '~/[A-Za-z0-9_./-]*gh-identity-guard\.sh' '$doc'" \
        "$(basename "$doc") documents no tilde-form invocation"
done

# The documented path is a placeholder root plus this script's real place in the
# repository. Check that tail, then apply the exemption to the guard's own
# canonical path — the string it prints in its keyring diagnosis, generated
# rather than copied, and so the one most able to drift out of the exemption.
SFX='/skills/gh-identity/scripts/gh-identity-guard.sh'
doc_root="${hook_cmd%$SFX}"
check "[ '$doc_root' != '$hook_cmd' ]" "docs name the guard at its in-repo path"
real_root="${GUARD%$SFX}"
check "[ '$real_root' != '$GUARD' ]" "the guard really lives at that in-repo path"
real_pattern="$real_root$SFX *"
self_matches=0
case "$GUARD --check ." in $real_pattern) self_matches=1 ;; esac
check "[ '$self_matches' -eq 1 ]" "guard's own path matches the exemption pattern"

echo "# 19. nothing machine-specific is published with the skill"
# Bracketed first letters so this file does not match its own patterns. Every
# path in the docs is either relative to the checkout or the placeholder root
# INSTALL.md defines; a real home directory means someone's machine leaked in.
check "! grep -rIqE '/[U]sers/[A-Za-z0-9]' '$skill_dir'" \
      "no macOS home path is baked into the skill"
check "! grep -rIqE '/[h]ome/[A-Za-z0-9]' '$skill_dir'" \
      "no Linux home path is baked into the skill"

echo "# 20. the wt pr integration resolves through the same guard"
if command -v zsh >/dev/null 2>&1; then
  wt_out="$(GH_IDENTITY_TABLE="$TABLE" zsh -fc \
    "source '$script_dir/wt-gh-alias.zsh'; wt_gh_alias '$PERSONAL'" 2>/dev/null)"
  check "[ '$wt_out' = personal ]" "wt_gh_alias finds the guard beside itself"

  wt_out2="$(GH_IDENTITY_TABLE="$TABLE" GH_IDENTITY_GUARD="$GUARD" zsh -fc \
    "source '$script_dir/wt-gh-alias.zsh'; wt_gh_alias '$LAB'" 2>/dev/null)"
  check "[ '$wt_out2' = lab ]" "GH_IDENTITY_GUARD overrides the location"

  GH_IDENTITY_GUARD=/nonexistent/guard.sh zsh -fc \
    "source '$script_dir/wt-gh-alias.zsh'; wt_gh_alias '$PERSONAL'" >/dev/null 2>&1
  WT_MISSING_RC=$?
  check "[ '$WT_MISSING_RC' -ne 0 ]" "a missing guard makes wt_gh_alias fail rather than answer"

  GH_IDENTITY_TABLE="$TABLE" zsh -fc \
    "source '$script_dir/wt-gh-alias.zsh'; wt_gh_alias '$UNKNOWN'" >/dev/null 2>&1
  WT_UNKNOWN_RC=$?
  check "[ '$WT_UNKNOWN_RC' -ne 0 ]" "an unresolvable repo makes wt_gh_alias fail rather than answer"
else
  echo "  -- zsh not installed, skipping the wt pr integration tests"
fi

echo
if [ "$fails" -eq 0 ]; then
  printf 'ALL %d TESTS PASSED\n' "$n"; exit 0
else
  printf '%d/%d TESTS FAILED\n' "$fails" "$n"; exit 1
fi
