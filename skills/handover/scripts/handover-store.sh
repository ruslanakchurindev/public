#!/usr/bin/env bash
set -euo pipefail

# Stores handover artifacts outside the repo, at
# $HANDOVER_HOME/<repo-basename>-<path-hash>/<utc>.md (named: <name>-<utc>.md).
#
# `latest` and `list` scan the store rather than follow the latest symlinks:
# those track one save track each, so a named save leaves the unnamed pointer
# stale. They are written for humans browsing the store. Ordering comes from the
# UTC stamp in the filename, not mtime, which a copy or restore rewrites.
#
# Metadata overrides: HANDOVER_REPO_NAME / _WORKSPACE_NAME / _MODEL_NAME.

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
# Key the store off the repository, not the working directory: every linked
# worktree has a distinct `--show-toplevel`, which would scatter one repo's
# handovers into a store per worktree. The common git dir is shared by all of
# them, so it yields one stable per-repo key.
common="$(git -C "$abs" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$common" ]]; then
  # Relative to $abs in the main worktree (".git"), absolute in a linked one.
  # `pwd -P` on both: git already symlink-resolves the linked-worktree form, so
  # the main checkout must too or the two keys diverge. This also matches the old
  # --show-toplevel form, keeping existing stores stable.
  common="$(cd "$abs" && cd "$common" 2>/dev/null && pwd -P || printf '%s' "$common")"
  if [[ "$(basename "$common")" == ".git" ]]; then
    base="$(dirname "$common")"
  else
    # Bare repo or unusual gitdir: the common dir itself is the identity.
    base="$common"
  fi
else
  base="$abs"
fi
repo_name="${HANDOVER_REPO_NAME:-$(basename "$base")}"
workspace_name="${HANDOVER_WORKSPACE_NAME:-$(basename "$abs")}"
model_name="${HANDOVER_MODEL_NAME:-unknown}"
hash="$(printf '%s' "$base" | { shasum 2>/dev/null || sha1sum; } | cut -c1-8)"
dir="$store_root/$(basename "$base")-$hash"

# All worktrees of a repo share one store, so this is what tells artifacts apart
# inside it: recorded on save, matched on `latest`. `workspace-path` cannot serve
# — it is the save's working directory, possibly a subdir, and not
# symlink-resolved. Empty for a bare repo or a non-repo directory.
worktree_root="$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$worktree_root" && -d "$worktree_root" ]]; then
  worktree_root="$(cd "$worktree_root" && pwd -P)"
fi

# Artifact filenames are <utc>.md or <name>-<utc>.md, optionally -<n> on collision.
ts_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z(-[0-9]+)?\.md$'
stem_re='^(.+-)?([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z)(-([0-9]+))?$'

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
  printf 'workspace-path: %s\n' "$(metadata_value "$abs")"
  printf 'worktree: %s\n' "$(metadata_value "$worktree_root")"
  printf 'model: %s\n' "$(metadata_value "$model_name")"
  printf 'name: %s\n' "$(metadata_value "${name:-default}")"
  printf -- '-->\n\n'
}

# Sub-second mtime, or 0 where the platform won't give one. Tiebreak only, so a
# copy that rewrites mtimes cannot reorder distinct seconds.
mtime_key() {
  local value
  value="$(stat -f '%Fm' "$1" 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] || value="$(stat -c '%.9Y' "$1" 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] || value=0
  printf '%s' "$value"
}

# Sort key: "<stamp>\t<mtime>\t<collision-n>\t<path>". The filename stamp is the
# durable part; two saves in the same second need the tiebreaks, and the -<n>
# counter is claimed per filename so it cannot order an unnamed save against a
# named one -- sub-second mtime can. A file with no stamp was dropped in by hand:
# order it by mtime rather than hide it.
artifact_key() {
  local file="$1" stem ts n
  stem="$(basename "$file")"
  stem="${stem%.md}"
  if [[ "$stem" =~ $stem_re ]]; then
    ts="${BASH_REMATCH[2]}"
    n="${BASH_REMATCH[4]:-0}"
  else
    ts="$(date -u -r "$file" +%Y-%m-%dT%H%M%SZ 2>/dev/null || printf '0000-00-00T000000Z')"
    n=0
  fi
  printf '%s\t%s\t%s\t%s\n' "$ts" "$(mtime_key "$file")" "$n" "$file"
}

