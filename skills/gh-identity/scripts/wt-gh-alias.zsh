# wt_gh_alias — teach `wt pr` which GitHub account a repository belongs to.
#
# `wt pr` (zsh/worktrees.zsh) looks for a function by this name, hands it the
# repository root, and runs `gh <printed alias> ...`; undefined, the calls stay
# bare and act as whichever account is globally active. The mapping is not
# restated here — it resolves through gh-identity-guard.sh, the same code path
# the PreToolUse hook uses. `--resolve` reads the identity table only: no network
# call, no credential store, nothing to fail in a sandbox.
#
# Install: INSTALL.md in the skill directory above this one.

# The guard beside this file, where a symlinked or in-checkout copy finds it
# (`:A` resolves symlinks). Set GH_IDENTITY_GUARD before sourcing if you copied
# this file somewhere the guard is not a sibling.
_wt_gh_guard="${GH_IDENTITY_GUARD:-${0:A:h}/gh-identity-guard.sh}"
typeset -g _WT_GH_IDENTITY_GUARD="$_wt_gh_guard"
unset _wt_gh_guard

# Defined even when the guard is missing: the useful failure is a loud one at
# `wt pr`, where wt refuses to run. Skipping the definition would silently
# restore the bare `gh` this file exists to remove.
wt_gh_alias() {
  local resolved
  [[ -x "$_WT_GH_IDENTITY_GUARD" ]] || {
    print -u2 "wt_gh_alias: gh-identity guard not found at $_WT_GH_IDENTITY_GUARD"
    return 1
  }
  # `use:      gh <alias> ...` is the guard's documented line for this answer.
  resolved=$("$_WT_GH_IDENTITY_GUARD" --resolve "$1" 2>/dev/null) || return 1
  print -r -- "$resolved" | awk '$1 == "use:" { print $3; exit }'
}
