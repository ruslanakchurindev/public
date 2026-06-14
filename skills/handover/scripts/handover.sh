#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
store_script="$script_dir/handover-store.sh"
state_script="$script_dir/collect-workspace-state.sh"

usage() {
  cat <<'EOF'
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
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

parse_target_and_name() {
  target="."
  name_args=()

  if [[ $# -gt 0 && "$1" != --* ]]; then
    target="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ $# -ge 2 ]] || die "--name requires a value"
        name_args=( --name "$2" )
        shift 2
        ;;
      --name=*)
        name_args=( --name "${1#--name=}" )
        shift
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

cmd="${1:-}"
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
  -h|--help|help)
    usage
    ;;
  path)
    target="${1:-.}"
    [[ $# -le 1 ]] || die "path accepts at most one target-dir"
    exec "$store_script" path "$target"
    ;;
  save|latest|list)
    parse_target_and_name "$@"
    if [[ ${#name_args[@]} -gt 0 ]]; then
      exec "$store_script" "$cmd" "$target" "${name_args[@]}"
    else
      exec "$store_script" "$cmd" "$target"
    fi
    ;;
  state)
    target="${1:-.}"
    since="${2:-}"
    [[ $# -le 2 ]] || die "state accepts at most target-dir and since-ref"
    if [[ -n "$since" ]]; then
      exec "$state_script" "$target" "$since"
    else
      exec "$state_script" "$target"
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