# Every artifact in the store, newest first. Unnamed invocations pool named and
# unnamed artifacts together so "the latest handover" has one answer; --name
# narrows to that track. Returns 1 when the store holds nothing.
collect_artifacts() {
  shopt -s nullglob
  local files=() out=() file base_file
  if [[ -n "$name" ]]; then
    files=( "$dir/$name-"*.md )
  else
    files=( "$dir"/*.md )
  fi
  # bash 3.2 treats "${files[@]}" on an empty array as an unbound variable.
  [[ ${#files[@]} -gt 0 ]] || return 1
  for file in "${files[@]}"; do
    base_file="$(basename "$file")"
    [[ "$base_file" == latest*.md ]] && continue
    # The remainder after "<name>-" must be exactly a timestamp, else name
    # "sprint" would also match "sprint-2026"'s files.
    if [[ -n "$name" ]]; then
      [[ "${base_file#"$name"-}" =~ $ts_re ]] || continue
    fi
    [[ -f "$file" && ! -L "$file" ]] || continue
    out+=( "$(artifact_key "$file")" )
  done
  [[ ${#out[@]} -gt 0 ]] || return 1
  printf '%s\n' "${out[@]}" | LC_ALL=C sort -t"$(printf '\t')" -k1,1r -k2,2nr -k3,3nr
}

no_artifacts_error() {
  if [[ -n "$name" ]]; then
    printf 'error: no handover artifacts named %s for %s\n' "$name" "$base" >&2
  else
    printf 'error: no handover artifacts for %s\n' "$base" >&2
  fi
  exit 1
}

# One metadata field from an artifact's header, if it has one.
artifact_field() {
  local file="$1" key="$2" line count=0
  while IFS= read -r line; do
    count=$((count + 1))
    [[ $count -gt 20 ]] && break
    case "$line" in
      '-->'*) break ;;
      "$key: "*)
        printf '%s' "${line#"$key": }"
        return 0
        ;;
    esac
  done < "$file"
  return 1
}

# The worktree an artifact was produced in. Falls back to workspace-path for
# artifacts written before the worktree field existed.
artifact_worktree() {
  local file="$1" value
  value="$(artifact_field "$file" worktree || true)"
  if [[ -z "$value" || "$value" == unknown ]]; then
    value="$(artifact_field "$file" workspace-path || true)"
  fi
  [[ -n "$value" && "$value" != unknown ]] || return 1
  printf '%s' "$value"
}

from_this_worktree() {
  local file="$1" value resolved
  [[ -n "$worktree_root" ]] || return 1
  value="$(artifact_field "$file" worktree || true)"
  if [[ -n "$value" && "$value" != unknown ]]; then
    # Already a resolved worktree root: exact match, nothing to infer.
    [[ "$value" == "$worktree_root" ]]
    return
  fi
  # Written before the worktree field existed. Ask git which worktree owns
  # workspace-path; a prefix test would not do, since worktrees are routinely
  # nested inside the main checkout and the parent would claim their handovers.
  # A gone directory leaves nothing to resolve — use the repo-wide fallback.
  value="$(artifact_field "$file" workspace-path || true)"
  [[ -n "$value" && "$value" != unknown && -d "$value" ]] || return 1
  resolved="$(git -C "$value" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$resolved" ]] || return 1
  resolved="$(cd "$resolved" && pwd -P)"
  [[ "$resolved" == "$worktree_root" ]]
}

# Falling back to another worktree's handover is correct but not obvious --
# branch, HEAD and uncommitted work are per-worktree. Say so on stderr, so stdout
# stays a bare path.
report_fallback() {
  local file="$1" value presence
  [[ -n "$worktree_root" ]] || return 0
  if ! value="$(artifact_worktree "$file")"; then
    printf 'note: newest handover for this repo records no originating worktree\n' >&2
    return 0
  fi
  if [[ -d "$value" ]]; then
    presence="still present"
  else
    presence="no longer present"
  fi
  printf 'note: no handover from this worktree (%s); using the newest for this repo, produced in %s (%s)\n' \
    "$worktree_root" "$value" "$presence" >&2
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
    # Claim the name with a hardlink: ln fails if the target exists, so the
    # published name only appears fully written and two concurrent same-second
    # saves can never resolve to the same file.
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
    # Informational only -- resolution scans the store rather than reading these.
    ln -sfn "$(basename "$file")" "$(latest_link)"
    printf '%s\n' "$file"
    ;;
  latest)
    harden_existing_dir
    sorted="$(collect_artifacts)" || no_artifacts_error
    newest=""
    chosen=""
    while IFS="$(printf '\t')" read -r _ts _mtime _n file; do
      [[ -n "$newest" ]] || newest="$file"
      # --name is already an explicit thread selector; don't second-guess it
      # with a worktree preference.
      [[ -n "$name" ]] && break
      if from_this_worktree "$file"; then
        chosen="$file"
        break
      fi
    done < <(printf '%s\n' "$sorted")
    if [[ -z "$chosen" ]]; then
      chosen="$newest"
      [[ -n "$name" ]] || report_fallback "$chosen"
    fi
    printf '%s\n' "$chosen"
    ;;
  list)
    harden_existing_dir
    sorted="$(collect_artifacts)" || no_artifacts_error
    printf '%s\n' "$sorted" | cut -f4-
    ;;
  *)
    usage
    ;;
esac
