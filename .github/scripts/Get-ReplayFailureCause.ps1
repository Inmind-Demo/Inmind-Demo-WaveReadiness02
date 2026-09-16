# Copyright (c) 2026 inMind Technologies. Licensed under the MIT License.
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
  Explain, in one line, why a bc-replay recording failed.

.DESCRIPTION
  bc-replay's own console output for a failed recording is only
  "One or more test recordings failed." The real reason is in the files it
  leaves behind in -ResultDir, in decreasing order of precision:

    Replay log attachment       which step failed and bc-replay's message
                                (present only when bc-replay caught the error
                                itself, e.g. a validate step that did not match)
    results.xml                 Playwright's failure text per attempt
                                (timeouts, locator errors, stack traces)
    error-context.md            what was on screen when Playwright gave up
                                (an open dialog, the Microsoft MFA page)

  Playwright retries a failed recording once, so results.xml carries one block
  per attempt. Only the final attempt decides the outcome, so the cause comes
  from that one. When an earlier attempt failed for a different reason it is
  appended, so a flaky sign-in on attempt 1 is not mistaken for the real
  problem found on attempt 2, or the other way round.

  Examples of what this returns:
    Step 7 "Validate Balance ($) is 0" failed: Was expecting '0' but got '32538'.
    Timed out after 120s with an unanswered dialog: "The invoice is posted as number 108237 ... Do you want to open the posted invoice?"
    Timed out after 120s during Microsoft sign-in (MFA code page)

.PARAMETER ScriptResultDir
  The directory bc-replay was given as -ResultDir. Holds results.xml and
  playwright-report/.

.OUTPUTS
  [string] Exactly one line, never empty. Never throws: a bug in this parser
  must not hide the original failure, so any internal error degrades to a
  generic pointer at the report.
#>
param(
  [Parameter(Mandatory)][string]$ScriptResultDir
)

$ErrorActionPreference = 'Stop'

# bc-replay step descriptions carry markup, e.g.
# "Validate <caption>Balance ($)</caption> <operation>is</operation> <value>0</value>".
function Get-CleanText {
  param([string]$Text)
  $t = $Text -replace '</?[a-zA-Z]+>', ''
  ($t -replace '\s+', ' ').Trim()
}

# Playwright writes attachment paths relative to the HTML report directory,
# e.g. "..\..\..\..\test-results\<test>\error-context.md". On the runner the
# test-results folder lives under $RUNNER_TEMP, where bc-replay is installed
# and run from. Try there first, then the path exactly as written.
function Resolve-AttachmentPath {
  param([string]$RelPath)
  if (-not $RelPath) { return $null }
  $sep  = [System.IO.Path]::DirectorySeparatorChar
  $norm = $RelPath.Replace('\', $sep).Replace('/', $sep)
  $candidates = @()
  $idx = $norm.IndexOf("test-results$sep")
  if ($idx -ge 0 -and $env:RUNNER_TEMP) {
    $candidates += Join-Path $env:RUNNER_TEMP $norm.Substring($idx)
  }
  $candidates += Join-Path (Join-Path $ScriptResultDir 'playwright-report') $norm
  foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c -PathType Leaf) { return (Get-Item -LiteralPath $c).FullName }
  }
  return $null
}

# Fallback for when the attachment's original path is gone (e.g. this script
# is run against a downloaded artifact): the HTML report keeps a copy of every
# attachment under playwright-report/data/, named by content hash. Return the
# first file of the given type whose content matches.
function Find-ReportData {
  param([string]$Filter, [string]$Pattern)
  $dataDir = Join-Path (Join-Path $ScriptResultDir 'playwright-report') 'data'
  if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) { return $null }
  foreach ($f in (Get-ChildItem -LiteralPath $dataDir -Filter $Filter -File)) {
    if ((Get-Content -LiteralPath $f.FullName -Raw) -match $Pattern) { return $f.FullName }
  }
  return $null
}

