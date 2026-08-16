# Installing the gh-identity guard

Machine configuration an agent should never do on its own: registering
`gh-identity-guard.sh` as a `PreToolUse` hook, letting the live check reach the
credential store, and adding an account to the table it reads.

`/absolute/path/to/dev-public` below stands for your checkout. Substitute the real
path — every pattern matches the literal command string, so a placeholder left in
place matches nothing.

## 1. Create the identity table

```bash
/absolute/path/to/dev-public/skills/gh-identity/scripts/gh-identity-guard.sh --init
```

This copies the commented template to
`${XDG_CONFIG_HOME:-$HOME/.config}/gh-identity/identities.tsv`, and stops if that
file exists. Edit it before going further: until it holds at least one uncommented
row, the hook denies every `gh` command that could act on a repository — correct
(an unconfigured guard must not fall back to the active account) but not useful.
Column meanings: [README.md](README.md#the-identity-table).

## 2. Install the skill

```bash
ln -s /absolute/path/to/dev-public/skills/gh-identity ~/.claude/skills/gh-identity
```

Or let [`sklink`](../../sklink/README.md) maintain the links:

```bash
sklink add /absolute/path/to/dev-public/skills/gh-identity --user
```

## 3. Register the hook

Claude Code and Codex implement the same `PreToolUse` contract — stdin JSON
carrying `cwd` and `tool_input.command`, a deny returned as
`hookSpecificOutput.permissionDecision: "deny"` with a `permissionDecisionReason`
— so one script serves both, unmodified.

| Agent | Config file | Registered under |
|-------|-------------|------------------|
| Claude Code | `~/.claude/settings.json` | `hooks.PreToolUse` |
| Codex | `~/.codex/hooks.json` (or inline `[hooks]` in `~/.codex/config.toml`) | `hooks.PreToolUse` |

Same shape in both. Append it as its own matcher group rather than editing an
existing one, so other hooks keep their handlers:

```json
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": "/absolute/path/to/dev-public/skills/gh-identity/scripts/gh-identity-guard.sh"
    }
  ]
}
```

Use the checkout path, not a symlinked copy under a skills directory — it is the
one that stays valid if the skill is unlinked.

## 4. Let `--check` reach the credential store

Each alias resolves its own token from the credential store the GitHub CLI uses
(the login keychain on macOS). The `gh` binary may already run outside your
agent's sandbox, but invoking this wrapper by path is a different command and
needs its own narrow exemption. Without it, `--check` reports `UNVERIFIED` with
`no oauth token found` even while `gh auth status` shows the account logged in.

Claude Code — merge into `sandbox.excludedCommands` in `~/.claude/settings.json`:

```json
{
  "sandbox": {
    "excludedCommands": [
      "/absolute/path/to/dev-public/skills/gh-identity/scripts/gh-identity-guard.sh *"
    ]
  }
}
```

Codex — add to `~/.codex/rules/default.rules`, then restart Codex:

```python
prefix_rule(
    pattern = ["/absolute/path/to/dev-public/skills/gh-identity/scripts/gh-identity-guard.sh"],
    decision = "allow",
    justification = "gh identity verification; needs credential-store access like gh itself",
)
```

Both match the literal command string, so the exemption fires only for this exact
absolute path — a `~/` prefix, a relative path, or a `bash <script>` prefix
silently misses it and the run stays sandboxed. That form is the invocation
contract in [SKILL.md](SKILL.md), and `scripts/test-gh-identity.sh` asserts the two
documents agree on it. Neither exemption broadens filesystem access for any other
command. See the
[Claude Code sandbox settings](https://code.claude.com/docs/en/settings#sandbox-settings)
and the [Codex rules documentation](https://learn.chatgpt.com/docs/agent-configuration/rules).

## 5. Codex only: trust the hook

Codex will not run a new or changed non-managed command hook until you review it
under `/hooks` and trust it. Trust covers the hook configuration including its
command string, not the contents of the executable it names — so editing
`gh-identity-guard.sh` in place does not trigger re-review.

## 6. Verify

```bash
# should print a deny reason naming the repository's alias
jq -n '{tool_name:"Bash",cwd:"'"$HOME"'/some/repo",
        tool_input:{command:"gh pr create"}}' \
  | /absolute/path/to/dev-public/skills/gh-identity/scripts/gh-identity-guard.sh

# should print nothing (allowed)
jq -n '{tool_name:"Bash",cwd:"'"$HOME"'/some/repo",
        tool_input:{command:"gh personal pr create"}}' \
  | /absolute/path/to/dev-public/skills/gh-identity/scripts/gh-identity-guard.sh

# the full matrix
bash /absolute/path/to/dev-public/skills/gh-identity/scripts/test-gh-identity.sh
```

## Adding an identity

Account configuration, so this is operator work — `SKILL.md` tells the agent to
ask instead. Two files, in this order:

1. Create the alias in `~/.config/gh/config.yml`, resolving that account's own
   token rather than the active one:

   ```yaml
   aliases:
     personal: '!GH_TOKEN="$(gh auth token --hostname github.com --user octocat)" gh "$@"'
   ```

2. Add one row to the identity table:
   `<ssh-host> <owner> <gh-alias> <expected-login>`.

3. Confirm against a repository owned by that account, by absolute path so the
   sandbox exemption applies:

   ```bash
   /absolute/path/to/dev-public/skills/gh-identity/scripts/gh-identity-guard.sh --check <repo>
   ```

Nothing else needs editing — the skill, the hook and the `wt` integration all
resolve through that row.

## Deliberately no pre-filter

Claude Code supports `"if": "Bash(gh *)"` and Codex a narrower `matcher` regex.
Both would avoid spawning the script on unrelated commands. Neither is used: if a
pre-filter ever fails to recognise a `gh` invocation — behind an env assignment,
after `&&`, inside a subshell — the guard silently never runs, and a silent
guardrail is worse than none. The script exits within a few milliseconds on
non-`gh` commands.
