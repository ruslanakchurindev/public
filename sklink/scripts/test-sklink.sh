#!/usr/bin/env bash
# Hermetic tests for sklink and sklink-sync.
#
# Everything runs inside a throwaway mktemp workspace via the env overrides
# SKLINK_MANIFEST / SKLINK_ROOTS / XDG_CONFIG_HOME / XDG_STATE_HOME, so the real
# ~/.claude, ~/.codex, etc. are never touched. Run:
#
#   bash sklink/scripts/test-sklink.sh
#
# bash 3.2 compatible (macOS default). No associative arrays, no mapfile.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool_dir="$(cd "$script_dir/.." && pwd)"
LINKER="$tool_dir/sklink-sync"
CLI="$tool_dir/sklink"

# Bare `mktemp -d` on macOS ignores TMPDIR and uses the Darwin per-user temp
# dir, which a sandboxed shell may not be allowed to write. Unchecked, WS would
# be empty and every path below would silently resolve to the filesystem root
# (/src, /rootA, /log) — so honour TMPDIR and refuse to run without a workspace.
WS="$(mktemp -d "${TMPDIR:-/tmp}/sklink-test.XXXXXX")" || exit 1
[ -n "$WS" ] && [ -d "$WS" ] || { echo "cannot create temp workspace" >&2; exit 1; }
# Normalise the workspace path. macOS sets TMPDIR with a trailing slash, so WS
# arrives containing '//'. The CLI derives paths with `cd && pwd`, which collapses
# that, and a $HOME-under-WS test then compares a normalised path against a
# non-normalised $HOME and sees no match — failing on stock macOS but not where
# TMPDIR has no trailing slash.
WS="$(cd "$WS" && pwd)"
trap 'rm -rf "$WS"' EXIT

SRC="$WS/src"; ROOTA="$WS/rootA"; ROOTB="$WS/rootB"; PROJ="$WS/proj"
STATE="$WS/state"; MAN="$WS/manifest"; LOG="$WS/log"
ROOTS="$ROOTA $ROOTB"
mkdir -p "$SRC" "$ROOTA" "$ROOTB" "$PROJ" "$STATE"

n=0; fails=0
ok() { n=$((n+1)); printf '  ok %2d - %s\n' "$n" "$1"; }
no() { n=$((n+1)); fails=$((fails+1)); printf 'NOT OK %2d - %s\n' "$n" "$1"; }
check() { if eval "$1"; then ok "$2"; else no "$2 [$1]"; fi; }

mkskill() { mkdir -p "$1"; printf -- '---\nname: %s\n---\nbody\n' "$(basename "$1")" > "$1/SKILL.md"; }
writeman() { : > "$MAN"; for l in "$@"; do printf '%s\n' "$l" >> "$MAN"; done; }
islink()  { [ -L "$1" ] && [ -e "$1" ]; }
absent()  { [ ! -e "$1" ] && [ ! -L "$1" ]; }
realdir() { [ -d "$1" ] && [ ! -L "$1" ]; }

