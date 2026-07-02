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
  [[ "${gh_branch}" == "HEAD" || "${gh_branch}" == "main" ]] && continue

  case "${gh_branch}" in
    SC4UTILITI-*|TCSC410303-*|SVRP-*|feature/SC4UTILITI-*|feature/TCSC410303-*|bugfix/TCSC410303-*|trial/*|trial-schema/*) ;;
    *) continue ;;
  esac

  gh_sha="$(git rev-parse "${gh_ref}")"
  iso_ref="refs/remotes/iso/${gh_branch}"

  if ! git rev-parse --verify --quiet "${iso_ref}" >/dev/null; then
    n="$(git rev-list --count "iso/develop..${gh_sha}" 2>/dev/null || echo "?")"
    echo "- ${gh_branch} — NEW on ISO (not yet pushed); ${n} commit(s) on top of iso/develop"
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
echo "# main ahead of develop"
main_ahead="$(git rev-list --count "iso/develop..origin/main" 2>/dev/null || echo 0)"
if [[ "${main_ahead}" -gt 0 ]]; then
  echo "- main is ahead of iso/develop by ${main_ahead} commit(s) — consider proxying via §7.7"
fi
