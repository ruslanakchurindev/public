# sklink

Link one copy of each agent skill into every AI agent on your machine, from a
single declarative manifest.

A skill is a folder with a `SKILL.md` at its root. The same folder works across
Claude Code, Codex and anything reading `~/.agents/skills` — but each agent looks
in its own directory, so copying gives you three divergent copies within a week.
`sklink` keeps exactly one copy; everything else is a symlink.

```console
$ sklink list
5 skills  (4 user, 1 project)  ~/.config/sklink/manifest

user  every agent on this machine
  boris                 ~/Code/skills/boris
  gh-identity           ~/Code/skills/gh-identity
  handover              ~/Code/public/skills/handover
  ntfy                  ~/Code/skills/ntfy

project  ~/Code/api
  writing-great-skills  ~/External/mattpocock-skills/skills/productivity/writing-great-skills
```

The manifest is the source of truth; `sklink-sync` reconciles it into symlinks;
`sklink` is the CLI that edits the manifest and re-syncs. The CLI reads its own
name from `$0`, so renaming the command needs no edit to the script.

## Install

```bash
git clone https://github.com/ruslanakchurindev/public.git ~/Code/public
~/Code/public/sklink/install.sh
```

Symlinks `sklink` into `~/.local/bin` (warning if that is not on your `PATH`) and
creates a starter manifest at `~/.config/sklink/manifest`. Nothing is copied, so
`git pull` updates the installed tool. Re-running is a no-op: it never overwrites
a file it did not create (`--force` to replace one) and **never** overwrites an
existing manifest.

```bash
./install.sh --bin-dir ~/bin      # install somewhere else
./install.sh --name myskills      # install under a different command name
./install.sh --no-config          # skip creating the starter manifest
./install.sh --uninstall          # remove the symlink again
```

By hand, symlink only the CLI — it finds `sklink-sync` and `templates/manifest`
next to its real location:

```bash
ln -s ~/Code/public/sklink/sklink ~/.local/bin/sklink
```

Requires `bash` 3.2+, `awk`, and the usual POSIX tools. macOS and Linux.

## Commands

```bash
sklink add ~/skills/code-review --user           # → every agent on the machine
sklink add ~/skills/deploy --project ~/Code/api  # → one repo only
sklink list                                      # what's registered
sklink doctor                                    # what's actually on disk
```

| Command | What it does |
|---------|--------------|
| `sklink list` | the registry, grouped by scope, with missing sources flagged |
| `sklink add <dir> [--user\|--project <repo>] [--name <n>]` | check for `SKILL.md`, take the name from its frontmatter, register, sync |
| `sklink rm <name> [--scope <scope>]` | unregister it and prune its links |
| `sklink sync [-n] [-v] [-q]` | make the links match the manifest |
| `sklink doctor` | check sources, links and drift; exits non-zero on problems |
| `sklink edit` | open the manifest in `$EDITOR`, then sync if it changed |
| `sklink init` | create the manifest from the template; never overwrites |
| `sklink --version` / `--help` | |

`sync` reports only what moved, so a converged run is one line:

```console
$ sklink sync
  + ~/.agents/skills/handover
  ~ ~/.claude/skills/ntfy -> ~/Code/skills/ntfy
  - ~/.codex/skills/old-thing  pruned
5 skills, 15 links  1 new, 1 retargeted, 1 pruned
```

`-n` is a dry run (`?` means a root could not be inspected), `-v` lists untouched
links too, `-q` prints nothing but warnings — what you want from a shell hook.
Colour switches off when output is not a terminal, and honours `NO_COLOR`.

## Scopes

| Scope | Goes to | Committed to git? |
|-------|---------|-------------------|
| `user` | every **detected** agent: `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills` | **No** — local symlinks, recreated by `sklink sync` |
| `project:<repo>` | that repo's `.claude/skills` and `.codex/skills` | **Yes** — they live in the repo and travel with it |

Project links are *absolute* symlinks pointing outside the repo, so git
materialises them in every worktree checkout and they still resolve there;
gitignoring them would leave every new worktree without project skills. The cost:
moving a source directory leaves committed links dangling — `doctor` reports it,
`sync` plus a commit repairs it.

