# sklink

Link one copy of each agent skill into every AI agent on your machine, from a
single declarative manifest.

A skill is a folder with a `SKILL.md` at its root (the open Agent Skills
format). The same folder works across Claude Code, Codex and anything else that
reads `~/.agents/skills` — but each agent looks in its own directory, so a skill
you want everywhere has to exist in several places at once. Copying it into each
one gives you three divergent copies within a week.

`sklink` keeps exactly one copy. Everything else is a symlink, so you edit a
skill in one place and every agent sees the change instantly.

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

---

## Mental model

One file decides everything; one command makes it real.

```
manifest  ─────────▶  sklink-sync  ─────────▶  symlinks in agent skill dirs
(source of truth)     (reconciler)             (Claude, Codex, .agents,
                                                and per-repo .claude/.codex)
```

- **the manifest** — the single source of truth. One line per skill: what it
  is, where it lives, and how far it should spread.
- **`sklink-sync`** — reads the manifest and creates absolute symlinks.
  Idempotent and prune-safe; reports only what changed.
- **`sklink`** — the CLI that edits the manifest for you and re-syncs. It takes
  its name from the symlink you invoke it through, so renaming the command is a
  one-line change with no edit to the script.

---

## Install

```bash
git clone https://github.com/ruslanakchurindev/public.git ~/Code/public
~/Code/public/sklink/install.sh
```

That symlinks `sklink` into `~/.local/bin` (and says so if that directory isn't
on your `PATH`), then creates a starter manifest at
`~/.config/sklink/manifest` from the template that ships with the tool. Nothing
is copied — the command points back at the checkout, so `git pull` updates the
installed tool. Re-running it is a no-op: it never overwrites a file it didn't
create (pass `--force` if you mean to replace one) and **never** overwrites an
existing manifest.

```bash
./install.sh --bin-dir ~/bin      # install somewhere else
./install.sh --name myskills      # install under a different command name
./install.sh --no-config          # skip creating the starter manifest
./install.sh --uninstall          # remove the symlink again
```

Doing it by hand is one line, if you'd rather see exactly what happens:

```bash
ln -s ~/Code/public/sklink/sklink ~/.local/bin/sklink
```

Symlink only the CLI — it finds `sklink-sync` and `templates/manifest` next to
its real location, through however many symlinks you point at it. (The installer
checks that those files are actually side by side, which is the one thing a
hand-rolled copy tends to get wrong.)

