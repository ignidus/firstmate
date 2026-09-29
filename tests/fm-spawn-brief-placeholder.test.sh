#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's unfilled-brief-placeholder refusal.
#
# A brief still holding a scaffold placeholder such as {TASK} must refuse before
# any endpoint, launch, or task metadata exists, naming the token and the brief
# path. Explanatory mentions in inline code spans (the scaffold's own Herdr
# safety-gate prose), fenced code blocks, and shell ${NAME} expansions must not
# refuse. Spawns run against a fake tmux and a real isolated git worktree, so no
# real harness starts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF_SCAFFOLD="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-brief-placeholder)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Sets CASE_HOME, CASE_PROJ, CASE_WT, CASE_FAKEBIN, CASE_LAUNCH_LOG.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_HOME="$case_dir/home"
  CASE_PROJ="$case_dir/project"
  CASE_WT="$case_dir/wt"
  CASE_LAUNCH_LOG="$case_dir/launch.log"
  CASE_FAKEBIN=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$CASE_HOME/data" "$CASE_HOME/projects" "$CASE_HOME/state" "$CASE_HOME/config"
  printf 'claude\n' > "$CASE_HOME/config/crew-harness"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "wt-$name"
  touch "$CASE_HOME/state/.last-watcher-beat"
  : > "$CASE_LAUNCH_LOG"
}

# Scaffold a real ship brief for <id> in the current case home.
scaffold_brief() {
  local id=$1
  FM_HOME="$CASE_HOME" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    "$BRIEF_SCAFFOLD" "$id" project --mode no-mistakes >/dev/null \
    || fail "fm-brief.sh could not scaffold $id"
}

# Replace the scaffold's standalone {TASK} line with <text>.
fill_task() {
  local brief=$1 text=$2 tmp
  tmp="$brief.tmp"
  awk -v text="$text" '$0 == "{TASK}" { print text; next } { print }' "$brief" > "$tmp"
  mv "$tmp" "$brief"
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CASE_WT" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$CASE_LAUNCH_LOG" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$CASE_PROJ" --mode no-mistakes --yolo off 2>&1
}

assert_refused_before_launch() {
  local id=$1 out=$2 status=$3 token=$4 brief
  brief="$CASE_HOME/data/$id/brief.md"
  expect_code 1 "$status" "$id: spawn with unfilled $token should refuse"
  assert_contains "$out" "$token" "$id: refusal did not name $token"
  assert_contains "$out" "$brief" "$id: refusal did not name the brief path"
  assert_absent "$CASE_HOME/state/$id.meta" "$id: refused spawn still wrote task metadata"
  [ ! -s "$CASE_LAUNCH_LOG" ] || fail "$id: refused spawn still sent a launch command"
}

test_filled_brief_spawns() {
  local id=placeholder-filled-a1 out status
  make_case filled
  scaffold_brief "$id"
  fill_task "$CASE_HOME/data/$id/brief.md" "Fix the widget so it stops crashing."
  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "filled brief should spawn"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude" "filled brief did not report a spawn"
  pass "a filled brief spawns normally"
}

test_unfilled_task_refuses() {
  local id=placeholder-task-b2 out status
  make_case unfilled-task
  scaffold_brief "$id"
  out=$(run_spawn "$id")
  status=$?
  assert_refused_before_launch "$id" "$out" "$status" "{TASK}"
  pass "an unfilled {TASK} placeholder refuses before launch, naming the token and brief"
}

test_unfilled_secondmate_projects_refuses() {
  local id=placeholder-projects-c3 out status
  make_case unfilled-projects
  scaffold_brief "$id"
  fill_task "$CASE_HOME/data/$id/brief.md" "Seed the home with {SECONDMATE_PROJECTS} before launch."
  out=$(run_spawn "$id")
  status=$?
  assert_refused_before_launch "$id" "$out" "$status" "{SECONDMATE_PROJECTS}"
  assert_not_contains "$out" "{TASK}" "$id: refusal named a {TASK} token that was already filled"
  pass "an unfilled {SECONDMATE_PROJECTS} placeholder refuses before launch"
}

test_explanatory_mentions_do_not_refuse() {
  local id=placeholder-prose-d4 brief out status
  make_case prose
  scaffold_brief "$id"
  brief="$CASE_HOME/data/$id/brief.md"
  # The scaffold's own Herdr gate prose mentions the placeholder in backticks.
  # shellcheck disable=SC2016  # literal backticks are the scaffold's inline-code span.
  assert_grep 'replaces `{TASK}` later' "$brief" "scaffold no longer carries the Herdr gate prose this test depends on"
  # shellcheck disable=SC2016  # literal backticks are the inline-code spans under test.
  fill_task "$brief" 'Document why fm-brief.sh emits `{TASK}` and ``{SECONDMATE_PROJECTS}`` placeholders.'
  cat >> "$brief" <<'EOF'
Shell expansions such as "${SECONDMATE_PROJECTS}" are not placeholders.
```
echo "{TASK}"
```
EOF
  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "explanatory placeholder mentions should not refuse"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude" "prose-mention brief did not report a spawn"
  pass "inline-code, fenced, and shell-expansion mentions do not refuse"
}

test_filled_brief_spawns
test_unfilled_task_refuses
test_unfilled_secondmate_projects_refuses
test_explanatory_mentions_do_not_refuse

echo "# all fm-spawn-brief-placeholder tests passed"
