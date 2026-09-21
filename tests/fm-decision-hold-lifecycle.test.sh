#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}


# A captain hold closed by hand - a plain tasks-axi done plus a hand-written note -
# satisfies neither shape verify_hold_durable accepts, so scout teardown stays
# blocked forever. repair is the supported stamp that makes the closed record
# durable again without loosening that gate.
test_repair_stamps_a_hand_closed_captain_decision() {
  local home id hold show json
  home=$(make_home repair-hand-closed)
  id=sample-hand-closed-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample hand-closed decision" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create hand-closed origin fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample hand-closed review\n\nOne captain choice was answered outside the lifecycle.\n' \
    > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register the route hold"
  run_decisions "$home" complete "$id" route >/dev/null \
    || fail "could not record the decision inventory"
  assert_grep "decision_keys=route" "$home/state/$id.meta" "inventory fixture did not record the key"
  tasks_in "$home" add sample-hand-route-impl "Apply the hand-chosen sample route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create dependent work fixture"

  # The exact observed loss: closed outside the script, with prose instead of the
  # script's own attestation, and the dependency edge left stuck behind it.
  tasks_in "$home" update "$hold" --body "Captain chose route north on 2026-09-17." >/dev/null \
    || fail "could not write the hand-written closure note"
  tasks_in "$home" unhold "$hold" >/dev/null || fail "could not release the hold by hand"
  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not close the hold by hand"
  if run_decisions "$home" verify "$id" > "$home/pre-verify.out" 2> "$home/pre-verify.err"; then
    fail "verify accepted a hand-closed captain record without the script's attestation"
  fi
  assert_grep "neither actively held nor durably resolved" "$home/pre-verify.err" \
    "the durable-record gate must stay strict for a hand-closed record"
  show=$(tasks_in "$home" show sample-hand-route-impl --full)
  assert_contains "$show" "blocked-by:$hold" \
    "the hand-closed fixture must leave its recorded dependency edge behind"
  if run_teardown "$home" "$id" > "$home/pre-teardown.out" 2> "$home/pre-teardown.err"; then
    fail "teardown proceeded while the hand-closed record was unverifiable"
  fi
  if run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample \
    > "$home/reopen.out" 2> "$home/reopen.err"; then
    fail "hold reopened an already-closed identity"
  fi
  printf 'Use route north for the sample system.\n' > "$home/hand-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/hand-decision.txt" \
    --routed-to sample-hand-route-impl > "$home/closed-resolve.out" 2> "$home/closed-resolve.err"; then
    fail "resolve closed an already-closed identity"
  fi

  run_decisions "$home" repair "$id" route --decision-file "$home/hand-decision.txt" \
    --routed-to sample-hand-route-impl >/dev/null \
    || fail "repair could not stamp the hand-closed captain decision"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verify still refused an origin whose metadata records the repaired key"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "repair reopened the closed record"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "repair did not stamp the attestation"
  assert_contains "$show" "closed outside fm-decision-hold" "repair did not state which fact it stamped"
  assert_contains "$show" "Use route north for the sample system." "repair lost the durable decision record"
  assert_grep "Captain chose route north on 2026-09-17." "$home/data/note-archive.md" \
    "repair discarded the superseded hand-written note"
  show=$(tasks_in "$home" show sample-hand-route-impl --full)
  assert_contains "$show" "deps: none" "repair left the recorded dependency edge in place"
  json=$(run_bearings "$home") || fail "Bearings failed after the repair"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold) | not
  ' >/dev/null || fail "a repaired decision still surfaced as an open captain call: $json"

  run_decisions "$home" repair "$id" route --decision-file "$home/hand-decision.txt" \
    --routed-to sample-hand-route-impl >/dev/null \
    || fail "an identical repair retry was not idempotent"
  printf 'Use route south for the sample system.\n' > "$home/changed-hand-decision.txt"
  if run_decisions "$home" repair "$id" route --decision-file "$home/changed-hand-decision.txt" \
    --routed-to sample-hand-route-impl > "$home/drift-decision.out" 2> "$home/drift-decision.err"; then
    fail "a repair retry accepted a different captain decision"
  fi
  assert_grep "records a different captain decision" "$home/drift-decision.err" \
    "a conflicting decision retry must fail loudly"
  tasks_in "$home" add sample-hand-route-followup "Check the hand-chosen sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create the second dependent fixture"
  if run_decisions "$home" repair "$id" route --decision-file "$home/hand-decision.txt" \
    --routed-to sample-hand-route-impl --routed-to sample-hand-route-followup \
    > "$home/drift-routes.out" 2> "$home/drift-routes.err"; then
    fail "a repair retry accepted a different routed task set"
  fi
  assert_grep "records different routed work" "$home/drift-routes.err" \
    "a conflicting routed-set retry must fail loudly"
  printf 'The key never carried a captain decision.\n' > "$home/hand-note.txt"
  if run_decisions "$home" repair "$id" route --never-a-decision --note-file "$home/hand-note.txt" \
    > "$home/drift-kind.out" 2> "$home/drift-kind.err"; then
    fail "a repair retry voided a stamped real decision as a never-a-decision key"
  fi
  assert_grep "different resolution record" "$home/drift-kind.err" \
    "a conflicting repair-kind retry must fail loudly"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the repair: $(cat "$home/teardown.err")"
  pass "repair stamps a hand-closed captain decision, is idempotent, and refuses conflicting retries"
}

