# Traffic history

Permanent history of this repo's GitHub traffic stats. GitHub's own
Insights → Traffic view keeps only a rolling 14-day window; the `Traffic`
workflow on `main` runs `.github/scripts/update_traffic.py` daily and merges
that window into `history.json` here, so nothing ages out.

- `history.json` — per-day clones and views (count + uniques), plus
  stars/forks/watchers and referrer/path snapshots, recorded only when they
  change. Collection started 2026-08-14; earlier traffic is already lost to
  the 14-day window.
- `badges/` — shields.io endpoint JSON behind the README clones/views
  badges. Totals are "since collection started". Daily `uniques` dedupe
  within one day only, so summing them counts a returning visitor once per
  day — the totals field is named `uniques_day_sum` to keep that honest.

This branch carries only traffic data; the workflow and script live on
`main`.
