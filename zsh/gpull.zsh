# gpull — fetch every Git repository immediately below ~/Code and safely
# fast-forward its local main branch without switching branches.
#
# Dirty checked-out main branches, missing main branches, and non-fast-forward
# histories are reported and skipped. Operational failures are reported and make
# the aggregate command fail. Repositories run in parallel while their output is
# printed in directory order.

typeset -g _GPULL_CODE_BASE="${_GPULL_CODE_BASE-$HOME/Code}"
typeset -g _GPULL_GIT="${_GPULL_GIT-$(command -v git)}"

# Return 0 for success, 1 for a safe skip, and 2 for an operational failure.
_gpull_one() {
  local dir="$1"
  local repo="${dir:t}"
  local current before remote worktree_status probe_rc ancestry_rc

  printf '→ %s\n' "$repo"

  if ! "$_GPULL_GIT" -C "$dir" fetch --quiet origin; then
    printf '    fetch failed\n'
    return 2
  fi

  if before=$("$_GPULL_GIT" -C "$dir" rev-parse --verify --quiet refs/heads/main 2>/dev/null); then
    :
  else
    probe_rc=$?
    if (( probe_rc == 1 )); then
      printf '    no local main — skipped\n'
      return 1
    fi
    printf '    could not inspect local main — failed\n'
    return 2
  fi
  if ! remote=$("$_GPULL_GIT" -C "$dir" rev-parse --verify refs/remotes/origin/main 2>/dev/null); then
    printf '    no origin/main — failed\n'
    return 2
  fi

  if current=$("$_GPULL_GIT" -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    :
  else
    probe_rc=$?
    if (( probe_rc == 1 )); then
      current='detached HEAD'
    else
      printf '    could not inspect HEAD — failed\n'
      return 2
    fi
  fi

  if [[ "$current" == main ]]; then
    if ! worktree_status=$("$_GPULL_GIT" -C "$dir" status --porcelain --untracked-files=normal); then
      printf '    could not inspect working tree — failed\n'
      return 2
    fi
    if [[ -n "$worktree_status" ]]; then
      printf '    dirty main — skipped\n'
      return 1
    fi
  fi

  if [[ "$before" == "$remote" ]]; then
    if [[ "$current" == main ]]; then
      printf '    up to date\n'
    else
      printf '    up to date (on %s)\n' "$current"
    fi
    return 0
  fi

  if "$_GPULL_GIT" -C "$dir" merge-base --is-ancestor "$before" "$remote" 2>/dev/null; then
    ancestry_rc=0
  else
    ancestry_rc=$?
  fi
  if (( ancestry_rc != 0 )); then
    if (( ancestry_rc != 1 )); then
      printf '    could not compare main with origin/main — failed\n'
      return 2
    fi
    if "$_GPULL_GIT" -C "$dir" merge-base --is-ancestor "$remote" "$before" 2>/dev/null; then
      printf '    local main ahead of origin/main — skipped (on %s)\n' "$current"
    else
      ancestry_rc=$?
      if (( ancestry_rc != 1 )); then
        printf '    could not compare main with origin/main — failed\n'
        return 2
      fi
      printf '    local main diverged from origin/main — skipped (on %s)\n' "$current"
    fi
    return 1
  fi

  if [[ "$current" == main ]]; then
    if ! "$_GPULL_GIT" -C "$dir" merge --quiet --ff-only refs/remotes/origin/main; then
      printf '    fast-forward failed\n'
      return 2
    fi
    printf '    pulled %s..%s\n' "${before[1,7]}" "${remote[1,7]}"
    return 0
  fi

  if ! "$_GPULL_GIT" -C "$dir" branch --quiet --force main refs/remotes/origin/main; then
    printf '    could not update local main — failed (on %s)\n' "$current"
    return 2
  fi
  printf '    updated main %s..%s (on %s)\n' \
    "${before[1,7]}" "${remote[1,7]}" "$current"
}

gpull() {
  setopt local_options local_traps no_err_exit no_monitor no_bg_nice

  if [[ -z "$_GPULL_GIT" ]]; then
    printf 'gpull: git is required\n' >&2
    return 2
  fi
  if [[ -z "$_GPULL_CODE_BASE" ]]; then
    printf 'gpull: _GPULL_CODE_BASE must not be empty\n' >&2
    return 2
  fi
  if [[ ! -d "$_GPULL_CODE_BASE" || ! -r "$_GPULL_CODE_BASE" || ! -x "$_GPULL_CODE_BASE" ]]; then
    printf 'gpull: _GPULL_CODE_BASE is not a readable directory: %s\n' \
      "$_GPULL_CODE_BASE" >&2
    return 2
  fi

  local jobs="${_GPULL_JOBS:-8}"
  if [[ "$jobs" != <-> ]] || (( 10#$jobs < 1 )); then
    printf 'gpull: _GPULL_JOBS must be a positive integer (got %s)\n' "$jobs" >&2
    return 2
  fi
  jobs=$(( 10#$jobs ))

  local -a dirs pids
  local dir
  for dir in "$_GPULL_CODE_BASE"/*(ND-/); do
    [[ -d "$dir/.git" || -f "$dir/.git" ]] || continue
    dirs+=("$dir")
  done

  local total=${#dirs[@]}
  if (( total == 0 )); then
    printf 'no repos under %s\n' "$_GPULL_CODE_BASE"
    return 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/gpull.XXXXXXXX") || {
    printf 'gpull: could not create temporary directory\n' >&2
    return 2
  }
  local trap_owner=$ZSH_SUBSHELL
  TRAPINT() {
    (( ZSH_SUBSHELL == trap_owner )) || return 130
    if [[ -n "$tmpdir" ]]; then
      command rm -rf -- "$tmpdir" || :
      tmpdir=''
    fi
    return 130
  }

  {
    local worker_limit=$jobs
    (( worker_limit > total )) && worker_limit=$total

    local i=0 idx pid worker_rc
    local running=0 slot=1 scan_slot=1 checked reaped
    for dir in "${dirs[@]}"; do
      if (( running < worker_limit )); then
        slot=$(( running + 1 ))
        running=$(( running + 1 ))
      else
        reaped=0
        while (( ! reaped )); do
          for (( checked = 0; checked < worker_limit; checked++ )); do
            slot=$(( (scan_slot + checked - 1) % worker_limit + 1 ))
            pid=${pids[slot]}
            if ! kill -0 "$pid" 2>/dev/null; then
              if ! wait "$pid"; then
                printf 'gpull: worker %s exited without a complete result\n' "$pid" >&2
              fi
              scan_slot=$(( slot % worker_limit + 1 ))
              reaped=1
              break
            fi
          done
          if (( ! reaped )) && ! sleep 0.02; then
            printf 'gpull: scheduler sleep failed\n' >&2
            return 2
          fi
        done
      fi

      idx=$(printf '%04d' "$i")
      {
        worker_rc=2
        if {
          if _gpull_one "$dir"; then
            worker_rc=0
          else
            worker_rc=$?
          fi
        } >"$tmpdir/$idx.out" 2>&1; then
          :
        else
          worker_rc=2
        fi
        if ! printf '%d\n' "$worker_rc" >"$tmpdir/$idx.rc"; then
          return 2
        fi
      } &
      pids[$slot]="$!"
      i=$(( i + 1 ))
    done
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        printf 'gpull: worker %s exited without a complete result\n' "$pid" >&2
      fi
    done

    local ok=0 skip=0 fail=0 rc artifact_failed
    for (( i = 0; i < total; i++ )); do
      idx=$(printf '%04d' "$i")
      rc=2
      artifact_failed=0
      if [[ -s "$tmpdir/$idx.out" ]]; then
        if ! command cat "$tmpdir/$idx.out"; then
          printf '→ %s\n    could not read worker output — failed\n' "${dirs[i + 1]:t}"
          artifact_failed=1
        fi
      else
        printf '→ %s\n    worker produced no output — failed\n' "${dirs[i + 1]:t}"
        artifact_failed=1
      fi

      if [[ -f "$tmpdir/$idx.rc" ]] && IFS= read -r worker_rc < "$tmpdir/$idx.rc"; then
        case "$worker_rc" in
          0|1|2) rc=$worker_rc ;;
          *) artifact_failed=1 ;;
        esac
      else
        artifact_failed=1
      fi
      if (( artifact_failed )); then
        rc=2
      fi
      case "$rc" in
        0) ok=$(( ok + 1 )) ;;
        1) skip=$(( skip + 1 )) ;;
        *) fail=$(( fail + 1 )) ;;
      esac
    done

    printf '\n%d ok  %d skipped  %d failed  (jobs=%d)\n' "$ok" "$skip" "$fail" "$jobs"
    (( fail == 0 ))
  } always {
    if [[ -n "$tmpdir" ]]; then
      command rm -rf -- "$tmpdir" || :
      tmpdir=''
    fi
  }
}
