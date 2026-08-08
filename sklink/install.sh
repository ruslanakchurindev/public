#!/usr/bin/env bash
set -euo pipefail

# Put sklink on your PATH.
#
# Creates a symlink to this checkout's `sklink` in a bin directory (default
# ~/.local/bin). Nothing is copied: the command keeps pointing at the checkout,
# so `git pull` updates the installed tool.
#
#   ./install.sh                        # ~/.local/bin/sklink
#   ./install.sh --name myskills        # install under a different command name
#   ./install.sh --bin-dir ~/bin        # install somewhere else
#   ./install.sh --uninstall            # remove the symlink again
#
# Idempotent, and it never overwrites something it didn't create — pass --force
# if you mean to replace an existing file.

tool_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
self="${0##*/}"

die() { printf '%s: %s\n' "$self" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$self — put sklink on your PATH.

  $self [--bin-dir <dir>] [--name <command>] [--force]
  $self --uninstall [--bin-dir <dir>] [--name <command>]

  --bin-dir <dir>   where to create the symlink (default: ~/.local/bin)
  --name <command>  what to call the command (default: sklink)
  --force           replace an existing file at the target
  --uninstall       remove a symlink that points at this checkout

The symlink points back at this checkout, so updating the checkout updates the
installed command. Your manifest and state are never touched.
EOF
}

bin_dir="$HOME/.local/bin"
name="sklink"
force=0
uninstall=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir) [[ -n "${2:-}" ]] || die "--bin-dir needs a directory"; bin_dir="${2/#\~/$HOME}"; shift 2;;
    --name)    [[ -n "${2:-}" ]] || die "--name needs a command name"; name="$2"; shift 2;;
    --force)   force=1; shift;;
    --uninstall) uninstall=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown argument: $1 (try: $self --help)";;
  esac
done

source_cli="$tool_dir/sklink"
target="$bin_dir/$name"

# Catch the "copied one file out of the checkout" case here, with a message that
# names the missing piece — rather than letting the CLI fail later looking for a
# sibling reconciler that was never installed alongside it.
[[ -f "$source_cli" ]]           || die "not found: $source_cli (run this script from the sklink directory)"
[[ -f "$tool_dir/sklink-sync" ]] || die "not found: $tool_dir/sklink-sync (sklink needs both files side by side)"

if [[ "$uninstall" == 1 ]]; then
  if [[ ! -L "$target" ]]; then
    [[ -e "$target" ]] && die "not a symlink, refusing to remove: $target"
    printf 'nothing to remove: %s\n' "$target"
    exit 0
  fi
  # Only ever remove a link we would have created. Anything else is someone
  # else's file that happens to share the name.
  current="$(readlink "$target")"
  [[ "$current" == "$source_cli" ]] || die "points elsewhere, refusing to remove: $target -> $current"
  rm "$target"
  printf 'removed %s\n' "$target"
  printf 'your manifest and state were left alone; see the README to remove those too.\n'
  exit 0
fi

mkdir -p "$bin_dir" || die "cannot create $bin_dir"

if [[ -L "$target" ]]; then
  current="$(readlink "$target")"
  if [[ "$current" == "$source_cli" ]]; then
    printf 'already installed: %s -> %s\n' "$target" "$source_cli"
  elif [[ "$force" == 1 ]]; then
    ln -sfn "$source_cli" "$target"
    printf 'replaced %s (was -> %s)\n' "$target" "$current"
  else
    die "$target already points at $current (use --force to replace it)"
  fi
elif [[ -e "$target" ]]; then
  [[ "$force" == 1 ]] || die "$target already exists and is not a symlink (use --force to replace it)"
  rm -f "$target"
  ln -sfn "$source_cli" "$target"
  printf 'replaced %s -> %s\n' "$target" "$source_cli"
else
  ln -sfn "$source_cli" "$target"
  printf 'installed %s -> %s\n' "$target" "$source_cli"
fi

case ":${PATH:-}:" in
  *":$bin_dir:"*) ;;
  *)
    case "$(basename "${SHELL:-sh}")" in
      zsh)  rc="~/.zshrc";;
      bash) rc="~/.bashrc";;
      *)    rc="your shell's startup file";;
    esac
    printf '\nwarning: %s is not on your PATH.\n' "$bin_dir"
    printf 'add this to %s, then restart your shell:\n' "$rc"
    printf '  export PATH="%s:$PATH"\n' "${bin_dir/#$HOME/\$HOME}"
    ;;
esac

printf '\nnext:\n'
printf '  %s add <skill-dir> --user   # register a skill everywhere\n' "$name"
printf '  %s doctor                   # see what is linked where\n' "$name"
