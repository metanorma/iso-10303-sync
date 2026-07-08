#!/usr/bin/env bash
# One-way ISO → GitHub mirror. See docs/iso-mirror-sync.md for the full spec.
#
# Updates rules per spec §6.3:
#   - GitHub branch missing      → create from iso_sha
#   - gh_sha == iso_sha          → no-op
#   - gh behind (FF possible)    → fast-forward
#   - gh strictly ahead          → info-only (normal state between proxy events)
#   - diverged                   → alert + open/update conflict issue, skip
#
# Hard rule: the bot NEVER uses --force or --force-with-lease.
# shellcheck disable=SC2016
set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
ORIGIN_REF_PREFIX="refs/remotes/${ORIGIN_REMOTE}/"
REPO="${GH_REPO:-}"          # owner/repo for gh CLI; auto-detected if empty
CONFLICT_LABEL="${CONFLICT_LABEL:-iso-mirror-conflict}"
SNAPSHOT_FILE="${SNAPSHOT_FILE:-/tmp/iso-branches-snapshot.txt}"

CREATED=()
FAST_FORWARDED=()
INFO_AHEAD=()
CONFLICT_BRANCHES=()
CONFLICT_ISSUES_OPENED=()
CONFLICT_ISSUES_UPDATED=()

# Pruning-detection output (alert-only — the bot NEVER auto-deletes).
# Parallel arrays because bash lacks structs.
PRUNABLE_DELETE_BRANCH=()
PRUNABLE_DELETE_SHA=()
PRUNABLE_PRESERVE_BRANCH=()
PRUNABLE_PRESERVE_SHA=()
PRUNABLE_PRESERVE_UNIQUE_COUNT=()

map_name() {
  case "$1" in
    develop) echo develop ;;  # name-duplicated: ISO develop → GitHub develop (pure FF-only mirror)
    main)    echo main ;;     # name-duplicated: ISO main (release) → GitHub main (pure FF-only mirror). GitHub mn/main is Metanorma's default branch, NOT mirrored.
    *)       echo "$1" ;;
  esac
}

is_ancestor() {
  git merge-base --is-ancestor "$1" "$2" 2>/dev/null
}

ensure_conflict_label() {
  [[ -z "${REPO}" || "${DRY_RUN}" == "true" ]] && return 0
  gh label create "${CONFLICT_LABEL}" \
    --color BFD4F2 \
    --description "ISO mirror divergence — needs proxy-user triage (see docs/iso-mirror-sync.md §7.11)" \
    --repo "${REPO}" >/dev/null 2>&1 || true
}

find_open_conflict_issue() {
  local branch="$1"
  [[ -z "${REPO}" ]] && { echo ""; return; }
  gh issue list --repo "${REPO}" \
    --state open \
    --label "${CONFLICT_LABEL}" \
    --search "in:title \"[iso-mirror] Conflict: ${branch}\"" \
    --json number,url --limit 1 \
    --jq '.[0]'
}

open_or_update_conflict_issue() {
  local branch="$1" iso_sha="$2" gh_sha="$3"
  [[ -z "${REPO}" ]] && { echo "(skipped: no GH_REPO for issue open)"; return; }

  local merge_base n_gh n_iso body title existing number url
  merge_base="$(git merge-base "${iso_sha}" "${gh_sha}")"
  n_iso="$(git rev-list --count "${merge_base}..${iso_sha}")"
  n_gh="$(git rev-list --count "${merge_base}..${gh_sha}")"
  title="[iso-mirror] Conflict: ${branch}"

  body=$(printf '## Diverged branch — `%s`\n\n' "${branch}")
  body+=$(printf '| ref | sha |\n|---|---|\n| iso/%s | `%s` |\n| origin/%s | `%s` |\n| merge-base | `%s` |\n\n' \
    "${branch}" "${iso_sha}" "${branch}" "${gh_sha}" "${merge_base}")
  body+=$(printf 'ISO has **%d** unique commit(s); GitHub has **%d** unique commit(s).\n\n' "${n_iso}" "${n_gh}")

  body+=$(printf '### ISO-only commits (`%s..%s`)\n```\n' "${merge_base}" "${iso_sha}")
  body+=$(git log --oneline --no-decorate "${merge_base}..${iso_sha}" | head -30 || true)
  body+=$'\n```\n\n'

  body+=$(printf '### GitHub-only commits (`%s..%s`)\n```\n' "${merge_base}" "${gh_sha}")
  body+=$(git log --oneline --no-decorate "${merge_base}..${gh_sha}" | head -30 || true)
  body+=$'\n```\n\n'

  body+='### Suggested resolutions (see docs/iso-mirror-sync.md §7.11)\n'
  body+='- If GitHub'\''s unique commits are still pending proxy (§7) → do that first; once ISO merges, the mirror fast-forwards.\n'
  body+='- If both sides have unrelated in-flight work → coordinate via JIRA; one side pauses, the other proceeds, then sync.\n'
  body+='- If GitHub'\''s unique commits are stale → open a PR to reset GitHub to ISO (force-push by a human; never the bot).\n'

  existing="$(find_open_conflict_issue "${branch}")"
  if [[ -n "${existing}" ]]; then
    number="$(printf '%s' "${existing}" | jq -r '.number')"
    url="$(printf '%s' "${existing}" | jq -r '.url')"
    if [[ "${DRY_RUN}" != "true" ]]; then
      printf '%b' "${body}" | gh issue comment "${number}" --repo "${REPO}" --body-file -
    fi
    CONFLICT_ISSUES_UPDATED+=("#${number} (${branch})")
    echo "${url}"
  else
    if [[ "${DRY_RUN}" != "true" ]]; then
      url="$(printf '%b' "${body}" | gh issue create --repo "${REPO}" \
        --title "${title}" \
        --label "${CONFLICT_LABEL}" \
        --body-file -)"
    else
      url="(dry-run)"
    fi
    CONFLICT_ISSUES_OPENED+=("${branch}: ${url}")
    echo "${url}"
  fi
}