Requires `bash` (3.2 or newer, so macOS's system bash is fine) plus `awk` and
the usual POSIX tools. macOS and Linux.

The PATH name is deliberately not `skills`: that word is being claimed from
several directions at once (Claude Code's `/skills`, the Agent Skills spec, and
whatever ships next), and a generic name on `PATH` is only cheap until it isn't.
Call the symlink whatever you like — the CLI reads its own name from `$0`, so
its help, its errors, and the template it writes all follow.

---

## Quickstart

```bash
sklink add ~/skills/code-review --user           # → every agent on the machine
sklink add ~/skills/deploy --project ~/Code/api  # → one repo only
sklink list                                      # what's registered
sklink doctor                                    # what's actually on disk
```

`sklink add`:

1. checks the folder has a `SKILL.md`,
2. derives the skill name from its frontmatter (override with `--name`),
3. appends a line to the manifest, creating it on first use,
4. runs `sklink sync` for you.

Prefer editing by hand? `sklink edit` opens the manifest in `$EDITOR` and syncs
when you save a change — or edit the file yourself and run `sklink sync`.

---

## Commands

| Command | What it does |
|---------|--------------|
| `sklink list` | the registry, grouped by scope, with missing sources flagged |
| `sklink add <dir> [--user\|--project <repo>] [--name <n>]` | register a skill and sync |
| `sklink rm <name> [--scope <scope>]` | unregister it and prune its links |
| `sklink sync [-n] [-v] [-q]` | make the links match the manifest |
| `sklink doctor` | check sources, links and drift; exits non-zero on problems |
| `sklink edit` | open the manifest in `$EDITOR`, then sync if it changed |
| `sklink init` | create the manifest from the template; never overwrites |
| `sklink --version` / `--help` | |

`sync` reports what moved and nothing else, so a converged run is one line:

```console
$ sklink sync
  + ~/.agents/skills/handover
  ~ ~/.claude/skills/ntfy -> ~/Code/skills/ntfy
  - ~/.codex/skills/old-thing  pruned
5 skills, 15 links  1 new, 1 retargeted, 1 pruned

$ sklink sync
5 skills, 15 links  up to date
```

`-n` shows what a run would change without changing it, `-v` lists every link
including the untouched ones, and `-q` prints nothing but warnings — which is
what you want from a shell hook or a login script. A `?` in a dry run means the
root couldn't be inspected (permissions, or a sandboxed agent), so the answer is
"can't tell" rather than a guess.

Colour switches itself off when output isn't a terminal, and honours `NO_COLOR`.

---

## Two kinds of distribution

| Scope | Goes to | Committed to git? |
|-------|---------|-------------------|
| `user` | every **detected** agent, machine-wide: `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills` | **No** — these are local machine symlinks, recreated from the manifest |
| `project:<repo>` | that repo's `.claude/skills` and `.codex/skills` | **Yes** — they live inside the repo and travel with it |

So: **user skills are a local setting** (regenerated by `sklink sync`, never
committed), while **project skills belong to their repo** (commit them there).

The asymmetry is deliberate. A user root is auto-detected — the agent's home
directory either exists or it doesn't — so the list can shrink and grow by
itself. A repo leaves no such marker for an agent that hasn't been used in it
yet, so the per-repo subdirectory list is explicit in `sklink-sync`
(`project_subdirs`).

**Why commit project links:** they're *absolute* symlinks pointing outside the
repo, so git materialises them in every worktree checkout and they still resolve
there. Gitignoring them would mean every new worktree starts with no project
skills, and only the main checkout could ever be fixed by a sync. The cost is
that moving a source directory leaves the committed links dangling — `sklink
doctor` reports that, and `sklink sync` plus a commit repairs it.

---

## The manifest

Lives at `~/.config/sklink/manifest` by default, written from
[`templates/manifest`](templates/manifest) the first time you need one. It is
your data, not the tool's — nothing is ever written inside the checkout, so
pulling an update never conflicts with your registry, and no command ever
overwrites a manifest that already exists.

```
# scope                name                 source-dir
user                   code-review          ~/skills/code-review
user                   handover             ~/Code/public/skills/handover
project:~/Code/api     deploy               ~/skills/deploy
```

- Whitespace-separated; `#` comments (whole-line or trailing) and blank lines
  ignored; `~` expands. A source path cannot contain spaces — `sklink add`
  refuses one rather than writing a line that reads back as a different path.
- `source-dir` may live in **any** directory — a skills monorepo, a cloned
  third-party repo, or a one-off folder.
- `name` is what the agent sees, and should match the source's `SKILL.md`
  frontmatter `name:`. `sklink add` derives it for you; hand-edits can drift,
  and `sklink doctor` reports it when they do.

---

## How the reconciler stays safe

`sklink-sync` only ever touches links **it** created. It records every link it
makes in `~/.local/state/sklink/managed.tsv`; on the next run it removes only
the previously-managed links that are no longer in the manifest. It will:

- never delete an unmanaged skill (Codex's `.system/`, anything you dropped in
  by hand),
- refuse to replace a real directory or file that isn't a symlink,
- warn (and exit non-zero) on a missing source rather than leave a dangling
  link,
- refuse a `project:` scope whose repo doesn't exist, instead of conjuring a
  phantom repo out of a stale path via `mkdir -p`,
- keep going after any single failure — an unwritable target, a missing source,
  a malformed line — so one bad entry can't leave the rest unprocessed and the
  state file stale,
- keep a link it can no longer refresh (source vanished) under management, so it
  stays visible to `doctor` and prunable later rather than being orphaned,
- change nothing at all under `--dry-run`, including the state file.

Agent roots are **auto-detected**: a root is used only if that agent's home
directory exists, so installing or removing an agent just works. See what was
detected with `sklink doctor`, or override the set entirely with `SKLINK_ROOTS`.

---

## What `doctor` checks

```console
$ sklink doctor
manifest  ~/.config/sklink/manifest  (5 skills)
roots     ~/.claude/skills
          ~/.codex/skills
          ~/.agents/skills

sources
  ok       boris                ~/Code/skills/boris
  NAME     handover             ~/Code/public/skills/handover  its SKILL.md says "handoff"
  MISSING  ntfy                 ~/Code/skills/ntfy  no such directory

links
  ~/.claude/skills   4 ok
  ~/.codex/skills    UNREADABLE (4 links not checked — permissions or sandbox)
  ~/.agents/skills   3 ok
      DANGLING ntfy -> ~/Code/skills/ntfy

3 problems  fix the sources above — 'sklink edit' to change the manifest, then 'sklink sync'
```

| Word | Means |
|------|-------|
| `MISSING` (source) | the source directory is gone |
| `BAD` | not a skill (no `SKILL.md`), an unknown scope, a `project:` repo that isn't there, or a malformed line |
| `NAME` | the manifest name disagrees with the source's `SKILL.md` frontmatter |
| `MISSING` (link) | the manifest asks for a link that isn't on disk — usually "you haven't synced yet" |
| `DANGLING` | the link is there, its target isn't |
| `WRONG` | the link points at something other than the registered source |
| `BLOCKED` | a real file or directory occupies the link's name |
| `UNREADABLE` | that root can't be inspected (permissions, or a sandboxed agent) — reported, never "fixed" |

The link list comes from `sklink-sync --print-plan`, so `doctor` checks the
links `sync` would really make rather than a second implementation of the same
rules. It exits non-zero when it found a problem, which makes it usable as a
hook or a CI check. An `UNREADABLE` root is not a problem — a sandboxed agent is
often denied a stat in another agent's home, and reporting those links as
missing would invite a destructive "fix".

`sklink-sync` is safe to run directly — from a shell hook, a login script, or
cron — without going through the CLI:

```bash
sklink-sync -q || echo "skills need attention"
```

---

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `SKLINK_MANIFEST` | `$XDG_CONFIG_HOME/sklink/manifest` | where the registry lives |
| `SKLINK_ROOTS` | auto-detected | space-separated user-wide skill roots, replacing detection |
| `XDG_CONFIG_HOME` | `~/.config` | |
| `XDG_STATE_HOME` | `~/.local/state` | holds `sklink/managed.tsv` |
| `EDITOR` / `VISUAL` | `vi` | used by `sklink edit` |
| `NO_COLOR` | unset | set to anything to disable colour |

Already keep your skills registry in a repo? Point at it instead of moving it:

```bash
export SKLINK_MANIFEST=~/Code/skills/skills.manifest
# or:  ln -s ~/Code/skills/skills.manifest ~/.config/sklink/manifest
```

Either way the real file is written through, never replaced — a symlinked
manifest stays a symlink.

---

## Uninstall

```bash
sklink rm <name>                # drop one skill and prune its links
: > ~/.config/sklink/manifest   # or: empty the manifest…
sklink sync                     # …and let the reconciler prune everything
./install.sh --uninstall        # take the command off your PATH
rm -r ~/.config/sklink ~/.local/state/sklink   # manifest and state, if you're done
```

Because the reconciler prunes only what it created, this leaves any hand-placed
skills in your agent directories untouched. `--uninstall` is equally careful: it
removes the symlink only if it still points at this checkout.

---

## Tests

```bash
bash sklink/scripts/test-sklink.sh
```

211 hermetic checks covering fan-out, pruning, idempotence, the non-symlink
guard, missing sources and missing project repos, orphan-free state, one broken
entry never stopping the rest of a run, the CLI (`add` validation, `rm`, dedup,
unterminated manifest, self-naming, reconciler resolution through a PATH
symlink), writing through a symlinked manifest without replacing it, manifest
defaulting and template creation (including "never overwrite" and the renamed
command), `list` grouping, `sync` change reporting / `-v` / `-q` / `--dry-run`,
`--print-plan`, `edit`, plain-text output off a terminal, every `doctor` verdict
(including an unreadable root and its exit codes), and the installer
(idempotence, `--name`, `--no-config`, the clobber guard, `--uninstall` refusing
a link it didn't make, and a half-copied checkout). The suite runs entirely
inside a temp workspace via `SKLINK_MANIFEST` / `SKLINK_ROOTS` /
`XDG_CONFIG_HOME` / `XDG_STATE_HOME` and installs only into that workspace, so
it never touches your real agent directories, your config, or your `PATH`.

---

## License

MIT — see [LICENSE](../LICENSE).
