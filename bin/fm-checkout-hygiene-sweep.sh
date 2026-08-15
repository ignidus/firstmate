#!/usr/bin/env bash
# Report-only hygiene sweep for one git checkout: absorbed local branches,
# aged untracked files, and secret-shaped content inside those untracked
# files. Never deletes, never rotates, never auto-fixes anything - every
# finding is a report line for a human to act on. Extends D-28's stale-
# session-sweep concept (harness-streamlining-report-2026-08-04.html) to
# project checkouts, after a live cyb-iac pass turned up ~90 unpruned
# branches, an unrotated cleartext credential, and unticketed analysis
# sitting untracked for weeks - the same root gap (nothing sweeps a
# checkout's own accumulated cruft) as D-28's Lavish-session case, worse
# blast radius.
#
# Usage: fm-checkout-hygiene-sweep.sh <repo-path>
#   Prints one line per finding, one of:
#     BRANCH_ABSORBED: <branch> - tree-identical to <default-branch>, safe to prune manually
#     UNTRACKED_AGED: <path> (<N>d old)
#     UNTRACKED_SECRET_SHAPED: <path> - matched <pattern-family>, rotate the real secret then decide the file's fate
#   Silent = nothing found. Never mutates the repo.
set -uo pipefail

repo="${1:-}"
if [ -z "$repo" ] || [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then
  echo "usage: fm-checkout-hygiene-sweep.sh <repo-path> (must be a git checkout)" >&2
  exit 1
fi

git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $repo" >&2; exit 1; }

default_branch="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
[ -n "$default_branch" ] || default_branch="$(git -C "$repo" branch --list main master 2>/dev/null | sed 's/^[* ]*//' | head -1)"
[ -n "$default_branch" ] || { echo "could not determine default branch for $repo" >&2; exit 1; }

default_ref="origin/$default_branch"
git -C "$repo" rev-parse --verify "$default_ref" >/dev/null 2>&1 || default_ref="$default_branch"
default_tree="$(git -C "$repo" rev-parse "${default_ref}^{tree}" 2>/dev/null)"

# 1. Branches fully absorbed into default (tree-identical, not just
#    ancestor-check - a squash-merged branch fails ancestor-check while
#    being fully absorbed, so compare the actual resulting tree instead).
while IFS= read -r branch; do
  [ -z "$branch" ] && continue
  [ "$branch" = "$default_branch" ] && continue
  merged_tree="$(git -C "$repo" merge-tree --write-tree "$default_ref" "$branch" 2>/dev/null)"
  if [ -n "$merged_tree" ] && [ "$merged_tree" = "$default_tree" ]; then
    echo "BRANCH_ABSORBED: $branch - tree-identical to $default_branch, safe to prune manually"
  fi
done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/)

# 2. Untracked files older than 7 days - both genuinely untracked (??) AND
#    gitignored (!!). Gitignored matters: a gitignored secret file (exactly
#    the tenable/c.py case D-38 found) never shows up in plain `git status`
#    without --ignored, so a check limited to ?? would systematically miss
#    the real-world case this tool exists to catch. Excludes common vendor/
#    dependency directories to stay fast and low-noise on large ignored trees.
aged_files=()
# Plain newline-delimited porcelain (not -z): git quotes any path containing
# a literal newline as a C-style-escaped string in this mode, so it never
# actually emits a raw newline mid-record - safe to read line-by-line, and
# sidesteps a BSD/macOS awk NUL-record-separator bug that silently dropped
# entries when NUL-splitting mixed ?? and !! records (confirmed live: one
# real entry vanished between a scoped test and the full-repo run before
# this was caught).
while IFS= read -r statusline; do
  case "$statusline" in
    '?? '*|'!! '*) path="${statusline:3}" ;;
    *) continue ;;
  esac
  case "$path" in
    */node_modules/*|node_modules/*|*/.terraform/*|.terraform/*|*/vendor/*|vendor/*|*/.venv/*|.venv/*|*/__pycache__/*|__pycache__/*|*/dist/*|dist/*|*/build/*|build/*) continue ;;
  esac
  full="$repo/$path"
  [ -f "$full" ] || continue
  mtime="$(stat -f '%m' "$full" 2>/dev/null || echo 0)"
  age_days=$(( ( $(date +%s) - mtime ) / 86400 ))
  if [ "$age_days" -ge 7 ]; then
    echo "UNTRACKED_AGED: $path (${age_days}d old)"
    aged_files+=("$full")
  fi
done < <(git -C "$repo" status --porcelain --ignored=matching 2>/dev/null)

# 3. Secret-shaped content inside those aged untracked files only (not the
#    whole tree - keeps this fast and matches D-38's actual finding shape).
if [ "${#aged_files[@]}" -gt 0 ]; then
  for f in "${aged_files[@]}"; do
    rel="${f#"$repo"/}"
    if grep -qE 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|xox[baprs]-[0-9]|ghp_[A-Za-z0-9]{36}|ya29\.[0-9A-Za-z_-]+' "$f" 2>/dev/null; then
      echo "UNTRACKED_SECRET_SHAPED: $rel - matched a cloud/token credential pattern, rotate the real secret then decide the file's fate"
    elif grep -qEi '\b(api[_-]?key|secret|password|token)\b[[:space:]]*[:=]' "$f" 2>/dev/null; then
      echo "UNTRACKED_SECRET_SHAPED: $rel - matched a generic credential-assignment shape, verify by hand"
    fi
  done
fi