ensure_conflict_label

while read -r iso_ref; do
  iso_branch="${iso_ref#refs/remotes/iso/}"
  [[ "${iso_branch}" == "HEAD" ]] && continue

  iso_sha="$(git rev-parse "${iso_ref}")"
  gh_branch="$(map_name "${iso_branch}")"
  [[ -z "${gh_branch}" ]] && continue

  gh_ref="${ORIGIN_REF_PREFIX}${gh_branch}"

  if ! git rev-parse --verify --quiet "${gh_ref}" >/dev/null; then
    echo "[create] ${gh_branch} <- ${iso_sha}"
    CREATED+=("${gh_branch}")
    if [[ "${DRY_RUN}" != "true" ]]; then
      git push "${ORIGIN_REMOTE}" "${iso_sha}:refs/heads/${gh_branch}"
    fi
    continue
  fi

  gh_sha="$(git rev-parse "${gh_ref}")"
  if [[ "${gh_sha}" == "${iso_sha}" ]]; then
    echo "[equal]  ${gh_branch}"
    continue
  fi

  if is_ancestor "${gh_sha}" "${iso_sha}"; then
    echo "[ff]     ${gh_branch} ${gh_sha} -> ${iso_sha}"
    FAST_FORWARDED+=("${gh_branch}")
    if [[ "${DRY_RUN}" != "true" ]]; then
      git push "${ORIGIN_REMOTE}" "${iso_sha}:refs/heads/${gh_branch}"
    fi
    continue
  fi

  if is_ancestor "${iso_sha}" "${gh_sha}"; then
    n="$(git rev-list --count "${iso_sha}..${gh_sha}")"
    echo "[info]   ${gh_branch} ahead of ISO by ${n} commit(s) — pending proxy (§7)"
    INFO_AHEAD+=("${gh_branch} (${n} ahead)")
    continue
  fi

  echo "[alert]  ${gh_branch} DIVERGED — iso=${iso_sha} gh=${gh_sha}"
  CONFLICT_BRANCHES+=("${gh_branch} iso=${iso_sha} gh=${gh_sha}")
  open_or_update_conflict_issue "${gh_branch}" "${iso_sha}" "${gh_sha}" >/dev/null || \
    echo "  (issue open/update failed for ${gh_branch})"
done < <(git for-each-ref --format='%(refname)' refs/remotes/iso/)

# === Pruning detection (stateful, alert-only) ============================
# See docs/iso-mirror-sync.md §6.5. Compares current ISO branches against a
# snapshot from the previous run. Branches that were on ISO last run but are
# gone now are pruning candidates. For each gone branch with a GitHub
# counterpart: if gh_sha is reachable from any current ISO branch → safe to
# delete; otherwise → preserve (GitHub has unique commits not in ISO).
# The bot NEVER deletes branches automatically — this is alert-only.

declare -A prev_iso_branches=()
if [[ -f "${SNAPSHOT_FILE}" ]]; then
  while IFS=' ' read -r p_branch p_sha; do
    [[ -z "${p_branch}" ]] && continue
    prev_iso_branches["${p_branch}"]="${p_sha}"
  done < "${SNAPSHOT_FILE}"
fi

declare -A curr_iso_branches=()
while read -r iso_ref; do
  iso_branch="${iso_ref#refs/remotes/iso/}"
  [[ "${iso_branch}" == "HEAD" ]] && continue
  curr_iso_branches["${iso_branch}"]="$(git rev-parse "${iso_ref}")"
done < <(git for-each-ref --format='%(refname)' refs/remotes/iso/)

# Persist current snapshot for next run (always overwrite — even on conflict
# exits, the workflow's `if: always()` cache-save step picks this up).
: > "${SNAPSHOT_FILE}"
for branch in "${!curr_iso_branches[@]}"; do
  printf '%s %s\n' "${branch}" "${curr_iso_branches[${branch}]}" >> "${SNAPSHOT_FILE}"
done

