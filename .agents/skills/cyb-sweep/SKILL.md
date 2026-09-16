---
name: cyb-sweep
description: >-
  Sweep the full open CYB Jira story backlog and advance every story toward its next lifecycle step, behind a mandatory dry-run approval gate.
  Use when John invokes /cyb-sweep or asks to progress, advance, or sweep every open CYB story rather than a single task.
  Classifies every open story by its own technical reading into next-action, in-flight-steer, dependency-blocked, or decision-held, then dispatches independent work with no artificial concurrency cap while serializing only genuine dependencies, and surfaces every decision-held story on a live Lavish page.
user-invocable: true
metadata:
  internal: true
---

# cyb-sweep

Maximize real forward progress across every open CYB story in one pass.
Never merely summarize the backlog.
For every open story, classify it into exactly one of these four conditions and act accordingly:

- **next-action** - take its next executable lifecycle action.
- **in-flight-steer** - check and steer work already in flight.
- **dependency-blocked** - place it behind a genuine dependency.
- **decision-held** - hold it because it needs John's decision.

Use `AGENTS.md` section 7, especially the delivery-mode and yolo-posture rules, as the authoritative lifecycle and dispatch procedure.
Use the live Jira state, `data/backlog.md`, and `data/projects.md` as execution inputs.
If these sources conflict, follow `AGENTS.md` for operating procedure and the live Jira record for current ticket state, unless doing so would violate an explicit instruction in this skill.

## Scope

Process every open story in the CYB Jira project, including stories already marked `hold_kind: captain`.
Do not advance a captain-held story; include it in the Decision List instead.

## Phase 1: mandatory dry run

The dry run is a required approval gate.
Before dispatching, editing Jira, or creating any crewmate, classify every open story into exactly one of next-action, in-flight-steer, dependency-blocked, or decision-held using your own technical reading, without acting on any of them.

No execution activity may occur before John approves, including:

- dispatching crewmates;
- creating worktrees;
- launching ship or scout tasks;
- editing Jira fields;
- creating Jira issue links;
- changing hold status;
- opening pull requests;
- modifying infrastructure;
- updating repositories;
- performing automated remediation.

The sole purpose of the dry run is to expose the complete planned blast radius before any action occurs.

Report to John using plain-language outcomes, per `AGENTS.md` section 9's translation rule, never the raw classification labels next-action, in-flight-steer, dependency-blocked, or decision-held:

- total open story count;
- count and list of story keys in each condition, described as: dispatched to its next step (next-action), checked and steered (in-flight-steer), waiting on a dependency (dependency-blocked), and needing your decision (decision-held);
- for stories waiting on a dependency, the dependency in plain terms;
- for stories needing a decision, a preview count only, full detail comes later in the Decision List.

Default approval is all-at-once: once John approves the dry-run summary, proceed with every classified story under the rules below.
If anything about scope or approval is ambiguous when you reach it, ask John directly rather than assuming.
Re-running the dry run does not require reprocessing stories already confirmed and dispatched in a prior pass.

## Progress, once the dry run is approved

Progress means an actual next-step action, not a status report.

- For queued or ready work: resolve its delivery mode and yolo posture, move it to the proper lifecycle state, and dispatch the appropriate crewmate.
- For in-flight work: inspect its current state and outputs, then steer, unblock, retry, redirect, or escalate it as appropriate.
- Scout work counts as progress only when investigation is the correct next lifecycle action or is necessary to make shipping work executable.
- Do not substitute investigation for implementation when the story is already sufficiently defined to ship.
- Update Jira before the first shipping edit whenever the lifecycle rules require it.
- Do not report a result as complete or passing until the required verification has actually run.

## Dependencies and concurrency

Follow `AGENTS.md` section 7's concurrency rule: dispatch isolated work with no artificial concurrency cap, and serialize only for a true dependency or unsafe shared-surface conflict, never for mere file, product, repository, or team overlap.
cyb-sweep adds these CYB/Jira-specific rules on top of it:

- Determine dependencies from your own technical reading of each story, its acceptance criteria, affected systems, project artifacts, and expected outputs; Jira's existing Blocked-by, Depends-on, or similar fields are evidence, not the source of truth.
- Treat same-surface ordering conflicts, including ZIA policy or rule-order interactions, as dependencies when concurrent execution could produce an invalid, conflicting, or incorrectly ordered result.
- Before creating a Jira dependency link, verify that the dependency is real and that an equivalent link does not already exist.
- If a genuine dependency is missing from Jira, create the appropriate issue link immediately.
- If an existing Jira dependency appears incorrect or stale, do not let it control execution; record the discrepancy without deleting or altering the existing link unless the governing instructions explicitly authorize that change.
- A story waiting on another story is dependency-blocked, not decision-held, unless choosing how to resolve the dependency requires John's judgment.

## Decision hold rule

Load `decision-hold-lifecycle` before treating any decision-held story as resolved: it is the single policy owner for unresolved John decisions discovered by this sweep, and this rule operates under its Operating sequence rather than a separate hold/resolve scheme.

The moment a story requires John's decision, approval, prioritization, risk acceptance, business judgment, security judgment, or information only John can provide:

1. stop advancing that story immediately;
2. do not assume or choose an answer for John;
3. preserve completed, safe work already performed;
4. register the decision with `bin/fm-decision-hold.sh hold <origin-id> <decision-key> --title <title> --reason <reason> --repo <repo>`, per `decision-hold-lifecycle`'s Operating sequence step 3, and mark or retain the story as `hold_kind: captain` under the resulting `<origin-id>-decision-<decision-key>` identity;
5. add it to the Decision List, using that same identity as the decision's stable ID.

Apply this rule both to stories already held for John's decision and to decision points discovered during execution.
Continue advancing every other independent story while decision-held stories wait.

After the sweep's classification pass finishes, run `bin/fm-decision-hold.sh complete <origin-id>` with the full inventory of unresolved decision keys found in that pass, or `--none` when the pass found no unresolved decision, per `decision-hold-lifecycle`'s Operating sequence step 4.

## Decision List

Maintain one complete, deduplicated Decision List covering every open story currently waiting on John's input.
Give each decision the stable `<origin-id>-decision-<decision-key>` identity established by `bin/fm-decision-hold.sh hold`; do not invent a separate ID scheme.
If multiple stories require the same decision, combine them only when one answer will resolve all of them, and list every affected Jira key.

For each decision include only:

- ID
- Jira story or affected stories
- Decision needed
- Minimum context necessary to decide
- Options, only when the available choices are known and materially useful

Keep every entry as brief as possible while still allowing John to decide without reopening the full story.

## Lavish interaction

Generate the Decision List as a live HTML page rendering the current structured hold set that `bin/fm-decision-hold.sh` and Bearings read, not a parallel list cyb-sweep maintains itself.
Open it with Lavish, per `~/.claude/rules/tools.md`'s Lavish conventions (open once, then edit-and-poll, never re-open).
Poll the Lavish page for John's responses.
When John answers a decision:

1. put John's exact durable decision in a file or project artifact;
2. resolve the hold with `bin/fm-decision-hold.sh resolve <origin-id> <decision-key> --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]`, which clears the dependent-work blocking edges before closing the hold; never toggle `hold_kind: captain` by hand;
3. resume the story from its next executable lifecycle step;
4. update the Lavish page so it continues to show the complete set of unresolved decisions.

Do not block independent backlog work while waiting on John's Lavish responses.

## Completion criteria

Do not declare the sweep complete until every open CYB story has been examined and is in exactly one of these conditions:

- a concrete lifecycle action was taken or dispatched;
- existing in-flight work was checked and appropriately steered;
- the story is waiting on a verified genuine dependency;
- the story is held on a clearly identified decision in the Lavish Decision List;
- the story reached completion and passed its required verification.

At the end, give John a concise execution summary with counts by condition and links or identifiers for dispatched work, newly created Jira dependency links, and unresolved decision IDs.
Do not repeat the full decision context outside the Lavish page.