function Format-StepCause {
  param([int]$No, [string]$Desc, [string]$Msg)
  $m = $Msg.Trim()
  if ($m.Length -ge 2 -and (($m[0] -eq '"' -and $m[-1] -eq '"') -or ($m[0] -eq "'" -and $m[-1] -eq "'"))) {
    $m = $m.Substring(1, $m.Length - 2)
  }
  $d = Get-CleanText $Desc
  if ($d) { return "Step $No `"$d`" failed: $m" }
  return "Step $No failed: $m"
}

# The replay log is the recording with a `log:` block added to each step the
# player reached; the step that failed carries `log: { error: { message } }`.
# A hand-rolled line scan is enough here (no YAML parser ships with pwsh):
# steps are list items introduced by "- type:", and the message is the first
# "message:" after an "error:" inside the current step.
function Get-ReplayLogCause {
  param([string]$Path)
  $stepNo = 0; $desc = ''; $descIndent = -1; $inDesc = $false; $inError = $false
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    if ($line -match '^\s*-\s+type:') {
      $stepNo++; $desc = ''; $inDesc = $false; $inError = $false
      continue
    }
    if ($line -match '^(\s*)description:\s*(.*)$') {
      $descIndent = $matches[1].Length; $desc = $matches[2]; $inDesc = $true
      continue
    }
    if ($inDesc) {
      # YAML folds long descriptions onto deeper-indented continuation lines.
      if ($line -match '^(\s*)\S' -and $matches[1].Length -gt $descIndent -and $line -notmatch '^\s*[\w-]+:(\s|$)') {
        $desc += ' ' + $line.Trim()
        continue
      }
      $inDesc = $false
    }
    if ($line -match '^\s*error:\s*(.*)$') {
      $inline = $matches[1].Trim()
      if ($inline) { return Format-StepCause $stepNo $desc $inline }
      $inError = $true
      continue
    }
    if ($inError -and $line -match '^\s*message:\s*(.*)$') {
      return Format-StepCause $stepNo $desc $matches[1]
    }
  }
  return $null
}

# error-context.md is Playwright's accessibility snapshot of the page at the
# moment of failure. Two things on it explain most timeouts: a modal dialog
# the recording never answers, or the Microsoft sign-in flow not completing.
function Get-ScreenHint {
  param([string]$Path)
  $text = Get-Content -LiteralPath $Path -Raw
  $m = [regex]::Match($text, '(?m)^\s*-\s+(?:alert)?dialog\s+"((?:[^"\\]|\\.)*)"')
  if ($m.Success) { return "with an unanswered dialog: `"$($m.Groups[1].Value)`"" }
  if ($text -match '"Enter code"') { return 'during Microsoft sign-in (MFA code page)' }
  if ($text -match '"Enter password"|"Enter your email|"Stay signed in|"Pick an account"|heading "Sign in"') {
    return 'during Microsoft sign-in'
  }
  return $null
}

# One attempt's block of Playwright failure text -> one-line cause.
function Get-AttemptCause {
  param([string]$Block)
  $lines = @($Block -split "`r?`n" | ForEach-Object { $_.Trim() })

  # The error text runs from the top of the block to the first attachment.
  # Drop the "[chromium] > ..." header, stack frames and the "=== logs ==="
  # rules Playwright draws around its own diagnostics.
  $errLines = New-Object System.Collections.Generic.List[string]
  foreach ($l in $lines) {
    if ($l -match '^(attachment #\d+|Error Context:)') { break }
    if (-not $l) { continue }
    if ($l -match '^\[\w+\]' -or $l -match '^at ' -or $l -match '^=+') { continue }
    $errLines.Add($l)
  }
  $errText = $errLines -join ' '

  $ctxRel = $null; $replayRel = $null
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^Error Context:\s*(.+)$') { $ctxRel = $matches[1] }
    if ($lines[$i] -match '^attachment #\d+: Replay log' -and ($i + 1) -lt $lines.Count) { $replayRel = $lines[$i + 1] }
  }

  # 1. bc-replay's replay log names the failing step. Most precise.
  if ($replayRel) {
    $replayLog = Resolve-AttachmentPath $replayRel
    if (-not $replayLog) { $replayLog = Find-ReportData -Filter '*.yml' -Pattern '(?m)^\s+error:\s*$' }
    if ($replayLog) {
      $c = Get-ReplayLogCause $replayLog
      if ($c) { return $c }
    }
  }

  # 2. Playwright killed the test: say what was on screen at that moment.
  if ($errText -match 'Test timeout of (\d+)ms exceeded') {
    $secs = [int]$matches[1] / 1000
    $hint = $null
    if ($ctxRel) {
      $ctx = Resolve-AttachmentPath $ctxRel
      if (-not $ctx) { $ctx = Find-ReportData -Filter '*.md' -Pattern '(?m)^\s*-\s+(?:alert)?dialog\s+"|"Enter code"' }
      if ($ctx) { $hint = Get-ScreenHint $ctx }
    }
    if (-not $hint -and $Block -match '\bat authenticate') { $hint = 'during Microsoft sign-in' }
    if (-not $hint) { $hint = 'with no visible progress; check the screenshot and video in the report' }
    return "Timed out after ${secs}s $hint"
  }

  # 3. bc-replay caught the error but its replay log could not be read.
  if ($errText -match 'Received:\s*"([^"]+)"') { return "Replay step failed: $($matches[1])" }

  # 4. Anything else: the first "Error: ..." line, minus the prefix.
  $first = $errLines | Where-Object { $_ -match '^(\w*Error|Error):' } | Select-Object -First 1
  if (-not $first) { $first = $errLines | Select-Object -First 1 }
  if ($first) { return ($first -replace '^Error:\s*', '') }
  return 'Failed without an error message; open the Playwright report.'
}

