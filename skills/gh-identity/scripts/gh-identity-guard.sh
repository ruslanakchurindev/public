#!/usr/bin/env bash
set -uo pipefail

# gh-identity-guard — resolve, and optionally enforce, the right GitHub account
# for the repository you are standing in. Background: README.md.
#
#   --resolve [dir]   print the alias/login this repo requires (no network call)
#   --check   [dir]   --resolve, then verify the live login actually matches
#   --init            seed the identity table from the shipped template
#   (no args)         PreToolUse hook: read the tool call as JSON on stdin and
#                     deny Bash commands calling `gh` without the right alias
#
# Advisory and enforcement share one resolver, so the skill's advice and the
# hook's blocks can never disagree.
#
# Requires git; jq for hook mode; the GitHub CLI for --check. Portable across
# macOS bash 3.2 and GNU bash.

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src";; esac
done
here="$(cd -P "$(dirname "$_src")" && pwd)"
me="$(basename "$_src")"
self="$here/$me"                   # canonical absolute path; sandbox exemptions match it literally
root="$(cd -P "$here/.." && pwd)"  # the skill directory: docs and templates live here
template="$root/templates/identities.tsv"

# User data: lives in the user's config dir, never in this checkout, so an update
# cannot conflict with it and the published repo carries no account names.
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
table="${GH_IDENTITY_TABLE:-$config_home/gh-identity/identities.tsv}"

usage() {
  cat <<EOF
gh-identity-guard — pick and verify the right GitHub account for a repository.

  $me --resolve [dir]   print the alias and login this repo requires
  $me --check   [dir]   --resolve, then verify the live login matches
  $me --init            create the identity table from the template
  $me --help            this message

[dir] defaults to the current directory. With no arguments at all the script
acts as a Claude Code / Codex PreToolUse hook, reading the tool call as JSON on
stdin.

Invoke it by this absolute path — sandbox exemptions match the literal string,
so a ~/ prefix or a relative path silently misses one that exists:
  $self

Identity table: $table
                (override with GH_IDENTITY_TABLE; create with --init)
Setup:          $root/INSTALL.md
EOF
}

# --- the identity table ------------------------------------------------------
# One actionable sentence when the table is the problem; empty when it is
# populated and the repository is simply not listed.
table_hint() {
  if [ ! -f "$table" ]; then
    printf 'There is no identity table at %s yet — create one with `%s --init`, then add a row for this repository.' \
      "$table" "$self"
  elif ! awk '!/^[[:space:]]*(#|$)/ {f=1} END{exit f?0:1}' "$table" 2>/dev/null; then
    printf '%s exists but holds no identity rows yet — every row is still commented out. Add one (the file documents its own columns).' \
      "$table"
  fi
}

die_hook() {  # deny the tool call with a reason the agent will read
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# --- resolve a repo directory to an identity row -----------------------------
# Prints: <ssh-host> <owner> <alias> <login>   (empty + rc!=0 when unresolvable)
resolve_row() {
  local dir="$1" url rest host owner row
  [ -n "$dir" ] || dir="$PWD"
  url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1

  case "$url" in
    git@*:*)
      host="${url#git@}"; host="${host%%:*}"
      owner="${url#*:}";  owner="${owner%%/*}" ;;
    ssh://git@*/*)
      rest="${url#ssh://git@}"
      host="${rest%%/*}"; rest="${rest#*/}"; owner="${rest%%/*}" ;;
    https://*/*)
      rest="${url#https://}"
      host="${rest%%/*}"; rest="${rest#*/}"; owner="${rest%%/*}" ;;
    *) return 1 ;;
  esac

  # Host alias is the strong signal; owner is the fallback for remotes written
  # as plain github.com, which `insteadOf` rewrites for git but not here.
  row="$(awk -v h="$host"  '!/^[[:space:]]*(#|$)/ && $1==h {print; exit}' "$table" 2>/dev/null)"
  [ -n "$row" ] || row="$(awk -v o="$owner" '!/^[[:space:]]*(#|$)/ && $2==o {print; exit}' "$table" 2>/dev/null)"
  [ -n "$row" ] || return 1
  printf '%s\n' "$row"
}

known_alias() {  # is $1 one of the aliases in the table?
  awk -v a="$1" '!/^[[:space:]]*(#|$)/ && $3==a {f=1} END{exit f?0:1}' "$table" 2>/dev/null
}

# --- mode: --help ------------------------------------------------------------
case "${1:-}" in
  --help|-h|help) usage; exit 0 ;;
esac

