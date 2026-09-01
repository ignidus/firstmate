#!/usr/bin/env bash
# fm-zia-surface-guard.sh - block a ZIA rule-order spawn that collides with one
# already in flight on the same live policy surface, then spawn it.
#
# ADR-0060 decision 2 makes ZIA rule order tenant-wide PER POLICY SURFACE, not
# per Terraform module: two tasks touching different files/modules can still
# race the same live order if they target the same surface (see cyb-iac's own
# CLAUDE.md, "ZIA rule order is adopt-first"). File-overlap alone cannot see
# this, so this script checks it directly against the project's own canonical
# surface catalog and every currently in-flight task's recorded surface(s).
#
# Usage:
#   fm-zia-surface-guard.sh <task-id> <surface-key>[,<surface-key>...] -- \
#       <fm-spawn.sh args...>
#
# <surface-key> must be one of the keys in cyb-iac's own
# zscaler/api-scope-probe/zia_policy_surfaces.py POLICY_SURFACES dict (read
# live from the project, never a hardcoded copy here, so this never drifts
# from the source of truth). Firstmate decides which surface(s) a task
# touches at dispatch intake, same judgment call as any other AGENTS.md
# section 7 semantic-dependency check; this script only mechanizes the
# resulting conflict math, it does not infer the surface from a task's brief.
#
# On a clean check, this runs fm-spawn.sh with the remaining arguments
# unchanged, then records "zia_surfaces=<sorted-csv>" as a new line in the
# freshly spawned task's state/<task-id>.meta. On a conflict, it refuses
# loudly and never calls fm-spawn.sh at all.
#
# A currently in-flight task is any state/<id>.meta that carries a
# zia_surfaces= line - teardown (bin/fm-teardown.sh) removes that file, so a
# torn-down task can never be read as still holding a surface.
#
# Env overrides (testing only):
#   FM_ZIA_SURFACES_PROJECT_DIR   cyb-iac checkout to read the catalog from
#                                 (default: $FM_HOME/projects/cyb-iac)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECT_DIR="${FM_ZIA_SURFACES_PROJECT_DIR:-$FM_HOME/projects/cyb-iac}"
SURFACES_MODULE="$PROJECT_DIR/zscaler/api-scope-probe/zia_policy_surfaces.py"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-zia-surface-guard: %s\n' "$*" >&2
  exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

[ "$#" -ge 4 ] || { usage; exit 2; }

TASK_ID=$1
SURFACES_CSV=$2
shift 2
[ "${1:-}" = "--" ] || die "expected '--' before the fm-spawn.sh arguments, got '${1:-}'"
shift

[ -f "$SURFACES_MODULE" ] || die "surface catalog not found at $SURFACES_MODULE - refusing rather than guessing the surface list"
command -v python3 >/dev/null 2>&1 || die "python3 not found - required to read the canonical surface catalog"

CANONICAL=$(python3 - "$SURFACES_MODULE" <<'PY'
import importlib.util
import os
import sys

path = sys.argv[1]
# The module imports sibling scripts (e.g. get_zia_object) by bare name, which
# only resolves when its own directory is on sys.path - it is not an
# installed package.
sys.path.insert(0, os.path.dirname(path))
spec = importlib.util.spec_from_file_location("zia_policy_surfaces", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for key in sorted(mod.POLICY_SURFACES.keys()):
    print(key)
PY
) || die "failed to load POLICY_SURFACES from $SURFACES_MODULE"

is_canonical() {
  local key=$1 line
  while IFS= read -r line; do
    [ "$line" = "$key" ] && return 0
  done <<<"$CANONICAL"
  return 1
}

IFS=',' read -r -a REQUESTED <<<"$SURFACES_CSV"
[ "${#REQUESTED[@]}" -gt 0 ] || die "no surface keys given"

for key in "${REQUESTED[@]}"; do
  is_canonical "$key" || die "unknown surface key '$key' - valid keys are: $(printf '%s ' "$CANONICAL")"
done

# Sorted, de-duplicated, canonical form for both the conflict check and what
# gets recorded into the new task's meta.
NORMALIZED_CSV=$(printf '%s\n' "${REQUESTED[@]}" | sort -u | paste -sd, -)

conflict_found=0
if [ -d "$STATE" ]; then
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    other_id=$(basename "$meta" .meta)
    [ "$other_id" = "$TASK_ID" ] && continue
    other_line=$(grep -m1 '^zia_surfaces=' "$meta" 2>/dev/null || true)
    [ -n "$other_line" ] || continue
    other_csv=${other_line#zia_surfaces=}
    IFS=',' read -r -a OTHER_SURFACES <<<"$other_csv"
    for req in "${REQUESTED[@]}"; do
      for other in "${OTHER_SURFACES[@]}"; do
        if [ "$req" = "$other" ]; then
          printf 'fm-zia-surface-guard: BLOCKED - task %s already holds surface %s live (state/%s.meta)\n' \
            "$other_id" "$other" "$other_id" >&2
          conflict_found=1
        fi
      done
    done
  done
fi

if [ "$conflict_found" -eq 1 ]; then
  die "requested surface(s) [$NORMALIZED_CSV] conflict with in-flight work - serialize these tasks instead of dispatching them concurrently"
fi

"$SCRIPT_DIR/fm-spawn.sh" "$@"
spawn_status=$?

if [ "$spawn_status" -eq 0 ]; then
  meta="$STATE/$TASK_ID.meta"
  if [ -f "$meta" ]; then
    printf 'zia_surfaces=%s\n' "$NORMALIZED_CSV" >> "$meta"
    printf 'fm-zia-surface-guard: recorded zia_surfaces=%s for %s\n' "$NORMALIZED_CSV" "$TASK_ID" >&2
  else
    printf 'fm-zia-surface-guard: WARNING - spawn reported success but %s was not created; surface not recorded\n' "$meta" >&2
  fi
fi

exit "$spawn_status"
