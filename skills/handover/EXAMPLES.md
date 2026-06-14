# Example handover artifact

A filled artifact at the expected quality bar. Note the concrete shas, exact
commands with prerequisites, the failed approach with its real error, and the
explicit Do NOT entries — these are what make the artifact resumable.

```markdown
# Handover: billing-service — webhook retry hardening
Generated: 2026-06-10T14:32:08Z | Repo: billing-service | Workspace: billing-platform | Model: claude-sonnet-4 | Branch: fix/webhook-retries | HEAD: 4ec6c04 | Dirty: 3 files

## Objective
- Make Stripe webhook handling idempotent so retried deliveries stop creating duplicate invoices (issue #482).

## Resume here
- First action: `pytest tests/webhooks/test_idempotency.py -x` — 2 of 6 tests still fail
- Read first: `app/webhooks/stripe_handler.py`, `app/models/processed_event.py`

## Completed this session
- Added `ProcessedEvent` model + migration `0042_processed_event.py` (applied locally)
- Wrapped handler in `select_for_update` dedup check (`stripe_handler.py:88-114`)
- The retry queue config in `settings/base.py` is pre-existing, not this session's work

## Decisions
- Dedup by Stripe `event.id` in Postgres — rejected Redis SETNX because retries can arrive after the 24h TTL we'd realistically set, and we already need the audit row
- Migration adds a plain unique index, not concurrent — table is empty in prod, confirmed via `psql` on 2026-06-10

## Failed approaches
- `@transaction.atomic` on the whole handler: deadlocks under the concurrent-retry test with `psycopg.errors.DeadlockDetected` — the Stripe API call inside the transaction holds the row lock too long. Moved the API call outside the transaction instead.

## Do NOT
- Do not bump the `stripe` package; user pinned 9.4.x until the Q3 platform upgrade
- Do not push — user wants to review the migration first

## Workspace state
- Uncommitted: handler + 2 test files | Stashes: 0 | In progress: none
- Commits this session: a91f3e2, 4ec6c04 | PR: none
- Important files: app/webhooks/stripe_handler.py, app/migrations/0042_processed_event.py

## Verification
- `pytest tests/webhooks/ -x` (in repo root; needs Postgres up via `docker compose up -d db`): failed — 2 failures in test_idempotency.py, both on the concurrent-retry case
- `ruff check app/`: passed

## Open issues
- Concurrent-retry test failures: suspect the dedup check races before the unique index commits; not yet confirmed
- Unknown whether Stripe ever reuses event ids across livemode/testmode — needs a docs check before merging

## Next steps
1. Fix the 2 failing concurrent-retry tests (likely move dedup insert before the API call)
2. Confirm Stripe event-id uniqueness across modes in their docs
3. Ask user to review migration 0042, then commit remaining changes
```