sync() { SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" bash "$LINKER" >"$LOG" 2>&1; }
cli()  { SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" bash "$CLI" "$@" >"$LOG" 2>&1; }

mkskill "$SRC/alpha"; mkskill "$SRC/beta"; mkskill "$SRC/gamma"
mkskill "$ROOTA/foreign"   # unmanaged skill that must always survive

echo "# 1. user-scope fans out to every root"
writeman "user alpha $SRC/alpha" "user beta $SRC/beta"
sync; check "[ $? -eq 0 ]" "sync exits 0"
check "islink '$ROOTA/alpha'" "rootA/alpha linked"
check "islink '$ROOTB/alpha'" "rootB/alpha linked"
check "islink '$ROOTB/beta'"  "rootB/beta linked"

echo "# 2. project-scope fans out to .claude and .codex only"
writeman "user alpha $SRC/alpha" "user beta $SRC/beta" "project:$PROJ gamma $SRC/gamma"
sync
check "islink '$PROJ/.claude/skills/gamma'" "proj/.claude gamma"
check "islink '$PROJ/.codex/skills/gamma'"  "proj/.codex gamma"
check "absent '$PROJ/.agents'"              "no empty .agents dir created"

echo "# 3. dropping a skill prunes only that link"
writeman "user alpha $SRC/alpha" "project:$PROJ gamma $SRC/gamma"
sync
check "absent '$ROOTA/beta'" "rootA/beta pruned"
check "absent '$ROOTB/beta'" "rootB/beta pruned"
check "islink '$ROOTA/alpha'" "rootA/alpha kept"
check "grep -q pruned '$LOG'" "prune reported"

echo "# 4. unmanaged (foreign) skill untouched"
check "realdir '$ROOTA/foreign'" "foreign survived"

echo "# 5. refuses to clobber a real (non-symlink) dir"
mkdir -p "$ROOTA/delta"
writeman "user alpha $SRC/alpha" "user delta $SRC/alpha"
sync; rc=$?
check "[ $rc -ne 0 ]" "sync exits non-zero on guard"
check "realdir '$ROOTA/delta'" "real dir delta preserved"
check "grep -q 'refusing to replace non-symlink' '$LOG'" "guard message"

echo "# 6. missing source warns and creates no link"
writeman "user alpha $SRC/alpha" "user ghost $WS/nope"
sync; rc=$?
check "[ $rc -ne 0 ]" "sync exits non-zero on missing source"
check "absent '$ROOTA/ghost'" "no dangling link for missing source"
check "grep -q 'source not found' '$LOG'" "missing-source message"

echo "# 7. clean reset, then: sklink add"
rm -rf "$ROOTA/delta"
writeman "user alpha $SRC/alpha"
sync
cli add "$SRC/gamma" --user; check "[ $? -eq 0 ]" "sklink add exits 0"
check "awk '\$1==\"user\"&&\$2==\"gamma\"{f=1}END{exit f?0:1}' '$MAN'" "manifest gained gamma"
check "islink '$ROOTA/gamma'" "add linked rootA/gamma"
check "islink '$ROOTB/gamma'" "add linked rootB/gamma"

echo "# 8. sklink rm removes from manifest and prunes"
cli rm gamma; check "[ $? -eq 0 ]" "sklink rm exits 0"
check "! grep -q gamma '$MAN'" "manifest lost gamma"
check "absent '$ROOTA/gamma'" "rm pruned rootA/gamma"

echo "# 9. sklink add rejects a duplicate"
cli add "$SRC/alpha" --user; check "[ $? -ne 0 ]" "duplicate rejected"

echo "# 10. doctor flags BAD source and DANGLING link"
writeman "user alpha $SRC/alpha" "user gamma $SRC/gamma"
sync
rm -rf "$SRC/gamma"          # break the source out from under the link
cli doctor
check "grep -q BAD '$LOG'" "doctor reports BAD source"
check "grep -q DANGLING '$LOG'" "doctor reports DANGLING link"
check "grep -qF '$MAN' '$LOG'" "doctor names the manifest in use"

echo "# 11. idempotent: second sync is a no-op"
mkskill "$SRC/gamma"
writeman "user alpha $SRC/alpha"
sync                          # converge
sync; rc=$?                   # again
check "[ $rc -eq 0 ]" "repeat sync exits 0"
check "! grep -q pruned '$LOG'" "repeat sync prunes nothing"

echo "# 12. CLI finds its reconciler through a PATH symlink"
# The CLI is installed on PATH as a symlink (~/.local/bin/sklink). It must
# follow the link back to its real directory to find the sibling sklink-sync,
# not look for it next to the symlink. Copy both scripts into a standalone
# directory, symlink a bin entry to the CLI, and sync through the symlink:
# a successful sync is only possible if the sibling was resolved.
TOOL="$WS/tool"; mkdir -p "$TOOL" "$WS/bin"
cp "$CLI" "$TOOL/sklink"; cp "$LINKER" "$TOOL/sklink-sync"
chmod +x "$TOOL/sklink" "$TOOL/sklink-sync"
ln -s "$TOOL/sklink" "$WS/bin/sklink"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$WS/bin/sklink" sync >"$LOG" 2>&1
check "[ $? -eq 0 ]" "symlinked CLI sync exits 0"
check "islink '$ROOTA/alpha'" "symlinked CLI reconciled links"
check "! grep -qi 'no such file' '$LOG'" "no missing-reconciler error"

echo "# 12b. the CLI calls itself whatever the PATH symlink is called"
# The command name is a symlink decision, not a string baked into the script,
# so help and errors must follow it. (--help also used to print past the usage
# block into the script's internal comments; it now has a real usage function.)
ln -s "$TOOL/sklink" "$WS/bin/myskills"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$WS/bin/myskills" --help >"$LOG" 2>&1
check "grep -q '^myskills — ' '$LOG'" "help announces the invoked name"
check "grep -q '  myskills doctor' '$LOG'" "usage lines use the invoked name"
check "! grep -q 'BASH_SOURCE' '$LOG'" "help leaks no internal comments"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$WS/bin/myskills" bogus >"$LOG" 2>&1
check "grep -q '^myskills: unknown command' '$LOG'" "errors are prefixed with the invoked name"

echo "# 13. sklink add collapses \$HOME to a clean ~ (no literal backslash-tilde)"
# Regression: collapse_home used a '\~' replacement string that bash 3.2 keeps
# literal, so `sklink add` on a $HOME-relative source/repo wrote 'project:\~/...'
# and the reconciler's expand_tilde couldn't resolve it. Earlier tests never
# caught this because their sources live under $WS, never under $HOME.
FAKEHOME="$WS/home"; mkskill "$FAKEHOME/proj/myskill"
HOME="$FAKEHOME" SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$CLI" add "$FAKEHOME/proj/myskill" --user >"$LOG" 2>&1
check "[ $? -eq 0 ]" "add under \$HOME exits 0"
check "grep -q '~/proj/myskill' '$MAN'" "source collapsed to ~/proj/myskill"
check "! grep -qF '\~' '$MAN'" "manifest has no literal backslash-tilde"
check "islink '$ROOTA/myskill'" "reconciler resolved the ~ source and linked it"

echo "# 13b. a \$HOME containing glob characters collapses literally, or not at all"
# Regression: collapse_home used ${p/#$HOME/~}, which expands $HOME as a pattern.
# With HOME=.../ho?me, the unrelated path .../hoXme/proj/myskill matched and was
# stored as ~/proj/myskill — a path that expands back to a directory that does
# not exist. Storing it uncollapsed is correct; storing a wrong ~ is not.
GLOBHOME="$WS/ho?me"; OTHER="$WS/hoXme"
mkdir -p "$GLOBHOME"; mkskill "$OTHER/proj/myskill"
writeman
HOME="$GLOBHOME" SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$CLI" add "$OTHER/proj/myskill" --user >"$LOG" 2>&1
check "[ $? -eq 0 ]" "add with a glob-ish \$HOME exits 0"
check "! grep -q '~/proj/myskill' '$MAN'" "look-alike path not collapsed to ~"
check "grep -qF '$OTHER/proj/myskill' '$MAN'" "stored as the real absolute path"
check "islink '$ROOTA/myskill'" "and it links to the directory that exists"

echo "# 14. project scope refuses a repo that isn't there"
# Regression: mkdir -p in link_one would conjure a whole phantom repo out of a
# stale scope (e.g. project:~/Code/skills long after that repo was renamed).
GHOST="$WS/ghostrepo"
writeman "project:$GHOST gamma $SRC/gamma"
sync; rc=$?
check "[ $rc -ne 0 ]" "sync exits non-zero for a missing project repo"
check "absent '$GHOST'" "no phantom repo created"
check "grep -q 'project repo not found' '$LOG'" "missing-repo message"

echo "# 15. a vanished source keeps its link managed (prunable, not orphaned)"
mkskill "$SRC/delta"
writeman "user delta $SRC/delta"
sync
check "islink '$ROOTA/delta'" "delta linked"
rm -rf "$SRC/delta"                       # source disappears under the link
sync; rc=$?
check "[ $rc -ne 0 ]" "sync exits non-zero when the source vanished"
check "[ -L '$ROOTA/delta' ]" "existing link left in place"
check "grep -qF delta '$STATE/sklink/managed.tsv'" "link still recorded as managed"
writeman "user alpha $SRC/alpha"          # now unregister it
sync
check "absent '$ROOTA/delta'" "still prunable after the source was lost"

echo "# 16. sklink add survives a manifest with no trailing newline"
# Regression: '>>' onto an unterminated last line glued the new entry onto it.
printf 'user alpha %s' "$SRC/alpha" > "$MAN"
cli add "$SRC/beta" --user; check "[ $? -eq 0 ]" "add to unterminated manifest exits 0"
check "awk '\$1==\"user\"&&\$2==\"beta\"{f=1}END{exit f?0:1}' '$MAN'" "beta is its own entry"
check "awk '\$1==\"user\"&&\$2==\"alpha\"{f=1}END{exit f?0:1}' '$MAN'" "alpha entry intact"

echo "# 17. root detection has one home: --print-roots, which doctor consumes"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$LINKER" --print-roots >"$LOG" 2>&1
check "grep -qxF '$ROOTA' '$LOG'" "--print-roots lists rootA"
check "grep -qxF '$ROOTB' '$LOG'" "--print-roots lists rootB"
cli doctor
check "grep -qF '$ROOTA' '$LOG'" "doctor reports the overridden roots"

echo "# 18. with no SKLINK_MANIFEST, the default is \$XDG_CONFIG_HOME/sklink/manifest"
# The manifest is user config, not tool code: it must never default to a path
# inside the checkout, or every `add` would dirty the user's clone.
CFG="$WS/config"
XDG_CONFIG_HOME="$CFG" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$CLI" add "$SRC/alpha" --user >"$LOG" 2>&1
check "[ $? -eq 0 ]" "add with no SKLINK_MANIFEST exits 0"
check "[ -f '$CFG/sklink/manifest' ]" "manifest created at the XDG default"
check "grep -q '^# Skill registry' '$CFG/sklink/manifest'" "new manifest carries the format header"
check "awk '\$1==\"user\"&&\$2==\"alpha\"{f=1}END{exit f?0:1}' '$CFG/sklink/manifest'" "entry appended below the header"
check "absent '$tool_dir/manifest'" "nothing written into the tool directory"
check "absent '$tool_dir/skills.manifest'" "no legacy manifest in the tool directory"

echo "# 19. read commands fail helpfully with no manifest; --help still works"
EMPTY="$WS/no-such-config"
XDG_CONFIG_HOME="$EMPTY" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$CLI" list >"$LOG" 2>&1
check "[ $? -ne 0 ]" "list without a manifest exits non-zero"
check "grep -q 'manifest not found' '$LOG'" "says the manifest is missing"
check "grep -q \"sklink add\" '$LOG'" "points at the command that creates one"
XDG_CONFIG_HOME="$EMPTY" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$CLI" --help >"$LOG" 2>&1
check "[ $? -eq 0 ]" "--help works without a manifest"
check "grep -q 'sklink doctor' '$LOG'" "usage printed"
XDG_CONFIG_HOME="$EMPTY" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$LINKER" >"$LOG" 2>&1
check "[ $? -ne 0 ]" "reconciler alone exits non-zero without a manifest"
check "grep -q 'manifest not found' '$LOG'" "reconciler says which path it tried"

echo "# 18b. doctor tells an unreadable root apart from a missing link"
# A sandboxed agent may be denied even a stat inside an agent's home. Every -L
# test then reads false, and reporting a healthy link as MISSING invites a
# destructive "fix". Root can read anything, so there is nothing to prove there.
if [ "$(id -u)" = 0 ]; then
  ok "skipped as root - unreadable dirs are readable to root"
else
  SEALED="$WS/sealed"; mkdir -p "$SEALED"
  writeman "user alpha $SRC/alpha"
  SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$SEALED" bash "$LINKER" >"$LOG" 2>&1
  chmod 000 "$SEALED"
  SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$SEALED" bash "$CLI" doctor >"$LOG" 2>&1
  check "grep -q UNREADABLE '$LOG'" "unreadable root reported as UNREADABLE"
  check "! grep -q MISSING '$LOG'" "not reported as MISSING"
  chmod 755 "$SEALED"
  SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$SEALED" bash "$CLI" doctor >"$LOG" 2>&1
  check "grep -q 'ok    $SEALED/alpha' '$LOG'" "readable again: back to ok"
fi
# restore the roots the later tests expect
writeman "user alpha $SRC/alpha"
sync

echo "# 19b. a symlinked manifest is written through, not replaced"
# Regression: `sklink rm` rewrote the manifest with `mv tmp $manifest`, which
# replaces a symlink with a regular file. A manifest kept in a repo and linked
# into the config dir would silently split in two — the config path holding the
# edit, the repo file keeping the stale content, and nothing reporting it.
REPOMAN="$WS/repoman"; mkdir -p "$REPOMAN"
LINKED="$WS/linked-manifest"
printf 'user alpha %s\nuser beta %s\n' "$SRC/alpha" "$SRC/beta" > "$REPOMAN/skills.manifest"
chmod 644 "$REPOMAN/skills.manifest"
ln -sfn "$REPOMAN/skills.manifest" "$LINKED"
SKLINK_MANIFEST="$LINKED" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$CLI" rm beta >"$LOG" 2>&1
check "[ $? -eq 0 ]" "rm through a symlinked manifest exits 0"
check "[ -L '$LINKED' ]" "the symlink is still a symlink"
check "! grep -q beta '$REPOMAN/skills.manifest'" "the real file lost the entry"
check "grep -q alpha '$REPOMAN/skills.manifest'" "the real file kept the rest"
check "[ \"\$(stat -f '%Lp' '$REPOMAN/skills.manifest' 2>/dev/null || stat -c '%a' '$REPOMAN/skills.manifest')\" = 644 ]" "permissions preserved, not tightened to 0600"
SKLINK_MANIFEST="$LINKED" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$CLI" add "$SRC/gamma" --user >"$LOG" 2>&1
check "[ $? -eq 0 ]" "add through a symlinked manifest exits 0"
check "[ -L '$LINKED' ]" "add left the symlink intact"
check "grep -q gamma '$REPOMAN/skills.manifest'" "add appended to the real file"

echo "# 20. install.sh links the CLI onto PATH, idempotently"
INSTALL="$tool_dir/install.sh"
BIN2="$WS/bin2"
PATH="/usr/bin:/bin" bash "$INSTALL" --bin-dir "$BIN2" >"$LOG" 2>&1
check "[ $? -eq 0 ]" "install exits 0"
check "[ -L '$BIN2/sklink' ]" "symlink created"
check "[ \"\$(readlink '$BIN2/sklink')\" = '$CLI' ]" "symlink points back at the checkout"
check "grep -q 'not on your PATH' '$LOG'" "warns when the bin dir is not on PATH"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$BIN2/sklink" list >"$LOG" 2>&1
check "[ $? -eq 0 ]" "the installed command runs"
PATH="$BIN2:/usr/bin:/bin" bash "$INSTALL" --bin-dir "$BIN2" >"$LOG" 2>&1
check "[ $? -eq 0 ]" "second install exits 0"
check "grep -q 'already installed' '$LOG'" "second install is a no-op"
check "! grep -q 'not on your PATH' '$LOG'" "no PATH warning once the dir is on PATH"

echo "# 20b. --name installs under another command name, and the CLI follows it"
PATH="/usr/bin:/bin" bash "$INSTALL" --bin-dir "$BIN2" --name myskills >"$LOG" 2>&1
check "[ $? -eq 0 ]" "install --name exits 0"
check "[ -L '$BIN2/myskills' ]" "named symlink created"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$BIN2/myskills" --help >"$LOG" 2>&1
check "grep -q '^myskills — ' '$LOG'" "installed command self-names"

echo "# 20c. install refuses to clobber; --force opts in"
printf 'hands off\n' > "$BIN2/taken"
PATH="/usr/bin:/bin" bash "$INSTALL" --bin-dir "$BIN2" --name taken >"$LOG" 2>&1
check "[ $? -ne 0 ]" "refuses to replace a real file"
check "grep -q 'already exists' '$LOG'" "clobber message"
check "grep -q 'hands off' '$BIN2/taken'" "existing file left intact"
PATH="/usr/bin:/bin" bash "$INSTALL" --bin-dir "$BIN2" --name taken --force >"$LOG" 2>&1
check "[ $? -eq 0 ]" "--force exits 0"
check "[ -L '$BIN2/taken' ]" "--force replaced it with the symlink"

echo "# 20d. --uninstall removes only a link it would have made"
PATH="/usr/bin:/bin" bash "$INSTALL" --bin-dir "$BIN2" --name taken --uninstall >"$LOG" 2>&1
check "[ $? -eq 0 ]" "uninstall exits 0"
check "absent '$BIN2/taken'" "symlink removed"
ln -s /usr/bin/true "$BIN2/foreign"
PATH="/usr/bin:/bin" bash "$INSTALL" --bin-dir "$BIN2" --name foreign --uninstall >"$LOG" 2>&1
check "[ $? -ne 0 ]" "refuses to remove a foreign symlink"
check "[ -L '$BIN2/foreign' ]" "foreign symlink survived"
check "grep -q 'points elsewhere' '$LOG'" "foreign-symlink message"
PATH="/usr/bin:/bin" bash "$INSTALL" --bin-dir "$BIN2" --name nothere --uninstall >"$LOG" 2>&1
check "[ $? -eq 0 ]" "uninstalling what isn't there exits 0"
check "grep -q 'nothing to remove' '$LOG'" "says there was nothing to remove"

echo "# 20e. install refuses a half-copied checkout"
# The CLI needs sklink-sync beside it; catching that here beats a confusing
# failure on the user's first `sync`.
HALF="$WS/half"; mkdir -p "$HALF"
cp "$INSTALL" "$HALF/install.sh"; cp "$CLI" "$HALF/sklink"
PATH="/usr/bin:/bin" bash "$HALF/install.sh" --bin-dir "$BIN2" --name half >"$LOG" 2>&1
check "[ $? -ne 0 ]" "install exits non-zero without sklink-sync"
check "grep -q 'sklink-sync' '$LOG'" "names the missing file"
check "absent '$BIN2/half'" "no link created from a broken checkout"

echo
if [ "$fails" -eq 0 ]; then
  printf 'ALL %d TESTS PASSED\n' "$n"; exit 0
else
  printf '%d/%d TESTS FAILED\n' "$fails" "$n"; exit 1
fi