# --- mode: --init ------------------------------------------------------------
# Never overwrites: a second run of an install step must not discard the user's
# own configuration.
if [ "${1:-}" = "--init" ]; then
  if [ -f "$table" ]; then
    printf 'gh-identity: %s already exists — left unchanged.\n' "$table"
    exit 0
  fi
  if [ ! -f "$template" ]; then
    printf 'gh-identity: template not found at %s\n' "$template" >&2
    printf '  Run this script from its checkout, or via a symlink to it.\n' >&2
    exit 1
  fi
  if ! mkdir -p "$(dirname "$table")" || ! cp "$template" "$table"; then
    printf 'gh-identity: cannot create %s\n' "$table" >&2
    exit 1
  fi
  chmod 600 "$table" 2>/dev/null
  printf 'gh-identity: created %s\n' "$table"
  printf '  Add one row per account: <ssh-host> <owner> <gh-alias> <expected-login>\n'
  printf '  Then verify:  %s --check <repo>\n' "$self"
  exit 0
fi

# --- mode: --resolve / --check ----------------------------------------------
if [ "${1:-}" = "--resolve" ] || [ "${1:-}" = "--check" ]; then
  mode="$1"; dir="${2:-$PWD}"
  if ! row="$(resolve_row "$dir")"; then
    hint="$(table_hint)"
    if [ "$mode" = "--check" ]; then
      printf 'UNVERIFIED: cannot resolve an identity for %s — no account was determined.\n' "$dir" >&2
      printf '  no origin remote, or its host/owner is not listed in %s\n' "$table" >&2
      [ -n "$hint" ] && printf '  %s\n' "$hint" >&2
      printf '  Identity unknown — treat as unsafe: no GitHub writes.\n' >&2
      exit 2
    fi
    printf 'gh-identity: cannot resolve an identity for %s\n' "$dir" >&2
    printf '  no origin remote, or its host/owner is not listed in %s\n' "$table" >&2
    [ -n "$hint" ] && printf '  %s\n' "$hint" >&2
    exit 1
  fi
  # shellcheck disable=SC2086
  set -- $row; r_host="$1"; r_owner="$2"; r_alias="$3"; r_login="$4"
  printf 'repo:     %s\n' "$dir"
  printf 'remote:   %s (%s)\n' "$r_host" "$r_owner"
  printf 'use:      gh %s ...\n' "$r_alias"
  printf 'expect:   %s\n' "$r_login"
  [ "$mode" = "--resolve" ] && exit 0

  # Keep stderr separate: merging it makes every failure look like a
  # wrong-account answer. An explicit template, not `-t`: macOS mktemp ignores
  # $TMPDIR under -t and uses the Darwin per-user temp dir, which an agent
  # sandbox denies — turning every sandboxed run into UNVERIFIED.
  if ! err_file="$(mktemp "${TMPDIR:-/tmp}/gh-identity-guard.XXXXXX")"; then
    printf 'UNVERIFIED: cannot create stderr capture — no account was determined.\n' >&2
    printf '  Identity unknown — treat as unsafe: no GitHub writes.\n' >&2
    exit 2
  fi
  actual="$(gh "$r_alias" api user --jq .login 2>"$err_file")"; rc=$?
  err="$(cat "$err_file")"; rm -f "$err_file"

  if [ "$rc" -eq 0 ] && [ "$actual" = "$r_login" ]; then
    printf 'verified: %s\n' "$actual"
    exit 0
  fi

  if [ "$rc" -ne 0 ] || [ -z "$actual" ]; then
    printf 'UNVERIFIED: `gh %s api user` failed (exit %s) — no account was determined.\n' "$r_alias" "$rc" >&2
    case "$err" in
      *"no oauth token found"*)
        printf '  cause: alias resolved, but its token came back empty from the\n' >&2
        printf '         credential store. `gh auth status` will still show the\n' >&2
        printf '         account as logged in.\n' >&2
        printf '  meaning: this run is most likely inside an agent sandbox, which\n' >&2
        printf '         cannot reach the credential store. Either no exemption is\n' >&2
        printf '         configured, or one is and this invocation did not match it:\n' >&2
        printf '         exemptions match the literal command string, so a `~/`\n' >&2
        printf '         prefix, a relative path, or a `bash <script>` prefix each\n' >&2
        printf '         miss an exemption that exists.\n' >&2
        printf '  fix 1: re-run by the canonical absolute path —\n' >&2
        printf '         %s --check <repo>\n' "$self" >&2
        printf '  fix 2: if that still fails, no exemption covers it yet. Add one —\n' >&2
        printf '         Claude Code: sandbox.excludedCommands in ~/.claude/settings.json\n' >&2
        printf '         Codex:       an allow prefix_rule for this script path\n' >&2
        printf '         Setup: %s/INSTALL.md\n' "$root" >&2
        ;;
      *) printf '  stderr: %s\n' "$err" >&2 ;;
    esac
    printf '  Identity unknown — treat as unsafe: no GitHub writes.\n' >&2
    exit 2
  fi

  printf 'MISMATCH: gh %s api user returned %s (wanted %s)\n' "$r_alias" "$actual" "$r_login" >&2
  printf '  Stop. Do not fall back to another account or run `gh auth switch`.\n' >&2
  exit 1
