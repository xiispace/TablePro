#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-/tmp}"
STATE="${2:-all}"
REPO="TablePlus/TablePlus"
PAGES=2
PER_PAGE=100

command -v gh >/dev/null 2>&1 || { echo "gh CLI required: https://cli.github.com" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq required: brew install jq" >&2; exit 1; }

mkdir -p "$OUT_DIR"

fetch_sorted() {
    local sort="$1"
    local out="$OUT_DIR/tableplus-issues-${sort}.json"
    echo "Fetching top $((PAGES * PER_PAGE)) ${STATE} issues from $REPO sorted by $sort..."
    local tmp
    tmp=$(mktemp)
    echo "[]" > "$tmp"
    for page in $(seq 1 "$PAGES"); do
        gh api "repos/$REPO/issues?state=$STATE&sort=$sort&per_page=$PER_PAGE&page=$page" \
            --jq '[.[] | select(.pull_request == null) | {
                number, title, html_url, created_at, state, closed_at,
                comments, reactions: .reactions.total_count,
                labels: [.labels[].name],
                body: (.body // "" | .[0:1000])
            }]' \
            | jq --slurpfile acc "$tmp" '. + $acc[0]' > "${tmp}.next"
        mv "${tmp}.next" "$tmp"
    done
    mv "$tmp" "$out"
    local count open_count closed_count
    count=$(jq 'length' "$out")
    open_count=$(jq '[.[] | select(.state == "open")] | length' "$out")
    closed_count=$(jq '[.[] | select(.state == "closed")] | length' "$out")
    echo "Wrote $count issues to $out (open: $open_count, closed: $closed_count)"
}

fetch_sorted reactions
fetch_sorted comments
