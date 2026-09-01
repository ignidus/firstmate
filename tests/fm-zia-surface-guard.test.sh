#!/usr/bin/env bash
# tests/fm-zia-surface-guard.test.sh - fm-zia-surface-guard.sh must block a
# spawn whose requested ZIA policy surface(s) overlap an in-flight task's
# recorded surface(s), allow a disjoint request through, and record the
# surface on a successful spawn so the next check can see it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Build an isolated FM_HOME: bin/ holds the real guard script plus a fake
# fm-spawn.sh, state/ starts empty, projects/cyb-iac/.../zia_policy_surfaces.py
# holds a small real-shaped POLICY_SURFACES so the guard's own live-catalog
# read is exercised, not bypassed.
setup_home() {
  local home=$1
  mkdir -p "$home/bin" "$home/state" \
    "$home/projects/cyb-iac/zscaler/api-scope-probe"

  cp "$ROOT/bin/fm-zia-surface-guard.sh" "$home/bin/fm-zia-surface-guard.sh"
  chmod +x "$home/bin/fm-zia-surface-guard.sh"

  cat > "$home/projects/cyb-iac/zscaler/api-scope-probe/zia_policy_surfaces.py" <<'PY'
POLICY_SURFACES = {
    "url_filtering": {"human_name": "URL Filtering Policy"},
    "ssl_inspection": {"human_name": "SSL Inspection Policy"},
}
PY

  # Fake fm-spawn.sh: records that it ran, then writes a minimal meta file
  # keyed by its first positional arg (the task id), exactly like the real
  # spawn does before the guard appends zia_surfaces= to it.
  cat > "$home/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$SCRIPT_DIR/../state"
TASK_ID=$1
: > "$SCRIPT_DIR/../spawn-called"
{
  printf 'window=fake:w1\n'
  printf 'endpoint_task_id=%s\n' "$TASK_ID"
} > "$STATE/$TASK_ID.meta"
printf 'spawned %s (fake)\n' "$TASK_ID"
exit 0
SH
  chmod +x "$home/bin/fm-spawn.sh"
}

run_guard() {
  local home=$1
  shift
  (cd "$home" && "./bin/fm-zia-surface-guard.sh" "$@")
}

test_unknown_surface_refused() {
  local home
  home=$(fm_test_tmproot fm-zia-guard)
  setup_home "$home"

  local out status
  out=$(run_guard "$home" newtask bogus_surface -- newtask ignored --mode no-mistakes --yolo off 2>&1) && status=0 || status=$?

  expect_code 1 "$status" "unknown surface key must refuse"
  assert_contains "$out" "unknown surface key" "refusal must name the bad key"
  assert_absent "$home/spawn-called" "fm-spawn.sh must never run on an unknown surface key"
}

test_conflicting_surface_refused() {
  local home
  home=$(fm_test_tmproot fm-zia-guard)
  setup_home "$home"
  fm_write_meta "$home/state/other-task.meta" "endpoint_task_id=other-task" "zia_surfaces=url_filtering"

  local out status
  out=$(run_guard "$home" newtask url_filtering -- newtask ignored --mode no-mistakes --yolo off 2>&1) && status=0 || status=$?

  expect_code 1 "$status" "same-surface conflict must refuse"
  assert_contains "$out" "other-task" "refusal must name the conflicting task"
  assert_contains "$out" "url_filtering" "refusal must name the conflicting surface"
  assert_absent "$home/spawn-called" "fm-spawn.sh must never run on a real conflict"
  assert_absent "$home/state/newtask.meta" "no meta should exist for a refused spawn"
}

test_partial_overlap_in_multi_surface_request_refused() {
  local home
  home=$(fm_test_tmproot fm-zia-guard)
  setup_home "$home"
  fm_write_meta "$home/state/other-task.meta" "endpoint_task_id=other-task" "zia_surfaces=ssl_inspection"

  local status
  run_guard "$home" newtask "url_filtering,ssl_inspection" -- newtask ignored --mode no-mistakes --yolo off \
    >/dev/null 2>&1 && status=0 || status=$?

  expect_code 1 "$status" "requesting one conflicting surface among several must still refuse"
  assert_absent "$home/spawn-called" "fm-spawn.sh must never run when any requested surface conflicts"
}

test_disjoint_surface_allowed_and_recorded() {
  local home
  home=$(fm_test_tmproot fm-zia-guard)
  setup_home "$home"
  fm_write_meta "$home/state/other-task.meta" "endpoint_task_id=other-task" "zia_surfaces=ssl_inspection"

  local status
  run_guard "$home" newtask url_filtering -- newtask ignored --mode no-mistakes --yolo off \
    >/dev/null 2>&1 && status=0 || status=$?

  expect_code 0 "$status" "a disjoint surface request must be allowed through"
  assert_present "$home/spawn-called" "fm-spawn.sh must run when there is no conflict"
  assert_grep "zia_surfaces=url_filtering" "$home/state/newtask.meta" \
    "successful spawn must record its surface for the next check to see"
}

test_no_prior_tasks_allowed() {
  local home
  home=$(fm_test_tmproot fm-zia-guard)
  setup_home "$home"

  local status
  run_guard "$home" newtask url_filtering -- newtask ignored --mode no-mistakes --yolo off \
    >/dev/null 2>&1 && status=0 || status=$?

  expect_code 0 "$status" "an empty state dir has nothing to conflict with"
  assert_present "$home/spawn-called" "fm-spawn.sh must run with no in-flight tasks at all"
}

test_non_zia_meta_never_blocks() {
  local home
  home=$(fm_test_tmproot fm-zia-guard)
  setup_home "$home"
  fm_write_meta "$home/state/other-task.meta" "endpoint_task_id=other-task" "kind=ship"

  local status
  run_guard "$home" newtask url_filtering -- newtask ignored --mode no-mistakes --yolo off \
    >/dev/null 2>&1 && status=0 || status=$?

  expect_code 0 "$status" "a meta file with no zia_surfaces= line must never be read as a conflict"
  assert_present "$home/spawn-called" "fm-spawn.sh must run when no live task declares any ZIA surface"
}

test_missing_separator_is_a_usage_error() {
  local home
  home=$(fm_test_tmproot fm-zia-guard)
  setup_home "$home"

  local status
  run_guard "$home" newtask url_filtering newtask ignored \
    >/dev/null 2>&1 && status=0 || status=$?

  [ "$status" -ne 0 ] || fail "a missing '--' separator must not be accepted silently"
  assert_absent "$home/spawn-called" "fm-spawn.sh must never run on a malformed invocation"
}

test_unknown_surface_refused
pass "unknown surface key refused, fm-spawn.sh never invoked"

test_conflicting_surface_refused
pass "same-surface conflict refused, names the conflicting task and surface"

test_partial_overlap_in_multi_surface_request_refused
pass "one conflicting surface among several requested still refuses"

test_disjoint_surface_allowed_and_recorded
pass "disjoint surface request allowed through and recorded in the new task's meta"

test_no_prior_tasks_allowed
pass "no in-flight tasks means nothing to conflict with"

test_non_zia_meta_never_blocks
pass "a meta file with no zia_surfaces= line is never read as a conflict"

test_missing_separator_is_a_usage_error
pass "a missing '--' separator is rejected as a usage error, not run"
