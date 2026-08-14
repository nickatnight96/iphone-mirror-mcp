#!/usr/bin/env python3
"""Snapshot GitHub traffic stats into a permanent in-repo history.

GitHub's traffic API only keeps a rolling 14-day window of clone/view data.
This script, run daily by .github/workflows/traffic.yml, merges the current
window into traffic/history.json on the traffic-data branch so the history
survives, and regenerates the shields.io endpoint JSON behind the README
clones/views badges.

Requires TRAFFIC_TOKEN: a fine-grained PAT with Administration:read on this
repo. The workflow's own GITHUB_TOKEN cannot read the traffic endpoints —
GitHub does not support them for app installation tokens.

`update_traffic.py --selftest` exercises the merge/badge logic on fixture
data; scripts/run_tests.sh and CI run it.
"""

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API = "https://api.github.com"
HISTORY_PATH = Path("traffic/history.json")
BADGE_DIR = Path("traffic/badges")


def fetch(path, token):
    req = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:
        if err.code in (401, 403, 404):
            sys.exit(
                f"GET {path} -> HTTP {err.code}. The traffic endpoints need a "
                "fine-grained PAT with Administration:read on this repo, stored "
                "as the TRAFFIC_PAT secret; the workflow's own GITHUB_TOKEN "
                "cannot read them."
            )
        raise


def merge_daily(section, api_days):
    """Fold the API's rolling window into the permanent per-date history."""
    for day in api_days:
        date = day["timestamp"][:10]
        prev = section.get(date, {"count": 0, "uniques": 0})
        # GitHub revises the current day upward as the day progresses; never
        # let a smaller reading replace a larger one already recorded.
        section[date] = {
            "count": max(prev["count"], day["count"]),
            "uniques": max(prev["uniques"], day["uniques"]),
        }
    return section


def totals(section):
    return {
        "count": sum(day["count"] for day in section.values()),
        # Uniques dedupe within a single day only; a visitor returning on a
        # later day is counted again. Named to keep that honest.
        "uniques_day_sum": sum(day["uniques"] for day in section.values()),
    }


def record_change(section, today, value):
    """Append value keyed by date, but only when it differs from the latest
    recorded entry — so quiet days produce no diff and no commit."""
    if section:
        if section[max(section)] == value:
            return
    section[today] = value


def badge(label, message):
    """shields.io 'endpoint' badge schema."""
    return {
        "schemaVersion": 1,
        "label": label,
        "message": str(message),
        "color": "informational",
    }


def update(history, today, clones, views, referrers, paths, meta):
    history["clones"] = merge_daily(history.get("clones", {}), clones["clones"])
    history["views"] = merge_daily(history.get("views", {}), views["views"])
    record_change(history.setdefault("referrers", {}), today, referrers)
    record_change(history.setdefault("paths", {}), today, paths)
    record_change(history.setdefault("stars", {}), today, meta["stargazers_count"])
    record_change(history.setdefault("forks", {}), today, meta["forks_count"])
    record_change(history.setdefault("watchers", {}), today, meta["subscribers_count"])
    history["totals"] = {
        "clones": totals(history["clones"]),
        "views": totals(history["views"]),
    }
    return history


def main():
    repo = os.environ.get("GITHUB_REPOSITORY")
    token = os.environ.get("TRAFFIC_TOKEN")
    if not repo or not token:
        sys.exit("GITHUB_REPOSITORY and TRAFFIC_TOKEN must both be set")

    history = json.loads(HISTORY_PATH.read_text()) if HISTORY_PATH.exists() else {}
    history["repo"] = repo
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    history = update(
        history,
        today,
        fetch(f"/repos/{repo}/traffic/clones", token),
        fetch(f"/repos/{repo}/traffic/views", token),
        fetch(f"/repos/{repo}/traffic/popular/referrers", token),
        fetch(f"/repos/{repo}/traffic/popular/paths", token),
        fetch(f"/repos/{repo}", token),
    )

    HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    HISTORY_PATH.write_text(json.dumps(history, indent=2, sort_keys=True) + "\n")
    BADGE_DIR.mkdir(parents=True, exist_ok=True)
    (BADGE_DIR / "clones.json").write_text(
        json.dumps(badge("clones", history["totals"]["clones"]["count"])) + "\n"
    )
    (BADGE_DIR / "views.json").write_text(
        json.dumps(badge("views", history["totals"]["views"]["count"])) + "\n"
    )
    print(f"{repo}: {json.dumps(history['totals'])}")


def selftest():
    # Overlapping day keeps the max; a new day is appended.
    section = {"2026-08-01": {"count": 5, "uniques": 2}}
    window = [
        {"timestamp": "2026-08-01T00:00:00Z", "count": 3, "uniques": 1},
        {"timestamp": "2026-08-02T00:00:00Z", "count": 7, "uniques": 4},
    ]
    merged = merge_daily(dict(section), window)
    assert merged["2026-08-01"] == {"count": 5, "uniques": 2}, merged
    assert merged["2026-08-02"] == {"count": 7, "uniques": 4}, merged
    # Re-merging the same window changes nothing (the daily run is idempotent).
    assert merge_daily(dict(merged), window) == merged

    t = totals(merged)
    assert t == {"count": 12, "uniques_day_sum": 6}, t

    # record_change skips values identical to the latest entry.
    stars = {}
    record_change(stars, "2026-08-01", 3)
    record_change(stars, "2026-08-02", 3)
    record_change(stars, "2026-08-03", 4)
    assert stars == {"2026-08-01": 3, "2026-08-03": 4}, stars

    # The badge JSON matches the shields.io endpoint schema.
    b = badge("clones", 12)
    assert b == {
        "schemaVersion": 1,
        "label": "clones",
        "message": "12",
        "color": "informational",
    }, b

    # End-to-end update() on fixtures.
    hist = update(
        {},
        "2026-08-14",
        {"clones": [{"timestamp": "2026-08-14T00:00:00Z", "count": 2, "uniques": 2}]},
        {"views": [{"timestamp": "2026-08-14T00:00:00Z", "count": 9, "uniques": 3}]},
        [{"referrer": "github.com", "count": 4, "uniques": 2}],
        [{"path": "/x", "title": "x", "count": 4, "uniques": 2}],
        {"stargazers_count": 1, "forks_count": 0, "subscribers_count": 1},
    )
    assert hist["totals"] == {
        "clones": {"count": 2, "uniques_day_sum": 2},
        "views": {"count": 9, "uniques_day_sum": 3},
    }, hist["totals"]
    assert hist["stars"] == {"2026-08-14": 1}, hist["stars"]
    print("selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        main()
