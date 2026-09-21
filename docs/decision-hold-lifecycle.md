# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation, visual review, or backlog sweep pass's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

The `repair` subcommand is the only supported way to stamp that same attestation onto a captain identity that was already closed outside the script, which both `hold` and `resolve` refuse to touch.
It requires an existing kind `captain` identity that is already Done and reuses the `resolve` body and retry identity, so `verify` accepts the record afterwards without loosening any acceptance rule.
The body records which of two mutually exclusive facts is stamped: a real captain decision closed by hand, or, with `--never-a-decision` and its own `--note-file`, a key that never carried a captain decision at all.
Neither input is inferred from the other, and the two shapes cannot be combined.
It archives the superseded body, clears the dependency edge a hand-closed identity leaves recorded on routed work, and stamps the attestation last, so an interrupted repair leaves the record unstamped.
An identical retry is idempotent, while a retry recording a different decision, routed set, or repair kind fails.
A closed record carrying no attestation is still refused, so the durable-record gate keeps distinguishing a record written through the script from one somebody marked done.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Closed-record `repair` verification date: 2026-09-21.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The `repair` regression reproduces a captain hold closed by a plain `tasks-axi done` plus a hand-written note, confirms `verify` and scout teardown still refuse that unstamped record, and then covers stamping a real hand-closed decision, recording a key that never carried a decision, refusal on an open, absent, non-captain, or already-resolved identity, an idempotent identical retry, and a loud failure when a retry records a different decision, routed set, or repair kind.
It also proves an origin whose metadata still lists the stale key passes `verify` after the repair without any metadata rewrite.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - repair stamps a hand-closed captain decision, is idempotent, and refuses conflicting retries
ok - repair records a never-a-decision key distinctly and never implies a real decision
ok - repair refuses open, absent, non-captain, and already-resolved identities

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
ok - local-only worktree with HEAD on a fork remote is torn down (fix holds)
ok - teardown prompts tasks-axi backlog refresh when compatible
ok - teardown honors config/backlog-backend=manual even when tasks-axi is compatible
ok - local-only worktree with truly unpushed work is refused (safety preserved)
ok - local-only worktree with work merged into local main is torn down (no regression)
ok - no-mistakes worktree with HEAD on origin is torn down (no regression)
ok - no-mistakes worktree with genuinely unlanded work is refused (safety preserved)
ok - local-only worktree with unpushed work is torn down under --force (escape hatch)
ok - teardown completes when an exact busy-state sidecar is already absent
ok - herdr teardown removes pane-owned escalation dedupe state
ok - herdr flat teardown refuses before returning the isolated copy under lock contention and the retry completes cleanly
ok - herdr flat teardown never erases records when pane presence is unparseable
not ok - herdr-preflight-missing-adapter: the retryable pre-return refusal was not explained visibly

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=62 local_links=178

$ git diff --check
(no output)
```

The one `not ok` line above is an unrelated pre-existing failure in the Herdr preflight case, not a decision-hold regression.
It reproduces identically on the base commit `c422878` from a pristine `git archive HEAD` export, so no decision-hold change introduced or masks it.
