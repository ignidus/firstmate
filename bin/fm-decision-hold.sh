#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh repair <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh repair <origin-id> <decision-key> \
#     --never-a-decision --note-file <path>
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
#
# `repair` is the only supported way to stamp this script's attestation onto a
# captain identity that was already closed outside this script, which `hold` and
# `resolve` both refuse to touch. It requires an existing kind `captain` identity
# that is already Done, takes the durable record and routed work exactly as
# `resolve` does, and reuses the same attestation body and retry identity so
# `verify` accepts the record afterwards. The body records which of two mutually
# exclusive facts is being stamped: a real captain decision closed by hand, or,
# with --never-a-decision and its own --note-file, a closed key that never carried
# a captain decision at all. Neither input is ever inferred from the other, and the
# two shapes cannot be combined. `repair` refuses an absent, non-captain, or
# still-open identity, so a genuinely open decision still goes through `resolve`.
# It requires every --routed-to task to exist but not to still be blocked, clears
# the dependency edge each routed task still records for the closed identity,
# archives the superseded body, and stamps the attestation last so a failure
# before that leaves the record unstamped. An identical retry is idempotent; a
# retry recording a different decision, routed set, or repair kind fails.
#
# Every decision identity, and every identity `repair` routes to, resolves to its
# newest record: the active backlog first, then the markdown `archive` that the
# active FM_HOME's `.tasks.toml` declares, because retention archives closed rows
# rather than deleting them and `tasks-axi show` reads only the active backlog.
# The archive is an append-only log of `## ` sections that `show` does not index,
# so each section mentioning the identity is rewritten under the active backlog's
# three section headings and parsed by tasks-axi itself, newest section first.
# Only checked rows parse under `## Done`, so an archived record can only ever meet
# the durably-resolved shape; an unchecked row a non-default prune archived stays
# unreadable. `resolve` still requires its routed work in the active backlog.
# tasks-axi never rewrites the archive, so `repair` stamps an archived identity by
# appending a new snapshot: that newest section is reduced to the one row with
# tasks-axi rm, stamped with tasks-axi update, and appended to the same archive by
# `tasks-axi prune --keep 0`, which is the stamp's only durable write. The earlier
# unstamped snapshot stays in the archive as the superseded body. Routed work that
# is itself archived keeps its retired edge, which blocks nothing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

