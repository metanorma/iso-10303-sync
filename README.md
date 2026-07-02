# iso-10303-sync

Hourly one-way mirror of the ISO TC184/SC4 `wg12-step` Bitbucket repository into [`metanorma/iso-10303`](https://github.com/metanorma/iso-10303). Fast-forward only; never force-pushes. Diverged branches open `[iso-mirror] Conflict: <branch>` issues on `metanorma/iso-10303` for human triage.

This repo exists as **infrastructure only** — it holds the GitHub Actions workflow, the sync scripts, and the spec. The mirrored content (documents, schemas) lives in `metanorma/iso-10303`; nothing sync-related is committed there.

## Layout

| Path | Purpose |
|------|---------|
| `.github/workflows/iso-mirror-sync.yml` | Hourly scheduled mirror workflow |
| `scripts/iso-mirror-sync.sh` | Per-branch update rules (create / fast-forward / info-ahead / alert-diverged) |
| `scripts/iso-proxy-queue.sh` | Local helper for proxy users (lists branches ahead of / new vs. ISO) |
| `docs/iso-mirror-sync.md` | Full spec — design, algorithm, use cases, failure modes |

## How the workflow works

It runs in *this* repo (so the script is available locally), then checks out `metanorma/iso-10303` into `./target` and runs the sync script from there:

```
actions/checkout@v6                          # sync repo (for scripts/)
actions/checkout@v6 → ./target               # metanorma/iso-10303 (uses METANORMA_CI_PAT_TOKEN)
working-directory: target
  git remote add iso …                        # sd.iso.org (no PAT in URL)
  credential.helper reads ISO_BB_PAT + ISO_BB_USERNAME from env  # creds never on disk or in argv
  git fetch iso   → refs/remotes/iso/*
  git fetch origin → refs/remotes/origin/*    # origin = iso-10303 (from ./target)
  bash $GITHUB_WORKSPACE/scripts/iso-mirror-sync.sh
```

Conflict-tracking issues are opened on `metanorma/iso-10303` (via `GH_REPO` env) so the team sees them where the content lives — not here.

## Secrets required (in this repo's Settings → Secrets and variables → Actions)

| Secret | Purpose |
|--------|---------|
| `ISO_BB_PAT` | Read-only Bitbucket pilot PAT. The workflow writes a credential helper script that reads the PAT from env at invocation time (never written to `.git/config` or process argv) — so a failed fetch can never leak the PAT value in error messages. |
| `ISO_BB_USERNAME` | Bitbucket account name paired with the PAT (e.g. `ronald.tse@eccma.org`). Required: BB Server's git-over-HTTPS endpoint, unlike its REST API, rejects no-username requests even with a valid PAT. |
| `METANORMA_CI_PAT_TOKEN` | GitHub PAT with `repo` scope on `metanorma/iso-10303`. Used both to push branches to `iso-10303` and to open conflict-tracking issues there. |

Optional repo variable: `PROXY_LAG_THRESHOLD` (integer) — when set, the step summary flags `main` if it's more than N commits ahead of `iso/develop`.

## For proxy users

To run the queue helper locally:

```sh
gh repo clone metanorma/iso-10303-sync
cd iso-10303-sync
bash scripts/iso-proxy-queue.sh
```

Requires `iso` and `origin` (= your `iso-10303` remote) configured in your global git config or in some local checkout. See `docs/iso-mirror-sync.md` §7 for the full proxy flow.

## See also

- **Full spec:** [`docs/iso-mirror-sync.md`](docs/iso-mirror-sync.md)
- **Mirror target:** [`metanorma/iso-10303`](https://github.com/metanorma/iso-10303)
- **Source issue:** [metanorma/iso-10303#693](https://github.com/metanorma/iso-10303/issues/693)
