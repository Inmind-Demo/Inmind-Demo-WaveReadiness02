#!/usr/bin/env bash
# Build the Wave Readiness report site, retaining the last $MAX_RUNS runs.
#
# State persists across executions on a dedicated history branch (the
# workflow checks it out at $HISTORY_DIR before invoking this script).
# Each run is stored under runs/<run_id>/ alongside a metadata.json
# sidecar; the top-level index.html lists all retained runs newest-first.
# Unless KEEP_SUMMARY is 'false', a copy of every run's metadata.json is
# kept under summary/, which is never pruned, so the pass/fail record
# outlives the reports themselves at a few hundred bytes per run.
#
# Layout:
#   $HISTORY_DIR/
#     index.html                 history index (retained runs, newest first)
#     summary/<run_id>.json      one per run ever published; never pruned
#                                (absent when KEEP_SUMMARY=false)
#     runs/<run_id>/
#       index.html               per-run report (areas + scripts table)
#       metadata.json            summary used by the top-level index
#       <area>/<script>/...      Playwright reports + results.xml
#
# Inputs (env):
#   HISTORY_DIR          Persistent site root (the history branch
#                        working tree). Defaults to "site".
#   RUN_ID               GitHub run id; used as the per-run folder name.
#                        Falls back to GITHUB_RUN_ID.
#   RUN_NUMBER           GitHub run number; shown in the run list.
#                        Falls back to GITHUB_RUN_NUMBER.
#   RUN_TIMESTAMP        ISO-8601 UTC timestamp; defaults to now.
#   TARGET_VERSION       Version line for the per-run header.
#   GITHUB_SERVER_URL    Standard Actions vars used to link rows back
#   GITHUB_REPOSITORY    to their Actions run page.
#   GITHUB_RUN_ID
#   MAX_RUNS             Number of runs to keep. Default 7. Older runs
#                        are deleted before the top-level index is built,
#                        so pruning only ever removes runs already on the
#                        branch (the new run survives any prune).
#   KEEP_SUMMARY         'false' disables summary/ and deletes it if
#                        present. Anything else (default 'true') keeps it.
#
# Outputs:
#   $HISTORY_DIR/runs/<id>/        Per-run report tree (added by this run).
#   $HISTORY_DIR/summary/<id>.json Copy of this run's metadata.json
#                                  (unless KEEP_SUMMARY=false).
#   $HISTORY_DIR/index.html        Regenerated top-level history index.
#   total / failed counts to $GITHUB_ENV (sibling steps in this job)
#                          and $GITHUB_OUTPUT (cross-job consumers).

set -euo pipefail

history_dir="${HISTORY_DIR:-site}"
run_id="${RUN_ID:-${GITHUB_RUN_ID:-unknown}}"
run_number="${RUN_NUMBER:-${GITHUB_RUN_NUMBER:-?}}"
run_timestamp="${RUN_TIMESTAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
max_runs="${MAX_RUNS:-7}"
keep_summary="${KEEP_SUMMARY:-true}"
target="${TARGET_VERSION:-<no upgrade>}"

run_dir="$history_dir/runs/$run_id"
mkdir -p "$run_dir"

# Flatten downloaded artifacts into runs/<id>/<area>/<script>/.
# Master-data uploads as replay-results-<area>; the sequential replay job
# uploads as replay-results/<area>. Handle both layouts.
for artifact_dir in replay-results/*/; do
  [ -d "$artifact_dir" ] || continue
  dir_name=$(basename "$artifact_dir")
  if [[ "$dir_name" == replay-results-* ]]; then
    # Named per-area artifact: replay-results/replay-results-<area>/<script>/
    area_name=${dir_name#replay-results-}
    mkdir -p "$run_dir/$area_name"
    cp -r "$artifact_dir"* "$run_dir/$area_name/" 2>/dev/null || true
  elif [[ "$dir_name" == replay-results ]]; then
    # Merged replay artifact: replay-results/replay-results/<area>/<script>/
    for sub in "$artifact_dir"*/; do
      [ -d "$sub" ] || continue
      area_name=$(basename "$sub")
      mkdir -p "$run_dir/$area_name"
      cp -r "$sub"* "$run_dir/$area_name/" 2>/dev/null || true
    done
  else
    # Direct area folder: replay-results/<area>/<script>/
    mkdir -p "$run_dir/$dir_name"
    cp -r "$artifact_dir"* "$run_dir/$dir_name/" 2>/dev/null || true
  fi
