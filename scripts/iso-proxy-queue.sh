#!/usr/bin/env bash
# List GitHub branches that are ahead of (or new vs.) their ISO counterparts.
# Run locally (not in CI). Requires both iso and origin remotes configured.
# See docs/iso-mirror-sync.md §7.4.
set -euo pipefail

git fetch --all --prune

echo "# Proxy queue — GitHub branches ahead of ISO"
echo

while read -r gh_ref; do
  gh_branch="${gh_ref#refs/remotes/origin/}"
  # main is Metanorma's own branch, not tracked by the mirror — skip.
  [[ "${gh_branch}" == "HEAD" || "${gh_branch}" == "main" ]] && continue

  # Proxy-intended branches on GitHub use the `to-iso/` prefix per spec §5.3.A.
  # Strip the prefix to match against the ISO-side branch name.
  if [[ "${gh_branch}" == to-iso/* ]]; then
    iso_branch="${gh_branch#to-iso/}"
  else
    continue   # not a proxy-intended branch; ignore
  fi

  gh_sha="$(git rev-parse "${gh_ref}")"
  iso_ref="refs/remotes/iso/${iso_branch}"

  if ! git rev-parse --verify --quiet "${iso_ref}" >/dev/null; then
    n="$(git rev-list --count "iso/develop..${gh_sha}" 2>/dev/null || echo "?")"
    echo "- ${gh_branch} — NEW on ISO (stripped: ${iso_branch}); ${n} commit(s) on top of iso/develop"
    continue
  fi

  iso_sha="$(git rev-parse "${iso_ref}")"
  if [[ "${gh_sha}" == "${iso_sha}" ]]; then continue; fi

  if git merge-base --is-ancestor "${iso_sha}" "${gh_sha}" 2>/dev/null; then
    n="$(git rev-list --count "${iso_sha}..${gh_sha}")"
    echo "- ${gh_branch} — ISO behind by ${n} commit(s); FF push OK"
  else
    echo "- ${gh_branch} — DIVERGED from ISO; rebase needed before push (§7.11)"
  fi
done < <(git for-each-ref --format='%(refname)' refs/remotes/origin/)

echo
echo "# develop status"
develop_ahead="$(git rev-list --count "iso/develop..origin/develop" 2>/dev/null || echo 0)"
develop_behind="$(git rev-list --count "origin/develop..iso/develop" 2>/dev/null || echo 0)"
if [[ "${develop_ahead}" -eq 0 && "${develop_behind}" -eq 0 ]]; then
  echo "- develop is in sync with iso/develop"
else
  echo "- develop ahead of iso/develop: ${develop_ahead}; behind: ${develop_behind}"
fi
