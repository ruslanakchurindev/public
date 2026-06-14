#!/usr/bin/env bash
set -euo pipefail

# Stores handover artifacts outside the repo so they never pollute git status
# or get committed. Layout: $HANDOVER_HOME/<repo-basename>-<path-hash>/<utc>.md
# with latest symlinks per repo. Named handovers use <name>-<utc>.md and
# latest-<name>.md.
#
# Optional metadata overrides written into each artifact:
#   HANDOVER_REPO_NAME / HANDOVER_WORKSPACE_NAME / HANDOVER_MODEL_NAME

umask 077

store_root="${HANDOVER_HOME:-$HOME/.handovers}"

usage() {
  cat >&2 <<'EOF'
usage: handover-store.sh <command> [target-dir] [--name NAME]
  path    print (and create) the store dir for target-dir's repo
  save    read artifact markdown on stdin, save it timestamped, update
          latest symlink(s), print the saved file path
  latest  print the path of the newest artifact
  list    list artifact paths, newest first
target-dir defaults to "."
NAME must be 1-64 chars starting with a letter or digit, then letters,
digits, dots, underscores, or hyphens. Names starting with "latest" are reserved.
EOF
  exit 2
}

cmd="${1:-}"
[[ $# -gt 0 ]] && shift || true

target="."
name=""
name_set=0

if [[ $# -gt 0 && "$1" != --* ]]; then
  target="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || { printf 'error: --name requires a value\n' >&2; exit 2; }
      name="$2"
      name_set=1
      shift 2
      ;;
    --name=*)
      name="${1#--name=}"
      name_set=1
      shift
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

[[ -d "$target" ]] || { printf 'error: not a directory: %s\n' "$target" >&2; exit 2; }
if [[ $name_set -eq 1 && -z "$name" ]]; then
  printf 'error: --name requires a non-empty value\n' >&2
  exit 2
fi
if [[ -n "$name" && ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  printf 'error: invalid handover name: %s\n' "$name" >&2
  printf 'hint: use 1-64 chars starting with a letter or digit, then letters, digits, dots, underscores, or hyphens\n' >&2
  exit 2
fi
if [[ -n "$name" && "$name" == latest* ]]; then
  printf 'error: names starting with "latest" are reserved\n' >&2
  exit 2
fi

abs="$(cd "$target" && pwd)"
base="$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$abs")"
repo_name="${HANDOVER_REPO_NAME:-$(basename "$base")}"
workspace_name="${HANDOVER_WORKSPACE_NAME:-$(basename "$abs")}"
model_name="${HANDOVER_MODEL_NAME:-unknown}"
hash="$(printf '%s' "$base" | { shasum 2>/dev/null || sha1sum; } | cut -c1-8)"
dir="$store_root/$(basename "$base")-$hash"

ensure_store_dir() {
  mkdir -p "$store_root" "$dir"
  chmod 700 "$store_root" "$dir" 2>/dev/null || true
}

harden_existing_dir() {
  [[ -d "$store_root" ]] && chmod 700 "$store_root" 2>/dev/null || true
  [[ -d "$dir" ]] && chmod 700 "$dir" 2>/dev/null || true
}

latest_link() {
  if [[ -n "$name" ]]; then
    printf '%s/latest-%s.md\n' "$dir" "$name"
  else
    printf '%s/latest.md\n' "$dir"
  fi
}

metadata_value() {
  local value="${1:-}"
  [[ -n "$value" ]] || value="unknown"
  printf '%s' "$value" | tr '\r\n' '  ' | sed 's/-->/-- >/g'
}

write_metadata_header() {
  printf '<!-- handover-metadata\n'
  printf 'generated: %s\n' "$generated"
  printf 'repo: %s\n' "$(metadata_value "$repo_name")"
  printf 'workspace: %s\n' "$(metadata_value "$workspace_name")"
  printf 'model: %s\n' "$(metadata_value "$model_name")"
  printf 'name: %s\n' "$(metadata_value "${name:-default}")"
  printf -- '-->\n\n'
}

case "$cmd" in
  path)
    ensure_store_dir
    printf '%s\n' "$dir"
    ;;
  save)
    ensure_store_dir
    generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    stamp="$(printf '%s' "$generated" | tr -d ':')"
    input="$(mktemp "$dir/.handover-input.XXXXXX")"
    output="$(mktemp "$dir/.handover-output.XXXXXX")"
    trap 'rm -f "$input" "$output"' EXIT INT TERM HUP
    cat > "$input"
    if [[ ! -s "$input" ]]; then
      printf 'error: empty artifact on stdin\n' >&2
      exit 1
    fi
    { write_metadata_header; cat "$input"; } > "$output"
    chmod 600 "$output" 2>/dev/null || true
    if [[ -n "$name" ]]; then
      file="$dir/$name-$stamp.md"
    else
      file="$dir/$stamp.md"
    fi
    # Claim the final name with a hardlink: ln fails if the target exists, so
    # the published name only ever appears fully written and two concurrent
    # same-second saves can never resolve to the same file.
    n=1
    until ln "$output" "$file" 2>/dev/null; do
      n=$((n + 1))
      [[ $n -gt 1000 ]] && { printf 'error: too many collisions for timestamp %s\n' "$stamp" >&2; exit 1; }
      if [[ -n "$name" ]]; then
        file="$dir/$name-$stamp-$n.md"
      else
        file="$dir/$stamp-$n.md"
      fi
    done
    rm -f "$input" "$output"
    ln -sfn "$(basename "$file")" "$(latest_link)"
    printf '%s\n' "$file"
    ;;
  latest)
    harden_existing_dir
    link="$(latest_link)"
    if [[ -e "$link" ]]; then
      target_path="$(readlink "$link" 2>/dev/null || printf '%s' "$link")"
      if [[ "$target_path" = /* ]]; then
        printf '%s\n' "$target_path"
      else
        printf '%s/%s\n' "$dir" "$target_path"
      fi
    else
      if [[ -n "$name" ]]; then
        printf 'error: no handover artifacts named %s for %s\n' "$name" "$base" >&2
      else
        printf 'error: no handover artifacts for %s\n' "$base" >&2
      fi
      exit 1
    fi
    ;;
  list)
    harden_existing_dir
    if [[ ! -d "$dir" ]]; then
      printf 'error: no handover artifacts for %s\n' "$base" >&2
      exit 1
    fi
    shopt -s nullglob
    # Artifact timestamps are <YYYY>-<MM>-<DD>T<HHMMSS>Z, optionally -<n> on collision.
    ts_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z(-[0-9]+)?\.md$'
    if [[ -n "$name" ]]; then
      files=( "$dir/$name-"*.md )
    else
      files=( "$dir"/*.md )
    fi
    artifacts=()
    if [[ ${#files[@]} -gt 0 ]]; then
      for file in "${files[@]}"; do
        base_file="$(basename "$file")"
        [[ "$base_file" == latest*.md ]] && continue
        # For a named list the remainder after "<name>-" must be exactly a
        # timestamp, else name "sprint" would also match "sprint-2026"'s files.
        if [[ -n "$name" ]]; then
          [[ "${base_file#"$name"-}" =~ $ts_re ]] || continue
        fi
        [[ -f "$file" && ! -L "$file" ]] && artifacts+=( "$file" )
      done
    fi
    if [[ ${#artifacts[@]} -eq 0 ]]; then
      if [[ -n "$name" ]]; then
        printf 'error: no handover artifacts named %s for %s\n' "$name" "$base" >&2
      else
        printf 'error: no handover artifacts for %s\n' "$base" >&2
      fi
      exit 1
    fi
    ls -1t "${artifacts[@]}"
    ;;
  *)
    usage
    ;;
esac