fi

# --- mode: PreToolUse hook ---------------------------------------------------
# Without this, an unrecognised argument falls through and blocks reading a hook
# payload that is never coming.
if [ "$#" -gt 0 ]; then
  printf 'gh-identity-guard: unrecognised argument: %s\n\n' "$1" >&2
  usage >&2
  exit 2
fi

# A terminal on stdin means someone ran it by hand expecting one of the modes.
if [ -t 0 ]; then
  usage >&2
  exit 2
fi

# Claude Code and Codex send the same PreToolUse payload and accept the same deny
# shape, so one script serves both.
input="$(cat)"

# Without jq no deny can be emitted, and a guardrail that silently stops guarding
# is worse than none. Fail closed — but only for payloads that could carry a `gh`
# call, so installing jq still works and the machine stays fixable.
if ! command -v jq >/dev/null 2>&1; then
  case "$input" in
    *gh*)
      printf 'gh-identity-guard: `jq` is not installed, so this hook cannot inspect the\n' >&2
      printf 'command or emit a decision. Blocking rather than letting a possible `gh`\n' >&2
      printf 'call run as whichever account is active. Install jq, or remove the hook.\n' >&2
      exit 2 ;;
    *) exit 0 ;;
  esac
fi

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
cmd="$(printf '%s'  "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
cwd="$(printf '%s'  "$input" | jq -r '.cwd // empty' 2>/dev/null)"

# Only shell calls. Codex's apply_patch also puts its payload in
# tool_input.command, so a patch merely containing "gh " would read as a call.
case "$tool" in Bash|bash|shell|"") ;; *) exit 0 ;; esac
[ -n "$cmd" ] || exit 0