done

# Build the per-run index.html. For each area, list each script with
# pass/fail derived from the presence of a non-empty results.xml with
# failures=0, plus a link to that script's Playwright report.
{
  echo '<!doctype html>'
  echo '<html><head><meta charset="utf-8"><title>Wave Readiness Report</title>'
  echo '<style>'
  echo 'body{font-family:system-ui,sans-serif;max-width:900px;margin:2rem auto;padding:0 1rem;color:#222}'
  echo 'h1{border-bottom:2px solid #eee;padding-bottom:.5rem}'
  echo 'h2{margin-top:2rem}'
  echo 'table{border-collapse:collapse;width:100%;margin:.5rem 0}'
  echo 'th,td{text-align:left;padding:.5rem .75rem;border-bottom:1px solid #eee}'
  echo 'th{background:#f7f7f7}'
  echo '.pass{color:#0a7d1a;font-weight:600}'
  echo '.fail{color:#c62828;font-weight:600}'
  echo '.meta{color:#666;font-size:.9rem}'
  echo 'a.back{display:inline-block;margin-bottom:1rem;color:#1565c0;text-decoration:none}'
  echo 'a.back:hover{text-decoration:underline}'
  echo '</style></head><body>'
  echo '<a class="back" href="../../index.html">&larr; All runs</a>'
  echo "<h1>Wave Readiness Report &mdash; Run #${run_number}</h1>"
  echo "<p class=\"meta\">Run: <a href=\"${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}\">#${GITHUB_RUN_ID}</a> &middot; Target: <code>${target}</code> &middot; ${run_timestamp}</p>"

  total=0; failed=0
  while IFS= read -r area_path; do
    [ -d "$area_path" ] || continue
    area_name=$(basename "$area_path")
    echo "<h2>$area_name</h2>"
    echo '<table><thead><tr><th>Script</th><th>Status</th><th>Tests</th><th>Report</th></tr></thead><tbody>'
    while IFS= read -r script_path; do
      [ -d "$script_path" ] || continue
      script_name=$(basename "$script_path")
      results_xml="${script_path}/results.xml"
      report_link="$area_name/$script_name/playwright-report/index.html"
      tests="?"; fails="?"; status_cls="fail"; status_txt="NO RESULT"
      if [ -f "$results_xml" ]; then
        tests=$(grep -oE 'tests="[0-9]+"' "$results_xml" | head -1 | grep -oE '[0-9]+' || echo "?")
        fails=$(grep -oE 'failures="[0-9]+"' "$results_xml" | head -1 | grep -oE '[0-9]+' || echo "?")
        if [ "$fails" = "0" ]; then
          status_cls="pass"; status_txt="PASS"
        else
          status_cls="fail"; status_txt="FAIL"
        fi
      fi
      total=$((total+1))
      if [ "$status_txt" != "PASS" ]; then failed=$((failed+1)); fi
      echo "<tr><td>$script_name</td><td class=\"$status_cls\">$status_txt</td><td>$tests tests / $fails failures</td><td><a href=\"$report_link\">open</a></td></tr>"
    done < <(find "$area_path" -mindepth 1 -maxdepth 1 -type d | sort)
    echo '</tbody></table>'
  done < <(find "$run_dir" -mindepth 1 -maxdepth 1 -type d | sort -t'-' -k2 -n)

  echo "<p class=\"meta\">Total scripts: $total &middot; Failed: $failed</p>"
  echo '</body></html>'
} > "$run_dir/index.html"

# Sidecar metadata so the top-level index can render this run without
# re-parsing each per-run page. JSON-escape the few values that could
# contain a quote or backslash; everything else is workflow-controlled
# and free of newlines.
json_esc() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}
{
  echo '{'
  echo "  \"run_id\": \"$(json_esc "$run_id")\","
  echo "  \"run_number\": \"$(json_esc "$run_number")\","
  echo "  \"run_timestamp\": \"$(json_esc "$run_timestamp")\","
  echo "  \"target_version\": \"$(json_esc "$target")\","
  echo "  \"total\": $total,"
  echo "  \"failed\": $failed"
  echo '}'
} > "$run_dir/metadata.json"

