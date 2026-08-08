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

echo "# 10. doctor names each way a source or a link can be wrong"
writeman "user alpha $SRC/alpha" "user gamma $SRC/gamma"
sync
rm -rf "$SRC/gamma"          # break the source out from under the link
cli doctor; rc=$?
check "[ $rc -ne 0 ]" "doctor exits non-zero once something is wrong"
check "grep -q MISSING '$LOG'" "doctor reports a source that is gone"
check "grep -q DANGLING '$LOG'" "doctor reports DANGLING link"
check "grep -qF '$MAN' '$LOG'" "doctor names the manifest in use"
mkdir -p "$SRC/nosk"         # a directory that is not a skill
writeman "user alpha $SRC/alpha" "user nosk $SRC/nosk"
cli doctor
check "grep -q 'BAD' '$LOG'" "doctor reports BAD for a dir with no SKILL.md"
check "grep -q 'no SKILL.md' '$LOG'" "and says why"
rm -rf "$SRC/nosk"

echo "# 10b. doctor is quiet and exits 0 when everything is healthy"
writeman "user alpha $SRC/alpha"
sync
cli doctor; rc=$?
check "[ $rc -eq 0 ]" "healthy doctor exits 0"
check "grep -q 'all good' '$LOG'" "and says so"
check "! grep -qE 'MISSING|DANGLING|BAD|WRONG' '$LOG'" "with no problem words in the report"

echo "# 10c. doctor tells apart drift the reconciler cannot see"
# A link pointing somewhere else, a real directory squatting the link name, and
# a manifest name that disagrees with the source's own frontmatter: three kinds
# of drift that a plain 'is there a symlink' check would call healthy.
mkskill "$SRC/drift"
printf -- '---\nname: renamed\n---\nbody\n' > "$SRC/drift/SKILL.md"
writeman "user alpha $SRC/alpha" "user drift $SRC/drift"
sync
ln -sfn "$SRC/beta" "$ROOTA/alpha"      # retargeted behind our back
mkdir -p "$ROOTB/drift.tmp" && rm -rf "$ROOTB/drift" && mv "$ROOTB/drift.tmp" "$ROOTB/drift"
cli doctor; rc=$?
check "[ $rc -ne 0 ]" "doctor exits non-zero on drift"
check "grep -q WRONG '$LOG'" "reports a link pointing at the wrong source"
check "grep -q BLOCKED '$LOG'" "reports a real directory sitting on a link name"
check "grep -q NAME '$LOG'" "reports a name that disagrees with SKILL.md"
check "grep -q 'renamed' '$LOG'" "and quotes what SKILL.md actually says"
rm -rf "$ROOTB/drift" "$SRC/drift"

echo "# 10d. doctor reports links left over from an edit that was never synced"
writeman "user alpha $SRC/alpha" "user beta $SRC/beta"
sync
writeman "user alpha $SRC/alpha"        # hand-edit: beta dropped, no sync yet
cli doctor
check "grep -q 'no longer in the manifest' '$LOG'" "leftover section shown"
check "grep -qF '$ROOTA/beta' '$LOG'" "names the leftover link"
sync
check "absent '$ROOTA/beta'" "and sync removes it"

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
TOOL="$WS/tool"; mkdir -p "$TOOL" "$TOOL/templates" "$WS/bin"
cp "$CLI" "$TOOL/sklink"; cp "$LINKER" "$TOOL/sklink-sync"
cp "$tool_dir/templates/manifest" "$TOOL/templates/manifest"
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
check "grep -q 'manifest' '$CFG/sklink/manifest'" "new manifest carries the format header"
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
  check "grep -q 'not checked' '$LOG'" "says the links there were not checked"
  chmod 755 "$SEALED"
  SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$SEALED" bash "$CLI" doctor >"$LOG" 2>&1
  check "grep -q \"$SEALED  *1 ok\" '$LOG'" "readable again: counted as ok"
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
# The installer now also creates a manifest, so every call below gets its own
# XDG_CONFIG_HOME: the suite must never write into the real ~/.config.
ICFG="$WS/install-config"
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$ICFG" bash "$INSTALL" --bin-dir "$BIN2" >"$LOG" 2>&1
check "[ $? -eq 0 ]" "install exits 0"
check "[ -L '$BIN2/sklink' ]" "symlink created"
check "[ \"\$(readlink '$BIN2/sklink')\" = '$CLI' ]" "symlink points back at the checkout"
check "grep -q 'not on your PATH' '$LOG'" "warns when the bin dir is not on PATH"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$BIN2/sklink" list >"$LOG" 2>&1
check "[ $? -eq 0 ]" "the installed command runs"
check "[ -f '$ICFG/sklink/manifest' ]" "install created a manifest from the template"
check "grep -q 'sklink sync' '$ICFG/sklink/manifest'" "template documents the format"
printf 'user alpha %s\n' "$SRC/alpha" >> "$ICFG/sklink/manifest"   # user data to protect
PATH="$BIN2:/usr/bin:/bin" XDG_CONFIG_HOME="$ICFG" bash "$INSTALL" --bin-dir "$BIN2" >"$LOG" 2>&1
check "[ $? -eq 0 ]" "second install exits 0"
check "grep -q 'already installed' '$LOG'" "second install is a no-op"
check "grep -q 'already exists' '$LOG'" "and leaves the manifest alone"
check "grep -q '^user alpha' '$ICFG/sklink/manifest'" "an existing manifest is never overwritten"
check "! grep -q 'not on your PATH' '$LOG'" "no PATH warning once the dir is on PATH"
NOCFG="$WS/install-noconfig"
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$NOCFG" bash "$INSTALL" --bin-dir "$BIN2" --no-config --force >"$LOG" 2>&1
check "[ $? -eq 0 ]" "--no-config exits 0"
check "absent '$NOCFG/sklink/manifest'" "--no-config writes no manifest"