# The cyb40-decision-default shape: a key that was closed by hand and never
# carried a captain decision at all. Recording that is a distinct explicit input
# and must never be implied by, or imply, a real decision record.
test_repair_records_a_key_that_was_never_a_decision() {
  local home id hold show
  home=$(make_home repair-never-a-decision)
  id=sample-placeholder-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample placeholder key" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create placeholder origin fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample placeholder review\n\nThe placeholder key never needed a captain choice.\n' \
    > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" default \
    --title "Choose the sample default" --reason "placeholder captain choice" --repo sample) \
    || fail "could not register the placeholder hold"
  run_decisions "$home" complete "$id" default >/dev/null \
    || fail "could not record the placeholder inventory"
  tasks_in "$home" unhold "$hold" >/dev/null || fail "could not release the placeholder by hand"
  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not close the placeholder by hand"
  if run_decisions "$home" verify "$id" > "$home/pre-verify.out" 2> "$home/pre-verify.err"; then
    fail "verify accepted a hand-closed placeholder without the script's attestation"
  fi

  printf 'The default key was an unkeyed status artifact, not a captain choice.\n' \
    > "$home/placeholder-note.txt"
  printf 'Pick the sample default.\n' > "$home/placeholder-decision.txt"
  if run_decisions "$home" repair "$id" default --never-a-decision \
    --decision-file "$home/placeholder-decision.txt" \
    > "$home/mixed-decision.out" 2> "$home/mixed-decision.err"; then
    fail "a never-a-decision repair accepted a captain decision record"
  fi
  if run_decisions "$home" repair "$id" default --never-a-decision \
    --note-file "$home/placeholder-note.txt" --routed-to "$id" \
    > "$home/mixed-routes.out" 2> "$home/mixed-routes.err"; then
    fail "a never-a-decision repair accepted routed work"
  fi
  if run_decisions "$home" repair "$id" default --note-file "$home/placeholder-note.txt" \
    > "$home/implied-never.out" 2> "$home/implied-never.err"; then
    fail "a note file alone implied a never-a-decision repair"
  fi
  if run_decisions "$home" repair "$id" default --never-a-decision \
    > "$home/missing-note.out" 2> "$home/missing-note.err"; then
    fail "a never-a-decision repair accepted no durable record at all"
  fi

  run_decisions "$home" repair "$id" default --never-a-decision \
    --note-file "$home/placeholder-note.txt" >/dev/null \
    || fail "repair could not record a key that was never a captain decision"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verify still refused an origin whose metadata records the repaired placeholder key"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the placeholder repair reopened the closed record"
  assert_contains "$show" "never a captain decision" \
    "the placeholder repair did not state which fact it stamped"
  assert_not_contains "$show" "closed outside fm-decision-hold" \
    "the placeholder repair claimed a real captain decision"
  run_decisions "$home" repair "$id" default --never-a-decision \
    --note-file "$home/placeholder-note.txt" >/dev/null \
    || fail "an identical placeholder repair retry was not idempotent"
  printf 'A different account of the placeholder key.\n' > "$home/changed-note.txt"
  if run_decisions "$home" repair "$id" default --never-a-decision \
    --note-file "$home/changed-note.txt" > "$home/note-drift.out" 2> "$home/note-drift.err"; then
    fail "a placeholder repair retry accepted a different durable record"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the placeholder repair: $(cat "$home/teardown.err")"
  pass "repair records a never-a-decision key distinctly and never implies a real decision"
}