# Keep the summary beyond the run's own retention. summary/ is never
# pruned, so it holds one small file per run ever published. Opting out
# also removes what earlier runs left there, so the setting describes the
# branch rather than only the runs after it was changed.
if [ "$keep_summary" = "false" ]; then
  rm -rf "$history_dir/summary"
else
  mkdir -p "$history_dir/summary"
  cp "$run_dir/metadata.json" "$history_dir/summary/$run_id.json"
fi

# Prune oldest runs to keep only the $max_runs most recent. Run IDs are
# monotonically increasing, so reverse name-sort gives newest-first; the
# current run always survives because it has the highest id.
if [ -d "$history_dir/runs" ]; then
  mapfile -t all_runs < <(find "$history_dir/runs" -mindepth 1 -maxdepth 1 -type d | sort -r)
  if [ "${#all_runs[@]}" -gt "$max_runs" ]; then
    for old in "${all_runs[@]:$max_runs}"; do
      echo "Pruning old run: $(basename "$old")"
      rm -rf "$old"
    done
  fi
fi

# Build the top-level history index. Reads metadata.json from every
# retained run and renders one row per run, newest first. Parsing is
# hand-rolled (one field per line, no nesting) to keep this script
# dependency-free — we wrote the metadata ourselves so the format is
# fixed.
json_str() {
  # $1 = key, $2 = file
  grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" \
    | head -1 \
    | sed -E 's/^[^:]*:[[:space:]]*"(.*)"$/\1/'
}
json_num() {
  grep -oE "\"$1\"[[:space:]]*:[[:space:]]*-?[0-9]+" "$2" \
    | head -1 \
    | grep -oE '\-?[0-9]+$'
}
{
  echo '<!doctype html>'
  echo '<html><head><meta charset="utf-8"><title>Wave Readiness &mdash; Run history</title>'
  echo '<style>'
  echo 'body{font-family:system-ui,sans-serif;max-width:900px;margin:2rem auto;padding:0 1rem;color:#222}'
  echo 'h1{border-bottom:2px solid #eee;padding-bottom:.5rem}'
  echo 'table{border-collapse:collapse;width:100%;margin:.5rem 0}'
  echo 'th,td{text-align:left;padding:.5rem .75rem;border-bottom:1px solid #eee}'
  echo 'th{background:#f7f7f7}'
  echo '.pass{color:#0a7d1a;font-weight:600}'
  echo '.fail{color:#c62828;font-weight:600}'
  echo '.meta{color:#666;font-size:.9rem}'
  echo '</style></head><body>'
  echo '<h1>Wave Readiness &mdash; Run history</h1>'
  echo "<p class=\"meta\">Showing the last $max_runs runs. The most recent run is at the top.</p>"
  echo '<table><thead><tr><th>Run</th><th>Date (UTC)</th><th>Target version</th><th>Status</th><th>Tests</th><th>Report</th></tr></thead><tbody>'

  while IFS= read -r d; do
    meta="$d/metadata.json"
    [ -f "$meta" ] || continue
    m_run_id=$(json_str run_id "$meta")
    m_run_number=$(json_str run_number "$meta")
    m_timestamp=$(json_str run_timestamp "$meta")
    m_target=$(json_str target_version "$meta")
    m_total=$(json_num total "$meta")
    m_failed=$(json_num failed "$meta")
    if [ "$m_failed" = "0" ]; then
      cls="pass"; txt="PASS"
    else
      cls="fail"; txt="FAIL"
    fi
    echo "<tr><td>#$m_run_number</td><td>$m_timestamp</td><td><code>$m_target</code></td><td class=\"$cls\">$txt</td><td>$m_total / $m_failed failed</td><td><a href=\"runs/$m_run_id/index.html\">open</a></td></tr>"
  done < <(find "$history_dir/runs" -mindepth 1 -maxdepth 1 -type d | sort -r)

  echo '</tbody></table>'
  echo '</body></html>'
} > "$history_dir/index.html"

# Counts go to GITHUB_ENV (for sibling steps in this job) and GITHUB_OUTPUT
# (for cross-job consumers via needs.deploy-report.outputs.*).
{
  echo "total=$total"
  echo "failed=$failed"
} >> "$GITHUB_ENV"
{
  echo "total=$total"
  echo "failed=$failed"
} >> "$GITHUB_OUTPUT"