User roots are auto-detected (the agent's home directory either exists or it does
not; override with `SKLINK_ROOTS`). A repo leaves no such marker, so the per-repo
subdirectory list is explicit in `sklink-sync` (`project_subdirs`).

## The manifest

Lives at `~/.config/sklink/manifest` by default, written from
[`templates/manifest`](templates/manifest) on first use. It is your data — nothing
is written inside the checkout, and no command overwrites an existing manifest.

```
# scope                name                 source-dir
user                   code-review          ~/skills/code-review
user                   handover             ~/Code/public/skills/handover
project:~/Code/api     deploy               ~/skills/deploy
```

Whitespace-separated; `#` comments (whole-line or trailing) and blank lines
ignored; `~` expands. A source path cannot contain spaces — `sklink add` refuses
one rather than writing a line that reads back as a different path. `source-dir`
may live anywhere. `name` is what the agent sees and should match the source's
`SKILL.md` frontmatter; `doctor` reports it when they drift.

## Safety

`sklink-sync` touches only links **it** created, recorded in
`~/.local/state/sklink/managed.tsv`. It never deletes an unmanaged skill, never
replaces a real file or directory, and changes nothing under `--dry-run`
(including the state file). A missing source or a `project:` repo that is not
there warns and exits non-zero rather than leaving a dangling link or conjuring
the repo back with `mkdir -p`. One bad entry never stops the rest of a run, and a
link whose source vanished stays under management so `doctor` still sees it.

## What `doctor` checks

Sources, then the links `sync` would really make (it asks `sklink-sync
--print-plan`, so there is no second copy of the rules), then leftovers. Exits
non-zero on a problem, so it works as a hook or a CI check.

| Word | Means |
|------|-------|
| `MISSING` (source) | the source directory is gone |
| `BAD` | not a skill, an unknown scope, a `project:` repo that is not there, or a malformed line |
| `NAME` | the manifest name disagrees with the source's `SKILL.md` |
| `MISSING` (link) | the manifest asks for a link that is not on disk — usually "not synced yet" |
| `DANGLING` | the link is there, its target is not |
| `WRONG` | the link points at something other than the registered source |
| `BLOCKED` | a real file or directory occupies the link's name |
| `UNREADABLE` | that root cannot be inspected (permissions, or a sandboxed agent) |

`UNREADABLE` is not counted as a problem: a sandboxed agent is often denied a stat
in another agent's home, and reporting those links as missing would invite a
destructive "fix".

`sklink-sync` is safe to run directly from a shell hook, a login script or cron:

```bash
sklink-sync -q || echo "skills need attention"
```

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `SKLINK_MANIFEST` | `$XDG_CONFIG_HOME/sklink/manifest` | where the registry lives |
| `SKLINK_ROOTS` | auto-detected | space-separated user-wide skill roots, replacing detection |
| `XDG_CONFIG_HOME` | `~/.config` | |
| `XDG_STATE_HOME` | `~/.local/state` | holds `sklink/managed.tsv` |
| `EDITOR` / `VISUAL` | `vi` | used by `sklink edit` |
| `NO_COLOR` | unset | set to anything to disable colour |

Already keep your registry in a repo? Point `SKLINK_MANIFEST` at it rather than
moving it — the real file is written through, so a symlinked manifest stays a
symlink.

## Uninstall

```bash
sklink rm <name>                # drop one skill and prune its links
: > ~/.config/sklink/manifest   # or: empty the manifest…
sklink sync                     # …and let the reconciler prune everything
./install.sh --uninstall        # take the command off your PATH
rm -r ~/.config/sklink ~/.local/state/sklink   # manifest and state, if you're done
```

Hand-placed skills are left untouched, and `--uninstall` removes the symlink only
if it still points at this checkout.

## Tests

```bash
bash sklink/scripts/test-sklink.sh
```

Hermetic: the suite runs entirely inside a temp workspace via `SKLINK_MANIFEST` /
`SKLINK_ROOTS` / `XDG_CONFIG_HOME` / `XDG_STATE_HOME`, so it never touches your
real agent directories, config or `PATH`.

## License

MIT — see [LICENSE](../LICENSE).