# repair must never become a way to void an open decision, adopt a foreign
# identity, or restamp a record resolve already closed correctly.
test_repair_refuses_open_missing_and_non_captain_identities() {
  local home id hold show
  home=$(make_home repair-refusals)
  id=sample-refusal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample repair refusals" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create refusal origin fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample refusal review\n\nOne open choice, one absent key, one foreign identity.\n' \
    > "$home/data/$id/report.md"
  printf 'Pick the sample refusal route.\n' > "$home/refusal-decision.txt"

  hold=$(run_decisions "$home" hold "$id" open-choice \
    --title "Choose the sample refusal route" --reason "captain refusal choice pending" --repo sample) \
    || fail "could not register the open hold"
  tasks_in "$home" add sample-refusal-impl "Apply the sample refusal route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the refusal dependent"
  if run_decisions "$home" repair "$id" open-choice --decision-file "$home/refusal-decision.txt" \
    --routed-to sample-refusal-impl > "$home/open.out" 2> "$home/open.err"; then
    fail "repair voided a genuinely open captain decision"
  fi
  assert_grep "is not closed" "$home/open.err" "an open identity must be refused as not closed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "the refused repair closed an open hold"
  assert_contains "$show" "held: yes" "the refused repair released an open hold"
  show=$(tasks_in "$home" show sample-refusal-impl --full)
  assert_contains "$show" "blocked: yes" "the refused repair cleared an open decision's dependency edge"

  if run_decisions "$home" repair "$id" absent-choice --decision-file "$home/refusal-decision.txt" \
    --routed-to sample-refusal-impl > "$home/absent.out" 2> "$home/absent.err"; then
    fail "repair invented a record for an identity that does not exist"
  fi
  assert_grep "is absent from" "$home/absent.err" "a missing identity must be refused as absent"
  assert_no_grep "$id-decision-absent-choice" "$home/data/backlog.md" \
    "the refused repair created a backlog identity"

  tasks_in "$home" add "$id-decision-ship-choice" "A foreign ship identity" \
    --kind ship --repo sample >/dev/null || fail "could not create the foreign identity fixture"
  tasks_in "$home" "done" "$id-decision-ship-choice" >/dev/null \
    || fail "could not close the foreign identity fixture"
  if run_decisions "$home" repair "$id" ship-choice --decision-file "$home/refusal-decision.txt" \
    --routed-to sample-refusal-impl > "$home/foreign.out" 2> "$home/foreign.err"; then
    fail "repair stamped a captain attestation onto a non-captain identity"
  fi
  assert_grep "is not kind captain" "$home/foreign.err" "a non-captain identity must be refused by kind"
  show=$(tasks_in "$home" show "$id-decision-ship-choice" --full)
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "the refused repair wrote an attestation onto a non-captain identity"

  hold=$(run_decisions "$home" hold "$id" dep-choice \
    --title "Choose the sample dependent route" --reason "captain dependent choice pending" --repo sample) \
    || fail "could not register the dependent-check hold"
  tasks_in "$home" unhold "$hold" >/dev/null || fail "could not release the dependent-check hold"
  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not close the dependent-check hold"
  if run_decisions "$home" repair "$id" dep-choice --decision-file "$home/refusal-decision.txt" \
    --routed-to sample-missing-dependent > "$home/missing-dep.out" 2> "$home/missing-dep.err"; then
    fail "repair recorded routed work that does not exist"
  fi
  assert_grep "does not exist in the active home" "$home/missing-dep.err" \
    "absent routed work must be refused by identity"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "the refused repair stamped an attestation despite absent routed work"

  run_decisions "$home" resolve "$id" open-choice --decision-file "$home/refusal-decision.txt" \
    --routed-to sample-refusal-impl >/dev/null \
    || fail "could not resolve the open decision through the ordinary path"
  if run_decisions "$home" repair "$id" open-choice --decision-file "$home/refusal-decision.txt" \
    --routed-to sample-refusal-impl > "$home/restamp.out" 2> "$home/restamp.err"; then
    fail "repair restamped a record that resolve had already closed correctly"
  fi
  assert_grep "different resolution record" "$home/restamp.err" \
    "a resolve-written record must not be silently repaired"
  pass "repair refuses open, absent, non-captain, and already-resolved identities"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_repair_stamps_a_hand_closed_captain_decision
test_repair_records_a_key_that_was_never_a_decision
test_repair_refuses_open_missing_and_non_captain_identities
