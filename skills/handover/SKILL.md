---
name: handover
description: Packages a session's irrecoverable context — decisions, failed approaches, constraints — into a portable handover artifact outside the repo, and loads one to pick up later. Use when the user says handover, hand off, save the session, resume, or pick up where we left off.
license: MIT
---

# Handover

Two modes, one portable artifact. **Produce** (default) packages the session into curated markdown saved outside the repo — no transcript capture, session resurrection, or workspace snapshotting. **Resume** loads an artifact for the current repo and summarizes the pickup point.

The hard part of a handover is not workspace state — the next agent can re-run `git status` itself. The **irrecoverable** part is conversation state: decisions and their rationale, rejected alternatives, constraints the user voiced, dead ends already explored. Capture the irrecoverable first; let the scripts capture the rest. (Install and store layout: see [README.md](README.md).)

## Command surface

Use the wrapper first; it delegates to the deterministic scripts in this folder:

```bash
scripts/handover.sh path .                  # print (and create) the store dir
scripts/handover.sh save .                  # stdin -> timestamped artifact; prints saved path
scripts/handover.sh latest .                # print path of newest artifact
scripts/handover.sh list .                  # list artifact paths, newest first
scripts/handover.sh state . [since-ref]     # print workspace snapshot
```

`latest` resolves the newest artifact produced in the current worktree; if that worktree has none, it falls back to the repo's newest and prints a note on stderr naming the worktree that produced it and whether that directory still exists. Both steps consider every artifact, named or not, so `latest` and `list` never disagree. Use `--name NAME` only when several workstreams in one repo need separate threads; it narrows `save`, `latest`, and `list` to that thread and, being an explicit selector, skips the worktree preference. Always set `HANDOVER_MODEL_NAME` to your model identifier — there is no auto-detection. Artifacts are stored outside the repo with private permissions, and `save` prepends a `handover-metadata` comment. See [README.md](README.md#configuration) for the full `--name` rules, store layout, and environment variables.

## Produce workflow

1. Identify the active objective, the latest user request, and constraints that still matter.
2. Snapshot the workspace — once per repo touched this session:

   ```bash
   scripts/handover.sh state <repo-path> [since-ref]
   ```

   Reports branch, HEAD, in-progress rebase/merge/cherry-pick, status, changed/staged/untracked files, diff stats, stashes, worktrees, recent commits, and the branch's open PR. Pass `since-ref` (e.g. `origin/main` or the session's starting sha) to list commits made this session.
3. Mine the conversation for the irrecoverable: every decision that changed direction, every approach that failed, every constraint the user voiced. Keep user-owned or pre-existing changes separate from this session's work when the distinction is known.
4. Capture verification reproducibly: exact command, working directory, prerequisites (env vars, running services, ports), and result — passed, failed with key detail, or skipped and why.
5. Fold unfinished session todos into Next steps. Note blockers honestly: missing credentials, approvals, failing tests, uncertain requirements, external state.
6. Before writing, confirm every irrecoverable item is in — anything reconstructible from Git, tests, command history, or source is padding, and the irrecoverable belongs first. Write the artifact (Output format below) to a temp file, then save it — the body is read from stdin: `HANDOVER_MODEL_NAME="<your-model>" scripts/handover.sh save <repo-path> < /tmp/handover.md`. Reply with the saved path plus a 3–5 line summary — not the full artifact — unless the user asks for it in chat or at a specific file path.

## Resume workflow

1. Locate the artifact: the path the user gave, else `scripts/handover.sh latest .` (or `--name NAME` when the user names a thread). When the pickup request names a topic rather than a path, run `scripts/handover.sh list .`, read the title line of each candidate, and offer a shortlist for the user to pick — do not guess. If none exists, say so and fall back to normal discovery — do not invent a prior session.
2. Read it. Compare the `Generated / Repo / Workspace / Model / Branch / HEAD / Dirty` stamp against the current workspace (re-run the snapshot script). If anything drifted, say exactly what, and re-verify the Workspace state and Verification sections before trusting them; the conversation-state sections (Conversation state that matters, Decisions, Failed approaches, Do NOT) remain valid. All worktrees of a repo share one store, so a loaded handover may have been produced in a different worktree. `latest` prefers this worktree's own and warns on stderr when it had to fall back; surface that warning, and confirm whether to switch to the named worktree before acting, since branch, HEAD, and uncommitted work are per-worktree. Check the metadata's `worktree` field (or `workspace-path` on older artifacts) when you were given an explicit path instead.
3. Honor Do NOT entries and do not retry Failed approaches without new information.
4. Summarize the objective, current state, drift, and recommended first action, then wait. Start work from "Resume here" only when the pickup request explicitly said to start or continue; confirm the objective first if the workspace drifted or the artifact is ambiguous.

## Output format

```markdown
# Handover: <repo or task name>
Generated: <UTC time> | Repo: <repo> | Workspace: <workspace> | Model: <model> | Branch: <branch> | HEAD: <short sha> | Dirty: <n files / clean>

## Objective
- <what this work is trying to achieve; the latest user request>

## Resume here
- First action: <exact command to run or file:line to open>
- Read first: <2-3 files that carry the mental model>

## Conversation state that matters
- User's real concern / stakeholder positions: <...>
- Accepted framing — and what was rejected, and why: <...>
- Wording or tone to preserve: <...>

## Completed this session
- <specific work done; mark pre-existing changes as such>

## Decisions
- <decision> — rejected <alternative> because <reason>

## Failed approaches
- <what was tried, how it failed, exact error when useful>

## Do NOT
- <constraints the user stated; things the next agent must not touch>

## Workspace state
- Uncommitted: <summary> | Stashes: <n> | In progress: <rebase/merge/none>
- Commits this session: <shas or none> | PR: <url or none>
- Important files: <paths>

## Verification
- `<command>` (in <dir>; needs <prereqs>): <passed/failed/skipped + key detail>

## Open issues
- <blockers, risks, unknowns>

## Next steps
1. <ordered, actionable; include unfinished todos>
```

Omit sections that are genuinely empty rather than padding them. "Conversation state that matters" appears only when the session's value was reasoning rather than code — translation, explanation, planning, review reasoning, stakeholder alignment, "what should I tell X" work — and then it carries the user's real concern, the framing accepted vs. rejected and why, and any wording or tone to preserve. See [EXAMPLES.md](EXAMPLES.md) for a filled artifact.

## Quality bar
- Prefer concrete paths, commands, branches, shas, ports, URLs, and exact error messages over general summaries.
- Use repository-relative paths for repo files — the stamp's Branch/HEAD anchors them, and all worktrees of a repo share one store. Reserve absolute paths for machine-local state (temp files, untracked scratch) and label them as such.
- Every command and path in the artifact must have actually been run or seen this session — never invent.
- Include failed attempts by default; they are the most expensive thing for the next agent to rediscover.
- Do not claim authorship of changes you did not make; say "pre-existing" when appropriate.
- No huge diffs, logs, secrets, tokens, `.env` values, raw transcripts, or tool session IDs.
- If no workspace is available, state that the handover is based only on conversation context.
