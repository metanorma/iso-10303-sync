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

It runs in *this* repo (so the script is available locally), then operates on the two content remotes via `git`:

```
actions/checkout@v4          # checks out THIS repo (for scripts/)
git remote add target …       # metanorma/iso-10303 (uses PRIVATE_TOKEN_GITHUB)
git remote add iso …          # sd.iso.org Bitbucket pilot (uses ISO_BB_PAT)
git fetch iso   → refs/remotes/iso/*
git fetch target → refs/remotes/target/*
bash scripts/iso-mirror-sync.sh   # with ORIGIN_REMOTE=target
```

Conflict-tracking issues are opened on `metanorma/iso-10303` (via `GH_REPO` env) so the team sees them where the content lives — not here.

## Secrets required (in this repo's Settings → Secrets and variables → Actions)

| Secret | Purpose |
|--------|---------|
| `ISO_BB_PAT` | Read-only Bitbucket pilot PAT. The PAT encodes the owning account, so the workflow uses `https://:${ISO_BB_PAT}@host`. |
| `PRIVATE_TOKEN_GITHUB` | GitHub PAT with `repo` scope on `metanorma/iso-10303`. Used both to push branches to `iso-10303` and to open conflict-tracking issues there. |

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
