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
#   ./install.sh --no-config            # don't create a starter manifest
#   ./install.sh --uninstall            # remove the symlink again
#
# It also creates a starter manifest from the shipped template, unless one is
# already there — your registry is user data and is never overwritten, here or
# anywhere else.
#
# Idempotent, and it never overwrites something it didn't create — pass --force
# if you mean to replace an existing file.

tool_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
self="${0##*/}"

die() { printf '%s: %s\n' "$self" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$self — put sklink on your PATH.

  $self [--bin-dir <dir>] [--name <command>] [--force] [--no-config]
  $self --uninstall [--bin-dir <dir>] [--name <command>]

  --bin-dir <dir>   where to create the symlink (default: ~/.local/bin)
  --name <command>  what to call the command (default: sklink)
  --force           replace an existing file at the target
  --no-config       skip creating a starter manifest
  --uninstall       remove a symlink that points at this checkout

The symlink points back at this checkout, so updating the checkout updates the
installed command. An existing manifest is never overwritten, and your state is
never touched.
EOF
}

bin_dir="$HOME/.local/bin"
name="sklink"
force=0
uninstall=0
make_config=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir) [[ -n "${2:-}" ]] || die "--bin-dir needs a directory"; bin_dir="${2/#\~/$HOME}"; shift 2;;
    --name)    [[ -n "${2:-}" ]] || die "--name needs a command name"; name="$2"; shift 2;;
    --force)   force=1; shift;;
    --no-config) make_config=0; shift;;
    --uninstall) uninstall=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown argument: $1 (try: $self --help)";;
  esac
done

source_cli="$tool_dir/sklink"
target="$bin_dir/$name"

# Catch the "copied one file out of the checkout" case here, with a message that
# names the missing piece — rather than letting the CLI fail later looking for a
# sibling it was never installed alongside.
[[ -f "$source_cli" ]]                 || die "not found: $source_cli (run this script from the sklink directory)"
[[ -f "$tool_dir/sklink-sync" ]]       || die "not found: $tool_dir/sklink-sync (sklink needs both files side by side)"
[[ -f "$tool_dir/templates/manifest" ]] || die "not found: $tool_dir/templates/manifest (sklink writes new manifests from it)"

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

# Create the registry from the shipped template so a fresh install has a file to
# read (and to learn the format from). `init` is a no-op when one already
# exists, so re-running the installer can never cost anyone their manifest.
if [[ "$make_config" == 1 ]]; then
  # Through the symlink we just made, so the template it writes talks about the
  # command name you chose rather than the one in this repo.
  bash "$target" init || printf 'warning: could not create the manifest (run: %s init)\n' "$name" >&2
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
printf '  %s add <skill-dir> --user   # register a skill for every agent\n' "$name"
printf '  %s list                     # what is registered\n' "$name"
printf '  %s doctor                   # what is actually on disk\n' "$name"