echo "# 20b. --name installs under another command name, and the CLI follows it"
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$ICFG" bash "$INSTALL" --bin-dir "$BIN2" --name myskills >"$LOG" 2>&1
check "[ $? -eq 0 ]" "install --name exits 0"
check "[ -L '$BIN2/myskills' ]" "named symlink created"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$BIN2/myskills" --help >"$LOG" 2>&1
check "grep -q '^myskills — ' '$LOG'" "installed command self-names"

echo "# 20c. install refuses to clobber; --force opts in"
printf 'hands off\n' > "$BIN2/taken"
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$ICFG" bash "$INSTALL" --bin-dir "$BIN2" --name taken >"$LOG" 2>&1
check "[ $? -ne 0 ]" "refuses to replace a real file"
check "grep -q 'already exists' '$LOG'" "clobber message"
check "grep -q 'hands off' '$BIN2/taken'" "existing file left intact"
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$ICFG" bash "$INSTALL" --bin-dir "$BIN2" --name taken --force >"$LOG" 2>&1
check "[ $? -eq 0 ]" "--force exits 0"
check "[ -L '$BIN2/taken' ]" "--force replaced it with the symlink"

echo "# 20d. --uninstall removes only a link it would have made"
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$ICFG" bash "$INSTALL" --bin-dir "$BIN2" --name taken --uninstall >"$LOG" 2>&1
check "[ $? -eq 0 ]" "uninstall exits 0"
check "absent '$BIN2/taken'" "symlink removed"
ln -s /usr/bin/true "$BIN2/foreign"
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$ICFG" bash "$INSTALL" --bin-dir "$BIN2" --name foreign --uninstall >"$LOG" 2>&1
check "[ $? -ne 0 ]" "refuses to remove a foreign symlink"
check "[ -L '$BIN2/foreign' ]" "foreign symlink survived"
check "grep -q 'points elsewhere' '$LOG'" "foreign-symlink message"
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$ICFG" bash "$INSTALL" --bin-dir "$BIN2" --name nothere --uninstall >"$LOG" 2>&1
check "[ $? -eq 0 ]" "uninstalling what isn't there exits 0"
check "grep -q 'nothing to remove' '$LOG'" "says there was nothing to remove"

echo "# 20e. install refuses a half-copied checkout"
# The CLI needs sklink-sync and the manifest template beside it; catching that
# here beats a confusing failure on the user's first `sync`.
HALF="$WS/half"; mkdir -p "$HALF"
cp "$INSTALL" "$HALF/install.sh"; cp "$CLI" "$HALF/sklink"
PATH="/usr/bin:/bin" bash "$HALF/install.sh" --bin-dir "$BIN2" --name half >"$LOG" 2>&1
check "[ $? -ne 0 ]" "install exits non-zero without sklink-sync"
check "grep -q 'sklink-sync' '$LOG'" "names the missing file"
check "absent '$BIN2/half'" "no link created from a broken checkout"
cp "$LINKER" "$HALF/sklink-sync"
PATH="/usr/bin:/bin" bash "$HALF/install.sh" --bin-dir "$BIN2" --name half >"$LOG" 2>&1
check "[ $? -ne 0 ]" "install exits non-zero without the template"
check "grep -q 'templates/manifest' '$LOG'" "names the missing template"

