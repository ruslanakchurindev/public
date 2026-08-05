# caf — manage one macOS caffeinate process across terminals.
#   caf       unlimited (replaces the current session)
#   caf N     N hours (replaces/resets the current session)
#   decaf     stop

typeset -g _CAF_STATE_DIR="${TMPDIR:-/tmp}"
_CAF_STATE_DIR="${_CAF_STATE_DIR%/}/caf-$UID"
typeset -g _CAF_PID_FILE="$_CAF_STATE_DIR/pid"
typeset -g _CAF_MAX_HOURS=596523 # floor(INT32_MAX / 3600)

_caf_usage() {
  echo "usage: caf [positive-hours]   (use decaf to stop)"
  return 1
}

_caf_state_dir() {
  local create="${1:-0}"
  if [[ -L "$_CAF_STATE_DIR" || ( -e "$_CAF_STATE_DIR" && ! -d "$_CAF_STATE_DIR" ) ]]; then
    echo "caf: unsafe state directory: $_CAF_STATE_DIR" >&2
    return 2
  fi
  if [[ ! -d "$_CAF_STATE_DIR" ]]; then
    (( create )) || return 1
    # A concurrent caf may create it first. Revalidate below rather than
    # treating the losing mkdir as fatal.
    (umask 077; mkdir "$_CAF_STATE_DIR") 2>/dev/null || :
  fi
  if [[ -L "$_CAF_STATE_DIR" || ! -d "$_CAF_STATE_DIR" || ! -O "$_CAF_STATE_DIR" ]] ||
      ! chmod 700 "$_CAF_STATE_DIR"; then
    echo "caf: unsafe state directory: $_CAF_STATE_DIR" >&2
    return 2
  fi
}

_caf_track() {
  _caf_state_dir 1 || return
  [[ ! -L "$_CAF_PID_FILE" ]] &&
    (umask 077; print -r -- "$1" >| "$_CAF_PID_FILE") &&
    chmod 600 "$_CAF_PID_FILE"
}

# Print the PID only when the file still names a caffeinate process.
_caf_pid() {
  local state_rc
  _caf_state_dir
  state_rc=$?
  (( state_rc == 1 )) && return 1
  (( state_rc == 0 )) || return "$state_rc"
  if [[ -L "$_CAF_PID_FILE" || ( -e "$_CAF_PID_FILE" && ( ! -f "$_CAF_PID_FILE" || ! -O "$_CAF_PID_FILE" ) ) ]]; then
    echo "caf: unsafe PID file: $_CAF_PID_FILE" >&2
    return 2
  fi
  [[ -f "$_CAF_PID_FILE" ]] || return 1

  local pid
  read -r pid < "$_CAF_PID_FILE" 2>/dev/null || {
    rm -f -- "$_CAF_PID_FILE"
    return 1
  }
  if [[ "$pid" == <-> ]] && (( pid > 0 )) &&
      /usr/bin/pgrep -F "$_CAF_PID_FILE" -x caffeinate >/dev/null 2>&1; then
    print -r -- "$pid"
    return 0
  fi
  rm -f -- "$_CAF_PID_FILE"
  return 1
}

_caf_stop() {
  local quiet="${1:-0}" pid rc
  pid=$(_caf_pid)
  rc=$?
  if (( rc == 1 )); then
    (( quiet )) || echo "caf: not caffeinating"
    return 0
  fi
  (( rc == 0 )) || return 1

  if ! kill "$pid" 2>/dev/null &&
      /usr/bin/pgrep -F "$_CAF_PID_FILE" -x caffeinate >/dev/null 2>&1; then
    echo "caf: failed to stop caffeinate PID $pid" >&2
    return 1
  fi
  rm -f -- "$_CAF_PID_FILE"
  (( quiet )) || echo "caf: stopped (PID $pid)"
}

_caf_start() {
  local hours="$1" hours_value="$2" pid
  local -a args=(-di)
  [[ -n "$hours" ]] && args+=(-t "$(( hours_value * 3600 ))")

  nohup /usr/bin/caffeinate "${args[@]}" </dev/null >/dev/null 2>&1 &!
  pid=$!
  if ! _caf_track "$pid"; then
    kill "$pid" 2>/dev/null
    echo "caf: could not record caffeinate PID" >&2
    return 1
  fi
  echo "caf: caffeinating${hours:+ for ${hours}h} (PID $pid)"
}

caf() {
  local hours="${1-}" hours_value=0
  if (( $# > 1 )) || [[ -n "$hours" && "$hours" != <-> ]] || (( ${#hours} > 6 )); then
    _caf_usage
    return 1
  fi
  if [[ -n "$hours" ]]; then
    hours_value=$(( 10#$hours ))
    (( hours_value > 0 && hours_value <= _CAF_MAX_HOURS )) || {
      _caf_usage
      return 1
    }
  fi

  _caf_stop 1 || return 1
  _caf_start "$hours" "$hours_value"
}

decaf() {
  (( $# == 0 )) || { echo "usage: decaf"; return 1; }
  _caf_stop 0
}