read_decision_record() {  # <label> <path>
  local label=$1 path=$2 text
  [ -n "$path" ] || fail "--$label-file is required"
  [ -f "$path" ] || fail "$label file does not exist: $path"
  text=$(cat "$path")
  [ -n "$text" ] || fail "$label file must not be empty"
  [ "$(printf '%s' "$text" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "$label file exceeds 8192 bytes"
  printf '%s' "$text"
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

# Print one double-quoted [markdown] key from the active home's tasks-axi config,
# resolved against FM_HOME the way tasks-axi resolves it.
tasks_store_path() {  # <path|archive>
  local key=$1 value
  [ -f "$FM_HOME/.tasks.toml" ] || return 1
  value=$(awk -v key="$key" '
    /^[[:space:]]*\[/ { table = $0; gsub(/[[:space:]]/, "", table); next }
    table == "[markdown]" && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      if (match(line, /^"[^"]+"/)) { print substr(line, 2, RLENGTH - 2); exit }
    }
  ' "$FM_HOME/.tasks.toml")
  [ -n "$value" ] || return 1
  case "$value" in
    /*) printf '%s\n' "$value" ;;
    *) printf '%s/%s\n' "$FM_HOME" "$value" ;;
  esac
}

searched_stores() {
  local active archive
  active=$(tasks_store_path path) || active="the tasks-axi backlog in $FM_HOME"
  if archive=$(tasks_store_path archive); then
    printf '%s and its archive %s' "$active" "$archive"
  else
    printf '%s, which declares no archive' "$active"
  fi
}

init_work_root() {
  WORK_ROOT=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-decision-hold-work.XXXXXX") \
    || fail "could not create a private work directory"
  trap 'rm -rf "$WORK_ROOT"' EXIT
}

work_dir() {
  [ -n "${WORK_ROOT:-}" ] || fail "private work directory is not initialized"
  mktemp -d "$WORK_ROOT/lookup.XXXXXX" || fail "could not create a private work directory"
}

# Print the normalized copy of the newest archive section whose tasks-axi parse
# holds <id>. A substring hit only selects candidates; tasks-axi decides.
archive_section() {  # <id> <work-dir>
  local id=$1 dir=$2 archive sections section
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  archive=$(tasks_store_path archive) || return 1
  [ -f "$archive" ] || return 1
  awk -v id="$id" -v dir="$dir" '
    function flush(  file) {
      if (hit) {
        file = sprintf("%s/section.%08d.md", dir, n)
        printf "## In flight\n\n## Queued\n\n## Done\n%s", body > file
        close(file)
      }
      body = ""
      hit = 0
    }
    /^## / { flush(); n++; next }
    { body = body $0 "\n"; if (index($0, id)) hit = 1 }
    END { flush() }
  ' "$archive" || return 1
  sections=$(find "$dir" -type f -name 'section.*.md' | LC_ALL=C sort -r)
  while IFS= read -r section; do
    [ -n "$section" ] || continue
    if tasks_axi show "$id" --file="$section" >/dev/null 2>&1; then
      printf '%s\n' "$section"
      return 0
    fi
  done <<EOF
$sections
EOF
  return 1
}

# Print the newest record of <id>: the active backlog first, then its archive.
identity_show() {  # <id>
  local id=$1 show dir section
  if show=$(task_show "$id"); then
    printf '%s\n' "$show"
    return 0
  fi
  dir=$(work_dir) || return 1
  section=$(archive_section "$id" "$dir") || return 1
  tasks_axi show "$id" --full --file="$section" 2>/dev/null
}

done_ids() {  # <backlog-file>
  tasks_axi list --state "done" --file="$1" \
    | sed -n 's/^  "\{0,1\}\([A-Za-z0-9._-][A-Za-z0-9._-]*\)"\{0,1\},done,.*/\1/p'
}

# Append a stamped snapshot of an archived identity to its archive.
stamp_archived_record() {  # <id> <body>
  local id=$1 body=$2 dir section others other
  dir=$(work_dir) || return 1
  section=$(archive_section "$id" "$dir") || return 1
  others=$(done_ids "$section") || return 1
  while IFS= read -r other; do
    [ -n "$other" ] && [ "$other" != "$id" ] || continue
    tasks_axi rm "$other" --file="$section" >/dev/null || return 1
  done <<EOF
$others
EOF
  tasks_axi list --state "done" --file="$section" | grep -Fx 'count: 1' >/dev/null || return 1
  [ "$(done_ids "$section")" = "$id" ] || return 1
  tasks_axi update "$id" --body "$body" --file="$section" >/dev/null || return 1
  tasks_axi prune --keep 0 --file="$section" >/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(identity_show "$id") || fail "captain hold $id is absent from $(searched_stores)"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  show=$(identity_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  show=$(identity_show "$id") || fail "captain decision $id is absent from $(searched_stores)"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ]; then
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
    esac
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

# The repair marks are part of the shared attestation body: they state which of the
# two mutually exclusive facts a stamped record carries, and a retry that flips
# between them is a conflict rather than an idempotent repeat.
REPAIR_DECIDED_MARK='Repair: stamped onto a captain decision closed outside fm-decision-hold.'
REPAIR_NEVER_MARK='Repair: stamped onto a closed key that was never a captain decision.'

verify_repair_identity() {  # <hold-id> <hold-body> <decision-digest> <routed-csv> <repair-mark>
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 mark=$5
  case "$hold_body" in
    *"$mark"*) : ;;
    *) fail "captain decision $id already carries a different resolution record than this repair" ;;
  esac
  verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(identity_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  decision=$(read_decision_record decision "$decision_file")
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(identity_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(identity_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

command_repair() {
  local origin=${1:-} key=${2:-} decision_file='' note_file='' never=0 routed='' routed_csv='' \
    id='' record='' digest='' mark='' section='' routed_block='' body='' show state kind hold_body dep
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; [ "$#" -gt 0 ] || fail "--decision-file requires a path"; decision_file=$1 ;;
      --note-file) shift; [ "$#" -gt 0 ] || fail "--note-file requires a path"; note_file=$1 ;;
      --never-a-decision) never=1 ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  if [ "$never" = 1 ]; then
    [ -z "$decision_file" ] || fail "--never-a-decision cannot be combined with --decision-file"
    [ -z "$routed" ] || fail "--never-a-decision cannot be combined with --routed-to"
    [ -n "$note_file" ] || fail "--never-a-decision requires its own --note-file"
    record=$(read_decision_record note "$note_file")
    routed_csv=none
    mark=$REPAIR_NEVER_MARK
    section=$(printf 'None. This key was never a captain decision.\n%s' "$record")
    routed_block='- none'
  else
    [ -z "$note_file" ] || fail "--note-file records a key that was never a decision and requires --never-a-decision"
    record=$(read_decision_record decision "$decision_file")
    [ -n "$routed" ] || fail "at least one --routed-to task is required"
    routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
    routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
    mark=$REPAIR_DECIDED_MARK
    section=$record
    routed_block=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d;s/^/- /')
  fi
  digest=$(sha256_text "$record")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  show=$(identity_show "$id") || fail "captain decision $id is absent from $(searched_stores)"
  kind=$(show_field "$show" kind)
  state=$(show_field "$show" state)
  hold_body=$(show_field "$show" body)
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$state" = "done" ] \
    || fail "captain decision $id is not closed (state=$state); an open decision is closed by resolve"
  if verify_hold_resolved "$id"; then
    verify_repair_identity "$id" "$hold_body" "$digest" "$routed_csv" "$mark"
    printf 'repaired: %s\n' "$id"
    return 0
  fi

  # Prove every routed identity exists before mutating any edge, so a bad routed
  # set fails before a partial repair.
  for dep in $routed; do
    identity_show "$dep" >/dev/null || fail "routed task $dep does not exist in the active home"
  done
  # A hand-closed identity leaves its recorded dependency edge on routed work even
  # though tasks-axi already treats a Done blocker as satisfied. Clearing the edge
  # is idempotent, and doing it before the attestation keeps the stamp the last
  # write, so an interrupted repair stays unstamped.
  for dep in $routed; do
    task_show "$dep" >/dev/null || continue
    tasks_axi unblock "$dep" --by "$id" >/dev/null \
      || fail "could not clear the recorded dependency edge from $dep"
  done

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n%s\n\nCaptain decision:\n%s\n\nRouted work:\n%s\n' \
    "$digest" "$routed_csv" "$mark" "$section" "$routed_block")
  if task_show "$id" >/dev/null; then
    tasks_axi update "$id" --body "$body" --archive-body >/dev/null \
      || fail "could not stamp the resolution record on $id"
  else
    stamp_archived_record "$id" "$body" \
      || fail "could not append the stamped resolution record for $id to $(searched_stores)"
  fi
  verify_hold_resolved "$id" || fail "captain decision $id did not retain its stamped resolution record"
  printf 'repaired: %s%s\n' "$id" "${routed:+ -> $routed}"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; init_work_root; command_hold "$@" ;;
  complete) shift; init_work_root; command_complete "$@" ;;
  verify) shift; init_work_root; command_verify "$@" ;;
  resolve) shift; init_work_root; command_resolve "$@" ;;
  repair) shift; init_work_root; command_repair "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