# The directory this call actually targets. `cwd` is only a proxy: Codex reports
# the *session's* directory for every call, so a leading `cd <path> &&` is the
# only way a call can name another repo — and unlike cwd it IS where gh will run.
# No eval, ever: a path carrying `$` or a backtick, a second chained `cd`, or one
# that is not a directory falls back to cwd, which only makes the guard stricter.
target="$cwd"
case "$cmd" in
  'cd '*)
    p="${cmd#cd }"
    case "$p" in *'&&'*) rest="${p#*&&}"; p="${p%%&&*}" ;; *) p='' rest='' ;; esac
    while :; do case "$p" in ' '*) p="${p# }" ;; *' ') p="${p% }" ;; *) break ;; esac; done
    while :; do case "$rest" in ' '*) rest="${rest# }" ;; *) break ;; esac; done
    case "$p" in \'*\') p="${p#\'}"; p="${p%\'}" ;; \"*\") p="${p#\"}"; p="${p%\"}" ;; esac
    case "$p" in *'$'*|*'`'*) p='' ;; esac            # never expanded, so never trusted
    case "$rest" in cd|'cd '*) p='' ;; esac           # chained cd → ambiguous target
    case "$p" in '~') p="$HOME" ;; '~/'*) p="$HOME/${p#\~/}" ;; '~'*) p='' ;; esac
    case "$p" in /*) ;; ?*) p="$cwd/$p" ;; esac
    [ -n "$p" ] && [ -d "$p" ] && target="$p"
    ;;
esac

# The first `gh` that actually starts a command: split on shell separators, skip
# VAR=value prefixes, look at each segment's head. Catches `git push && gh pr
# create` and `GH_DEBUG=1 gh ...`; ignores `gh` inside another word.
hit="$(printf '%s\n' "$cmd" | tr ';&|()' '\n\n\n\n\n\n' | awk '
  { i = 1
    while (i <= NF && $i ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++
    if ($i == "gh") { print "gh", $(i+1), $(i+2); exit } }')"
# No `gh` at a segment head is not the same as no `gh` running: a script calling
# it internally is two processes down, and this hook only sees the command
# string, so `handover.sh state` slips past and its PR lookup runs as the active
# account. Such scripts accept the account by name, so require that name — but
# only where an identity resolves. With no origin or no table row there is no
# account to demand, and blocking would break a working command for nothing.
if [ -z "$hit" ]; then
  handover_hit="$(printf '%s\n' "$cmd" | tr ';&|()' '\n\n\n\n\n\n' | awk '
    { i = 1; named = 0
      while (i <= NF && $i ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
        if ($i ~ /^HANDOVER_GH_ALIAS=./) named = 1
        i++ }
      if ($i ~ /(^|\/)handover\.sh$/ && $(i+1) == "state") { print named; exit } }')"
  if [ -n "$handover_hit" ] && [ "$handover_hit" != 1 ] && row="$(resolve_row "$target")"; then
    # shellcheck disable=SC2086
    set -- $row; r_alias="$3"; r_login="$4"
    die_hook "Blocked: \`handover.sh state\` runs \`gh pr view\` inside the script, where this hook cannot see it, so it would query whichever GitHub account is currently active — reporting no PR, or a 404 that reads like a missing repository. \`$target\` is served by \`gh $r_alias\` (login $r_login), so name the account on the command itself: \`HANDOVER_GH_ALIAS=$r_alias <the same command>\`. It has to be inline — an exported variable is invisible from here. Nothing else about the snapshot changes, and the lookup stays read-only."
  fi
  exit 0
fi
read -r _gh gh_1 gh_2 <<EOF
$hit
EOF

# These change the active account for every repo and session. Never allowed from
# a tool call, aliased or not.
if [ "$gh_1" = "auth" ] && [ "${gh_2:-}" != "status" ] && [ -n "${gh_2:-}" ]; then
  die_hook "Blocked: \`gh auth $gh_2\` changes the globally active GitHub account, which silently re-points every other repository and session. Never run it from a tool call. To act as a different account, use its alias: \`gh <alias> ...\` (see $table)."
fi

# Identity-neutral commands are fine bare.
case "$gh_1" in
  ''|--version|version|--help|-h|help|alias) exit 0 ;;
  auth) [ "${gh_2:-}" = "status" ] && exit 0 ;;
esac

if ! row="$(resolve_row "$target")"; then
  # Cannot prove which account is correct → refuse the active one by default.
  # The fail-closed case, and the point of the hook.
  hint="$(table_hint)"
  [ -n "$hint" ] && hint=" $hint"
  die_hook "Blocked: cannot resolve which GitHub account \`$target\` belongs to (no origin remote, or its host/owner is missing from $table), so a bare \`gh\` here would run as whichever account is currently active. Name the account explicitly (\`gh <alias> ...\`) or add a row to $table.$hint"
fi
# shellcheck disable=SC2086
set -- $row; r_host="$1"; r_owner="$2"; r_alias="$3"; r_login="$4"

# Right alias already → allow.
[ "$gh_1" = "$r_alias" ] && exit 0

# Wrong alias for the resolved identity. Two situations reach here and the hook
# cannot tell them apart, since identity comes from the directory alone: wrong
# alias for this repo, or right alias and wrong directory. Give both remedies —
# asserting only the first sends the reader to re-run a correct command as the
# wrong account, which 404s on a private repo and reads as a missing one.
if known_alias "$gh_1"; then
  die_hook "Blocked: identity is resolved from the tool call's cwd, or from a leading \`cd <path> &&\` when the command starts with one, and \`$target\` is $r_owner via $r_host, which requires \`gh $r_alias\` (login $r_login) — but the command uses \`gh $gh_1\`. Possible cross-account write. The hook reads that directory only, never the command's own target (\`--repo\`, \`-R\`, or a positional owner/name), so two cases look identical from here: (a) if you meant a repository under that directory, re-run with \`gh $r_alias ...\`; (b) if \`gh $gh_1\` is the right account for the repository you are targeting, name that repository in this same command — \`cd <that repo> && gh $gh_1 ...\` — and identity resolves from it instead. Do not re-run as \`gh $r_alias\` against another account's repository: on a private repository that 404s and looks like a missing repository."
fi

die_hook "Blocked: bare \`gh $gh_1\` runs as whichever account is currently active, not necessarily $r_login. Identity is resolved from the tool call's cwd, or from a leading \`cd <path> &&\` when the command starts with one, and \`$target\` is $r_owner via $r_host — use \`gh $r_alias $gh_1 ...\`, or, if you meant a repository owned by another account, target it in this same command: \`cd <that repo> && gh <its alias> $gh_1 ...\`. (Verify once per repository with: $self --check)"
