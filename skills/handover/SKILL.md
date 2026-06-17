---
name: handover
description: Packages a coding session's decisions, failed approaches, constraints, the reasoning and framing Git can't show, workspace state, and next steps into a portable handover artifact stored outside the repo, and loads the latest one to pick up later. Use when the user asks to hand off, save, summarize, or continue a session, types "handover", or asks to resume / "pick up where we left off" — in resume mode, load and summarize, then wait unless the user explicitly asks to start or continue.
license: MIT
---

# Handover

Two modes, one portable artifact. **Produce** (default) packages the session into curated markdown saved outside the repo — no transcript capture, session resurrection, or workspace snapshotting. **Resume** loads an artifact for the current repo, summarizes the pickup point, and waits unless the user explicitly asked to start or continue work.

The hard part of a handover is not workspace state — the next agent can re-run `git status` itself. The irrecoverable part is conversation state: decisions and their rationale, rejected alternatives, constraints the user voiced, dead ends already explored. Capture those first; let the scripts capture the rest. (Install and store layout: see [README.md](README.md).)

## Command surface

Use the wrapper first; it delegates to the deterministic scripts in this folder:

```bash
scripts/handover.sh path .                  # print (and create) the store dir
scripts/handover.sh save .                  # stdin -> timestamped artifact; prints saved path
scripts/handover.sh latest .                # print path of newest artifact
scripts/handover.sh list .                  # list artifact paths, newest first
scripts/handover.sh state . [since-ref]     # print workspace snapshot
```

Use `--name NAME` only when several workstreams in one repo need separate `latest` pointers (named saves track `latest-NAME.md`, unnamed track `latest.md`). Always set `HANDOVER_MODEL_NAME` to your model identifier — there is no auto-detection. Artifacts are stored outside the repo with private permissions, and `save` prepends a `handover-metadata` comment. See [README.md](README.md#configuration) for the full `--name` rules, store layout, and environment variables.

## Produce workflow

1. Identify the active objective, the latest user request, and constraints that still matter.
2. Snapshot the workspace — once per repo touched this session:

   ```bash
   scripts/handover.sh state <repo-path> [since-ref]
   ```

   Reports branch, HEAD, in-progress rebase/merge/cherry-pick, status, changed/staged/untracked files, diff stats, stashes, worktrees, recent commits, and the branch's open PR. Pass `since-ref` (e.g. `origin/main` or the session's starting sha) to list commits made this session.
3. From the conversation, collect what the workspace cannot show: decisions with the rejected alternative and the reason; approaches that failed and how; explicit "do not" constraints and user preferences. When the session's value is reasoning rather than code — translation, explanation, planning, review reasoning, stakeholder alignment, or "what should I tell X" work — also capture the user's real concern, the framing accepted vs. rejected and why, and any wording or tone to preserve, and put that block high (see Output format). Keep user-owned or pre-existing changes separate from this session's work when the distinction is known.
4. Capture verification reproducibly: exact command, working directory, prerequisites (env vars, running services, ports), and result — passed, failed with key detail, or skipped and why.
5. Fold unfinished session todos into Next steps. Note blockers honestly: missing credentials, approvals, failing tests, uncertain requirements, external state.
6. Before writing, ask what in this handover could not be reconstructed from Git, tests, command history, or source — those items belong first. Write the artifact (Output format below) to a temp file, then save it — the body is read from stdin: `HANDOVER_MODEL_NAME="<your-model>" scripts/handover.sh save <repo-path> < /tmp/handover.md`. Reply with the saved path plus a 3–5 line summary — not the full artifact — unless the user asks for it in chat or at a specific file path.

## Resume workflow

1. Locate the artifact: the path the user gave, else `scripts/handover.sh latest .` (or `--name NAME` when the user names a thread). If none exists, say so and fall back to normal discovery — do not invent a prior session.
2. Read it. Compare the `Generated / Repo / Workspace / Model / Branch / HEAD / Dirty` stamp against the current workspace (re-run the snapshot script). If anything drifted, say exactly what, and re-verify the Workspace state and Verification sections before trusting them; the conversation-state sections (Conversation state that matters, Decisions, Failed approaches, Do NOT) remain valid. All worktrees of a repo share one store, so a loaded handover may have been produced in a different worktree — if the metadata's `workspace` / `workspace-path` (or the stamp) names a directory other than the current one, say so and confirm whether to switch to that worktree before acting, since branch, HEAD, and uncommitted work are per-worktree.
3. Honor Do NOT entries and do not retry Failed approaches without new information.
4. If the user's pickup request explicitly says to start or continue work, start from "Resume here". Confirm the objective with the user only if the workspace drifted or the artifact is ambiguous.
5. If the user only asked to load, pick up, or resume context without explicitly asking to start work, do **not** begin the next step. Summarize the objective, current state, drift, and recommended first action, then wait for the user to say to proceed.

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

Omit sections that are genuinely empty rather than padding them — "Conversation state that matters" in particular appears only when the session's value is reasoning, framing, or stakeholder alignment, not for pure coding work. See [EXAMPLES.md](EXAMPLES.md) for a filled artifact.

## Quality bar
- Prefer concrete paths, commands, branches, shas, ports, URLs, and exact error messages over general summaries.
- Every command and path in the artifact must have actually been run or seen this session — never invent.
- Include failed attempts by default; they are the most expensive thing for the next agent to rediscover.
- Do not claim authorship of changes you did not make; say "pre-existing" when appropriate.
- No huge diffs, logs, secrets, tokens, `.env` values, raw transcripts, or tool session IDs.
- If no workspace is available, state that the handover is based only on conversation context.