try {
  $xmlPath = Join-Path $ScriptResultDir 'results.xml'
  if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
    Write-Output 'bc-replay produced no results.xml, so the recording never reached a Playwright result. The cause is in the job log just above this line.'
    return
  }
  $raw = Get-Content -LiteralPath $xmlPath -Raw
  $fm = [regex]::Match($raw, '(?s)<(?:failure|error)\b[^>]*>(.*?)</(?:failure|error)>')
  if (-not $fm.Success) {
    $fails = if ($raw -match 'failures="(\d+)"') { $matches[1] } else { '?' }
    Write-Output "bc-replay exited non-zero but results.xml records $fails failure(s) and no failure text. Check the job log just above this line."
    return
  }
  $body = $fm.Groups[1].Value
  $cd = [regex]::Match($body, '(?s)<!\[CDATA\[(.*?)\]\]>')
  $text = if ($cd.Success) { $cd.Groups[1].Value } else { [System.Net.WebUtility]::HtmlDecode($body) }

  # One block per attempt; Playwright separates retries with "Retry #N ----".
  $blocks = @([regex]::Split($text, '(?m)^[ \t]*Retry #\d+[^\r\n]*$') | Where-Object { $_.Trim() })
  $causes = @($blocks | ForEach-Object { Get-AttemptCause $_ } | Where-Object { $_ })
  if ($causes.Count -eq 0) {
    Write-Output 'Failed without an error message; open the Playwright report.'
    return
  }

  $final = $causes[-1]
  if ($causes.Count -gt 1) {
    $earlier = @($causes[0..($causes.Count - 2)] | Where-Object { $_ -ne $final } | Select-Object -Unique)
    if ($earlier.Count -gt 0) { $final += " (an earlier attempt failed differently: $($earlier -join ' | '))" }
  }
  $final = ($final -replace '[\r\n]+', ' ' -replace '\s+', ' ').Trim()
  if ($final.Length -gt 700) { $final = $final.Substring(0, 697) + '...' }
  Write-Output $final
}
catch {
  Write-Output "Could not work out the cause automatically ($($_.Exception.Message)). Open results.xml in the Playwright report."
}
