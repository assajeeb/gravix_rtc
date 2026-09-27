#!/usr/bin/env bash
#
# `flutter analyze`, baselined.
#
# Green on the issues listed in tool/analyze_baseline.txt (none today); red on
# anything new, including a new instance of
# an already-baselined rule in the same file — the baseline is compared as a
# multiset, not a set.
set -uo pipefail

cd "$(dirname "$0")/.."
BASELINE="tool/analyze_baseline.txt"
raw="$(mktemp)"
trap 'rm -f "$raw" "$raw".cur "$raw".base' EXIT

flutter analyze --no-fatal-infos --no-fatal-warnings 2>&1 | tee "$raw"

# `flutter analyze` prints "<severity> • <message> • <path>:<line>:<col> • <rule>".
# Normalise to "<severity>|<path>|<rule>" so line numbers cannot flip the job.
grep -E '^[[:space:]]*(error|warning|info) • ' "$raw" \
  | sed -E 's/^[[:space:]]*([a-z]+) • .* • ([^ ]+):[0-9]+:[0-9]+ • ([a-z_]+)[[:space:]]*$/\1|\2|\3/' \
  | sort > "$raw".cur

grep -vE '^[[:space:]]*(#|$)' "$BASELINE" | sort > "$raw".base

new="$(comm -23 "$raw".cur "$raw".base)"
gone="$(comm -13 "$raw".cur "$raw".base)"

if [ -n "$gone" ]; then
  echo
  echo "note: baselined issues that no longer occur — drop them from $BASELINE:"
  echo "$gone" | sed 's/^/  /'
fi

if [ -n "$new" ]; then
  echo
  echo "FAIL: analyze issues that are not baselined:"
  echo "$new" | sed 's/^/  /'
  echo
  echo "Fix them, or — only if they are in vendored upstream code that is"
  echo "re-synced rather than edited — add them to $BASELINE."
  exit 1
fi

echo
echo "OK: $(wc -l < "$raw".cur | tr -d ' ') analyze issue(s), all baselined."