echo "# 21. init writes the manifest from the template, and never overwrites one"
# The template is the format documentation: it ships with the tool, so what a
# user finds at the top of their own file is the text we maintain in the repo.
ICFG2="$WS/config-init"
init_cli() { XDG_CONFIG_HOME="$ICFG2" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" bash "$1" "${@:2}" >"$LOG" 2>&1; }
init_cli "$CLI" init
check "[ $? -eq 0 ]" "init exits 0"
check "[ -f '$ICFG2/sklink/manifest' ]" "manifest created"
check "grep -q '^#' '$ICFG2/sklink/manifest'" "it is the commented template"
check "grep -q 'created manifest' '$LOG'" "and says so"
init_cli "$CLI" list
check "grep -q 'no skills registered yet' '$LOG'" "list of an empty registry explains itself"
printf 'user alpha %s\n' "$SRC/alpha" >> "$ICFG2/sklink/manifest"
init_cli "$CLI" init
check "[ $? -eq 0 ]" "second init exits 0"
check "grep -q 'already exists' '$LOG'" "second init reports it left things alone"
check "grep -q '^user alpha' '$ICFG2/sklink/manifest'" "existing content untouched"
check "[ \"\$(grep -c '^user alpha' '$ICFG2/sklink/manifest')\" = 1 ]" "and not appended twice"

echo "# 21b. the template speaks the name the command was installed under"
ICFG3="$WS/config-named"
XDG_CONFIG_HOME="$ICFG3" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$WS/bin/myskills" init >"$LOG" 2>&1
check "grep -q 'myskills sync' '$ICFG3/sklink/manifest'" "template says 'myskills sync'"
check "! grep -q 'sklink sync' '$ICFG3/sklink/manifest'" "and never the repo's own name"
check "! grep -q '@CMD@' '$ICFG3/sklink/manifest'" "no placeholder left behind"

echo "# 22. sync reports what changed, not what it re-checked"
writeman            # empty manifest first: prune back to a known-clean slate
sync
check "grep -q 'no skills registered' '$LOG'" "an empty manifest reports itself"
writeman "user alpha $SRC/alpha" "user beta $SRC/beta"
sync
check "grep -qE '2 skills, 4 links' '$LOG'" "summary counts skills and links"
check "grep -q '4 new' '$LOG'" "first run reports new links"
sync
check "grep -q 'up to date' '$LOG'" "a converged run says up to date"
check "! grep -q '$ROOTA/alpha' '$LOG'" "and does not replay every link"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" bash "$LINKER" -v >"$LOG" 2>&1
check "grep -qF '$ROOTA/alpha' '$LOG'" "-v lists every link"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" bash "$LINKER" -q >"$LOG" 2>&1
check "[ ! -s '$LOG' ]" "-q on a healthy run prints nothing"
ln -sfn "$SRC/gamma" "$ROOTA/alpha"       # someone retargeted a link
sync
check "grep -q '1 retargeted' '$LOG'" "a link pointing elsewhere is retargeted"
check "[ \"\$(readlink '$ROOTA/alpha')\" = '$SRC/alpha' ]" "and put back on the manifest's source"

echo "# 22b. sync --dry-run changes nothing"
writeman "user alpha $SRC/alpha" "user beta $SRC/beta" "user gamma $SRC/gamma"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" bash "$LINKER" --dry-run >"$LOG" 2>&1
check "[ $? -eq 0 ]" "dry run exits 0"
check "grep -q 'dry run' '$LOG'" "says it was a dry run"
check "grep -q '2 new' '$LOG'" "reports what it would create"
check "absent '$ROOTA/gamma'" "but creates nothing"
check "! grep -qF gamma '$STATE/sklink/managed.tsv'" "and records nothing in state"
sync
check "islink '$ROOTA/gamma'" "the real run then creates it"

echo "# 22c. a dry run says so when it cannot see inside a root"
# Every -L test reads false in a root we may not enter, so without this a dry
# run would announce links that are already there. A real run finds out
# honestly: the ln fails and warns. Root can read anything, so skip it there.
if [ "$(id -u)" = 0 ]; then
  ok "skipped as root - unreadable dirs are readable to root"
else
  SEALED2="$WS/sealed2"; mkdir -p "$SEALED2"
  writeman "user alpha $SRC/alpha"
  SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$SEALED2" bash "$LINKER" >/dev/null 2>&1
  chmod 000 "$SEALED2"
  SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$SEALED2" bash "$LINKER" -n >"$LOG" 2>&1
  check "grep -q 'not checked' '$LOG'" "dry run reports what it could not check"
  check "! grep -q '1 new' '$LOG'" "and does not claim the existing link is new"
  chmod 755 "$SEALED2"
fi

echo "# 22d. a machine with no agent installed yet says so"
# The first thing a new user does is `add`, and "0 links, up to date" is a
# baffling answer when nothing is installed to link into. SKLINK_ROOTS is left
# unset here on purpose: this exercises detection finding nothing.
LONELY="$WS/lonely-home"; mkdir -p "$LONELY"
writeman "user alpha $SRC/alpha"
HOME="$LONELY" SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" bash "$LINKER" >"$LOG" 2>&1
check "[ $? -eq 0 ]" "no agent directory is not an error"
check "grep -q 'no agent directory found' '$LOG'" "sync explains the empty result"
check "grep -q '~/.claude' '$LOG'" "and names where it looked"
check "grep -q 'SKLINK_ROOTS' '$LOG'" "and the way to override detection"
mkdir -p "$LONELY/.claude"
HOME="$LONELY" SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" bash "$LINKER" >"$LOG" 2>&1
check "islink '$LONELY/.claude/skills/alpha'" "installing an agent later just works"
check "! grep -q 'no agent directory' '$LOG'" "and the note is gone"
# That run recorded links under the fake home; drop them from state so the
# suite's own roots are the only thing later checks reconcile.
writeman "user alpha $SRC/alpha"
sync

echo "# 23. one broken entry never stops the rest of the reconcile"
# Regression: `return` after a false test handed its status back to `set -e`,
# so the first missing source aborted the run before the prune and before the
# state file was written — leaving every later entry unprocessed.
writeman "user ghost $WS/nope" "user alpha $SRC/alpha" "user beta $SRC/beta"
sync; rc=$?
check "[ $rc -ne 0 ]" "sync still exits non-zero"
check "islink '$ROOTA/alpha'" "entries after the broken one are still linked"
check "islink '$ROOTB/beta'" "in every root"
check "[ -f '$STATE/sklink/managed.tsv' ]" "state file still written"
check "[ \"\$(grep -c 'source not found' '$LOG')\" = 1 ]" "one missing source is reported once, not once per root"

echo "# 23b. a trailing comment is fine; anything else after the source is not"
writeman "user alpha $SRC/alpha  # the good one" "user beta $SRC/beta and then some"
sync
check "islink '$ROOTA/alpha'" "an entry with a trailing comment still links"
check "! grep -q 'ignoring extra text after the source for alpha' '$LOG'" "and says nothing about it"
check "grep -q 'ignoring extra text' '$LOG'" "junk after the source is reported"
check "grep -q 'cannot contain spaces' '$LOG'" "with the reason a path is the likely cause"

echo "# 24. add validates before it writes anything"
SPACED="$WS/has space/skill"; mkskill "$SPACED"
cli add "$SPACED" --user
check "[ $? -ne 0 ]" "a source path with a space is refused"
check "grep -q 'whitespace' '$LOG'" "and says why"
check "! grep -q 'has space' '$MAN'" "nothing written to the manifest"
cli add "$SRC/alpha" --project "$WS/no-such-repo"
check "[ $? -ne 0 ]" "a --project repo that isn't there is refused"
check "grep -q 'no such repo' '$LOG'" "with a message about the repo"
cli add "$WS/not-a-skill-dir" --user
check "[ $? -ne 0 ]" "a directory that isn't there is refused"
mkdir -p "$WS/bare"; cli add "$WS/bare" --user
check "[ $? -ne 0 ]" "a directory with no SKILL.md is refused"
check "grep -q 'SKILL.md' '$LOG'" "and names what is missing"

echo "# 25. list groups by scope and stays aligned"
writeman "user alpha $SRC/alpha" "project:$PROJ gamma $SRC/gamma" "user beta $SRC/beta"
cli list
check "[ $? -eq 0 ]" "list exits 0"
check "grep -q '3 skills' '$LOG'" "reports the total"
check "grep -q '^user' '$LOG'" "user group header"
check "grep -qE '^project +'\"$PROJ\" '$LOG'" "project group header names the repo"
check "[ \"\$(grep -c '^user' '$LOG')\" = 1 ]" "the user scope is one group, not one line per entry"
rm -rf "$SRC/beta"
cli list
check "grep -q 'source missing' '$LOG'" "a source that is gone is flagged in list"
mkskill "$SRC/beta"

echo "# 25b. doctor points at whatever actually fixes what it found"
writeman "user alpha $SRC/alpha"
sync
rm -f "$ROOTA/alpha"                       # a link problem: sync fixes it
cli doctor
check "grep -q \"run '\"'sklink sync'\"'\" '$LOG'" "link-only trouble says: run sync"
check "! grep -q 'fix the sources' '$LOG'" "and does not blame the sources"
sync
writeman "user alpha $SRC/alpha" "user vanished $WS/gone"
cli doctor
check "grep -q 'fix the sources' '$LOG'" "a broken source says: fix the source"
check "grep -q \"'\"'sklink edit'\"'\" '$LOG'" "and names the command that edits the manifest"

echo "# 25c. the CLI passes sync flags through to the reconciler"
writeman "user alpha $SRC/alpha" "user gamma $SRC/gamma"
sync
writeman "user alpha $SRC/alpha" "user gamma $SRC/gamma" "user beta $SRC/beta"
cli sync --dry-run
check "grep -q 'dry run' '$LOG'" "sklink sync --dry-run reaches the reconciler"
check "absent '$ROOTA/beta'" "and nothing was created"
cli sync -v
check "grep -qF '$ROOTA/alpha' '$LOG'" "sklink sync -v lists unchanged links"

echo "# 25d. edit opens \$EDITOR, then syncs only if the file changed"
FAKE="$WS/fake-editor"
printf '#!/bin/sh\nprintf "user delta %s\\n" "%s" >> "$1"\n' '%s' "$SRC/delta" > "$FAKE"
chmod +x "$FAKE"
mkskill "$SRC/delta"
writeman "user alpha $SRC/alpha"
sync
EDITOR="$FAKE" cli edit
check "[ $? -eq 0 ]" "edit exits 0"
check "grep -q delta '$MAN'" "the editor's change landed"
check "islink '$ROOTA/delta'" "and edit synced it"
EDITOR="/usr/bin/true" cli edit
check "grep -q 'no changes' '$LOG'" "an untouched file skips the sync"
EDITOR="$WS/no-such-editor" cli edit
check "[ $? -ne 0 ]" "a missing editor is an error, not a silent no-op"
check "grep -q 'editor not found' '$LOG'" "and says so"

echo "# 25e. no escape codes when output is not a terminal"
# Every check in this suite reads a redirected log, so colour must switch itself
# off there — otherwise the first thing a user pipes into grep breaks.
cli list
check "! grep -q '$(printf '\033')' '$LOG'" "list writes plain text to a pipe"
cli doctor
check "! grep -q '$(printf '\033')' '$LOG'" "doctor writes plain text to a pipe"

echo "# 26. --version, and --print-plan is what doctor consumes"
cli --version
check "grep -q '^sklink 0' '$LOG'" "--version prints name and version"
writeman "user alpha $SRC/alpha"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$LINKER" --print-plan >"$LOG" 2>&1
check "[ $? -eq 0 ]" "--print-plan exits 0"
check "grep -qF \"\$(printf '%s/alpha\t%s/alpha' '$ROOTA' '$SRC')\" '$LOG'" "plan is <link-path>TAB<source>"
check "[ \"\$(wc -l < '$LOG')\" -eq 2 ]" "one line per link, both roots"
writeman "project:$WS/ghostrepo gamma $SRC/gamma"
SKLINK_MANIFEST="$MAN" XDG_STATE_HOME="$STATE" SKLINK_ROOTS="$ROOTS" \
  bash "$LINKER" --print-plan >"$LOG" 2>&1
check "[ ! -s '$LOG' ]" "a query mode plans nothing and warns about nothing"

echo
if [ "$fails" -eq 0 ]; then
  printf 'ALL %d TESTS PASSED\n' "$n"; exit 0
else
  printf '%d/%d TESTS FAILED\n' "$fails" "$n"; exit 1
fi
