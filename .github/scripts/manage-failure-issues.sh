#!/usr/bin/env bash
# Copyright (c) 2026 inMind Technologies. Licensed under the MIT License.
# SPDX-License-Identifier: MIT
# Open / comment / close GitHub issues per Wave Readiness script failure.
#
# Walks the run report tree built by build-report-site.sh. For each script:
#   - failed + open issue      -> comment on the existing issue
#   - failed + no open issue   -> create one (labelled wave-readiness)
#   - passed + open issue      -> close it with a "passing again" comment
#   - passed + no open issue   -> nothing to do
#   - a script directory without a results.xml is treated as a failure,
#     matching the per-run report's "NO RESULT" handling.
#
# The issue title is stable across runs ("[Wave Readiness] <area> /
# <script>"), so a script that breaks once and recovers leaves a single
# closed issue rather than a trail of duplicates.
#
# Inputs (env):
#   GH_TOKEN         Token for the gh CLI (the workflow's GITHUB_TOKEN).
#                    Job needs `issues: write` permission.
#   HISTORY_DIR      Where build-report-site.sh placed runs/<run_id>/.
#   RUN_ID           This run's id (folder under runs/, link target).
#   RUN_NUMBER       Friendly run number for body / comment text.
#   PAGE_URL         Pages root, with trailing slash.
#   RUN_URL          Actions run page URL.
#   TARGET_VERSION   Target version line shown in the body.
#   ISSUE_LABEL      Label applied to managed issues (default: wave-readiness).

set -euo pipefail

history_dir="${HISTORY_DIR:-history}"
run_id="${RUN_ID:-${GITHUB_RUN_ID:-unknown}}"
run_number="${RUN_NUMBER:-${GITHUB_RUN_NUMBER:-?}}"
target="${TARGET_VERSION:-<no upgrade>}"
page_url="${PAGE_URL:-}"
run_url="${RUN_URL:-}"
label="${ISSUE_LABEL:-wave-readiness}"

run_dir="$history_dir/runs/$run_id"
if [ ! -d "$run_dir" ]; then
  echo "No run dir at $run_dir; nothing to manage."
  exit 0
fi

# Repositories can have Issues switched off. Every gh issue command then
# fails with "has disabled issues", which would fail the deploy-report job
# after the site has already shipped. Skip with a warning instead; the
# report site and the history branch still carry the failures.
repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
has_issues=$(gh api "repos/${repo}" --jq .has_issues 2>/dev/null || echo "unknown")
if [ "$has_issues" = "false" ]; then
  echo "::warning::Issues are disabled on ${repo}; skipping failure-issue management. Enable Issues in the repository settings to get one issue per failing script."
  exit 0
fi

# Idempotent label create. The `|| true` swallows "already exists" so
# manual colour/description tweaks made in the UI are preserved.
gh label create "$label" \
  --color B60205 \
  --description "Auto-managed by Wave Readiness Validation workflow" \
  >/dev/null 2>&1 || true

# Snapshot all open issues with our label up front so the per-script
# loop is one find_issue call (in-memory) instead of a search API hit.
# Format per line: "<number>\t<title>".
mapfile -t existing < <(
  gh issue list --label "$label" --state open --limit 200 \
    --json number,title --jq '.[] | "\(.number)\t\(.title)"'
)

# Echo the issue number for an exact title match, or empty.
find_issue() {
  local needle="$1"
  local row num title
  for row in "${existing[@]}"; do
    num="${row%%$'\t'*}"
    title="${row#*$'\t'}"
    if [ "$title" = "$needle" ]; then
      printf '%s' "$num"
      return
    fi
  done
}

opened=0; commented=0; closed=0
while IFS= read -r script_dir; do
  script_name=$(basename "$script_dir")
  area_name=$(basename "$(dirname "$script_dir")")
  results_xml="$script_dir/results.xml"

  if [ -f "$results_xml" ]; then
    fails=$(grep -oE 'failures="[0-9]+"' "$results_xml" | head -1 | grep -oE '[0-9]+' || echo "0")
    fails="${fails:-0}"
  else
    # No JUnit = bc-replay didn't finish. Same handling as NO RESULT.
    fails="1"
  fi

  # One-line cause written by Invoke-ReplayArea.ps1 next to results.xml.
  cause=""
  if [ -f "$script_dir/failure-cause.txt" ]; then
    cause=$(tr -d '\r\n' < "$script_dir/failure-cause.txt")
  fi
  [ -n "$cause" ] || cause="Not recorded; open the Playwright report."

  title="[Wave Readiness] ${area_name} / ${script_name}"
  # Encode spaces in path components so the Markdown link in the issue body
  # isn't truncated at the first whitespace by GitHub's parser.
  area_enc="${area_name// /%20}"
  script_enc="${script_name// /%20}"
  report_url="${page_url}runs/${run_id}/${area_enc}/${script_enc}/playwright-report/index.html"
  existing_num=$(find_issue "$title")

  if [ "$fails" != "0" ]; then
    if [ -n "$existing_num" ]; then
      gh issue comment "$existing_num" --body "Still failing on run [#${run_number}](${run_url}) (target \`${target}\`).

**Cause:**
\`\`\`text
${cause}
\`\`\`

[Open Playwright report](${report_url})" >/dev/null
      commented=$((commented+1))
      echo "Commented on #${existing_num}: ${area_name} / ${script_name}"
    else
      gh issue create \
        --title "$title" \
        --label "$label" \
        --body "**Script:** \`${area_name} / ${script_name}\`
**Status:** failing on run [#${run_number}](${run_url})
**Target version:** \`${target}\`
**Cause:**
\`\`\`text
${cause}
\`\`\`

[Open Playwright report](${report_url})

---

Auto-managed by \`.github/workflows/WaveReadinessValidation.yaml\`. This issue closes automatically once the script passes on a future run." >/dev/null
      opened=$((opened+1))
      echo "Opened issue: ${area_name} / ${script_name}"
    fi
  else
    if [ -n "$existing_num" ]; then
      gh issue close "$existing_num" --comment "Passing again on run [#${run_number}](${run_url}) (target \`${target}\`). Auto-closing.

[Open Playwright report](${report_url})" >/dev/null
      closed=$((closed+1))
      echo "Closed #${existing_num}: ${area_name} / ${script_name}"
    fi
  fi
done < <(find "$run_dir" -mindepth 2 -maxdepth 2 -type d | sort)

echo "Issue management: ${opened} opened, ${commented} commented, ${closed} closed."