# Pruning detection only runs if we have a previous snapshot to compare.
if (( ${#prev_iso_branches[@]} > 0 )); then
  iso_tips=()
  exclude_args=()
  for branch in "${!curr_iso_branches[@]}"; do
    iso_tips+=("${curr_iso_branches[${branch}]}")
    exclude_args+=("^${curr_iso_branches[${branch}]}")
  done

  for gone_branch in "${!prev_iso_branches[@]}"; do
    # Skip branches still on ISO
    [[ -n "${curr_iso_branches[${gone_branch}]:-}" ]] && continue

    gh_branch="$(map_name "${gone_branch}")"
    [[ -z "${gh_branch}" ]] && continue
    gh_ref="${ORIGIN_REF_PREFIX}${gh_branch}"

    # Skip if GitHub branch is also gone
    if ! git rev-parse --verify --quiet "${gh_ref}" >/dev/null 2>&1; then
      continue
    fi

    gh_sha="$(git rev-parse "${gh_ref}")"

    # Reachability: is gh_sha an ancestor of any current ISO branch?
    reachable=false
    for tip in "${iso_tips[@]}"; do
      if git merge-base --is-ancestor "${gh_sha}" "${tip}" 2>/dev/null; then
        reachable=true
        break
      fi
    done

    if $reachable; then
      echo "[prune:delete] ${gh_branch} (was iso/${gone_branch}; GitHub tip ${gh_sha:0:12} reachable from ISO)"
      PRUNABLE_DELETE_BRANCH+=("${gh_branch}")
      PRUNABLE_DELETE_SHA+=("${gh_sha}")
    else
      unique_count=$(git rev-list --count "${gh_sha}" "${exclude_args[@]}" 2>/dev/null || echo "?")
      echo "[prune:keep]    ${gh_branch} (GitHub has ${unique_count} unique commit(s) not on ISO)"
      PRUNABLE_PRESERVE_BRANCH+=("${gh_branch}")
      PRUNABLE_PRESERVE_SHA+=("${gh_sha}")
      PRUNABLE_PRESERVE_UNIQUE_COUNT+=("${unique_count}")
    fi
  done
fi

{
  echo "## ISO → GitHub mirror summary"
  echo
  if (( ${#CREATED[@]} )); then
    echo "### Created"
    printf -- '- %s\n' "${CREATED[@]}"
    echo
  fi
  if (( ${#FAST_FORWARDED[@]} )); then
    echo "### Fast-forwarded"
    printf -- '- %s\n' "${FAST_FORWARDED[@]}"
    echo
  fi
  if (( ${#INFO_AHEAD[@]} )); then
    echo "### GitHub ahead of ISO (informational — pending proxy per §7)"
    printf -- '- %s\n' "${INFO_AHEAD[@]}"
    echo
  fi
  if (( ${#CONFLICT_BRANCHES[@]} )); then
    echo "### Conflicts — manual resolution required (§6.4)"
    printf -- '- %s\n' "${CONFLICT_BRANCHES[@]}"
    echo
  fi
  if (( ${#CONFLICT_ISSUES_OPENED[@]} )); then
    echo "### Conflict issues opened"
    printf -- '- %s\n' "${CONFLICT_ISSUES_OPENED[@]}"
    echo
  fi
  if (( ${#CONFLICT_ISSUES_UPDATED[@]} )); then
    echo "### Conflict issues updated"
    printf -- '- %s\n' "${CONFLICT_ISSUES_UPDATED[@]}"
    echo
  fi
  if (( ${#PRUNABLE_DELETE_BRANCH[@]} )); then
    echo "### Pruning candidates — safe to delete (GitHub tip reachable from ISO)"
    for i in "${!PRUNABLE_DELETE_BRANCH[@]}"; do
      echo "- \`${PRUNABLE_DELETE_BRANCH[$i]}\` (\`${PRUNABLE_DELETE_SHA[$i]:0:12}\`) — was on ISO, now merged into a current ISO branch"
    done
    echo
    echo "<details><summary>Delete commands (click to expand)</summary>"
    echo
    echo '```sh'
    for b in "${PRUNABLE_DELETE_BRANCH[@]}"; do
      echo "git push ${ORIGIN_REMOTE} :${b}"
    done
    echo '```'
    echo
    echo "</details>"
    echo
    echo "The bot does not auto-delete. Run the commands above manually after review."
    echo
  fi
  if (( ${#PRUNABLE_PRESERVE_BRANCH[@]} )); then
    echo "### Pruning candidates — preserve (GitHub has unique commits not on ISO)"
    for i in "${!PRUNABLE_PRESERVE_BRANCH[@]}"; do
      echo "- \`${PRUNABLE_PRESERVE_BRANCH[$i]}\` (\`${PRUNABLE_PRESERVE_SHA[$i]:0:12}\`) — ${PRUNABLE_PRESERVE_UNIQUE_COUNT[$i]} unique commit(s)"
    done
    echo
    echo "These branches need proxy-push (§7) or explicit human review before deletion."
    echo
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if (( ${#CONFLICT_BRANCHES[@]} )); then
  echo "::error::${#CONFLICT_BRANCHES[@]} branch conflict(s) detected — see step summary"
  exit 1
fi
