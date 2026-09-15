# Copyright (c) 2026 inMind Technologies. Licensed under the MIT License.
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
  Resolve a user-supplied target version against the BC admin API's /updates
  list for an environment, then PATCH the selected version to schedule the
  upgrade.

.DESCRIPTION
  Called from the copy-and-upgrade job in WaveReadinessValidation.yaml.
  Accepts the same three forms as the workflow_dispatch input:
    - 'latest'   - newest released GA/Preview offered for the environment
    - bare major - e.g. '28' resolves to the newest released minor in that wave
    - exact N.M  - must be released (not pending) and offered

  The /updates endpoint excludes the environment's current version (you can
  only upgrade to something strictly newer) and may list slots reserved for
  versions that have not shipped yet, so alias resolution runs only against
  released, non-EarlyAccessPreview entries. EAP requires Partner Sandbox
  licensing; callers who want it must pass the exact version string.

  When the sandbox is already on / above the requested version, this emits a
  workflow warning and returns Skipped=$true so the caller can proceed with
  the replay at the current version (still useful signal) instead of
  failing the whole workflow.

.PARAMETER Token
  Bearer token with admin API access. Mask upstream before calling.

.PARAMETER AdminApiBase
  e.g. https://api.businesscentral.dynamics.com/admin/v2.28/applications/BusinessCentral

.PARAMETER EnvironmentName
  Sandbox to upgrade, e.g. 'SANDBOX-Waves'.

.PARAMETER RequestedVersion
  Alias or exact version string. Trimmed before use.

.OUTPUTS
  [pscustomobject] with:
    CurrentVersion - environment version before the upgrade (or '(unknown)')
    Resolved       - exact version patched; '' when Skipped
    ResolvedType   - GA | Preview | EarlyAccessPreview; '' when Skipped
    Skipped        - $true when no upgrade was scheduled (see SkipReason)
    SkipReason     - human-readable explanation when Skipped=$true
#>
param(
  [Parameter(Mandatory)][string]$Token,
  [Parameter(Mandatory)][string]$AdminApiBase,
  [Parameter(Mandatory)][string]$EnvironmentName,
  [Parameter(Mandatory)][string]$RequestedVersion
)

$ErrorActionPreference = 'Stop'

$headers    = @{ Authorization = "Bearer $Token" }
$envUri     = "$AdminApiBase/environments/$EnvironmentName"
$updatesUri = "$envUri/updates"

# The copy step produces a sandbox at the source environment's version; the
# admin API's /updates endpoint will never list the current version (only
# versions strictly above it), which is why we need this separate call to
# detect 'already on the version you asked for'.
$envInfo = Invoke-RestMethod -Method Get -Uri $envUri -Headers $headers
$currentVersion = $envInfo.applicationVersion
if (-not $currentVersion) { $currentVersion = $envInfo.version }
if (-not $currentVersion) { $currentVersion = '(unknown)' }
Write-Host "Sandbox current version: $currentVersion"

function New-SkipResult([string]$reason) {
  Write-Host "::warning::$reason Proceeding with replay at current version ($currentVersion)."
  [pscustomobject]@{
    CurrentVersion = $currentVersion
    Resolved       = ''
    ResolvedType   = ''
    Skipped        = $true
    SkipReason     = $reason
  }
}

# The /updates endpoint lists every future major.minor slot Microsoft has
# reserved for this environment, NOT just versions that can be installed
# today. Each entry has:
#
#   available            bool   - has the version actually shipped?
#   targetVersionType    string - 'GA' | 'Preview' | 'EarlyAccessPreview'
#   expectedAvailability {month,year} - set when available=false
#
# PATCHing an unreleased version is supported but useless for CI: the Update
# operation just sits Queued until the version ships, which is days to weeks
# away. So we only resolve aliases against released versions.
$updates = Invoke-RestMethod -Method Get -Uri $updatesUri -Headers $headers
$entries = @($updates.value)
if ($entries.Count -eq 0) {
  throw "Admin API returned no offered target versions for $EnvironmentName. The sandbox may already be on the newest version."
}

# [version] requires at least two components, so pad bare majors with '.0'.
function Parse-BcVersion($v) {
  if ($v -notmatch '\.') { return [version]"$v.0" }
  return [version]$v
}

$released = @($entries | Where-Object { $_.available -eq $true } |
              Sort-Object { Parse-BcVersion $_.targetVersion } -Descending)
$pending  = @($entries | Where-Object { $_.available -ne $true } |
              Sort-Object { Parse-BcVersion $_.targetVersion })

Write-Host "Released target versions (installable now):"
if ($released.Count -eq 0) {
  Write-Host "  (none)"
} else {
  $released | ForEach-Object { Write-Host "  - $($_.targetVersion) [$($_.targetVersionType)]" }
}
if ($pending.Count -gt 0) {
  Write-Host "Pending target versions (slot reserved, not yet released):"
  $pending | ForEach-Object {
    $exp = if ($_.expectedAvailability) { " (expected $($_.expectedAvailability.month)/$($_.expectedAvailability.year))" } else { '' }
    Write-Host "  - $($_.targetVersion) [$($_.targetVersionType)]$exp"
  }
}

# Exclude EarlyAccessPreview from alias resolution - it requires a Partner
# Sandbox license; users who specifically want it can pass the exact version.
$aliasCandidates = @($released | Where-Object { $_.targetVersionType -ne 'EarlyAccessPreview' })

# Empty released list = sandbox is already at the latest shipped version.
# Skip the upgrade; wave-readiness run against the current GA build is still
# useful signal (catches anything broken by the prod->sandbox copy or by
# recent Microsoft hot-fixes), and failing the whole workflow would hide that.
if ($released.Count -eq 0) {
  $msg = "Sandbox is already on the latest released version ($currentVersion). No upgrade available."
  if ($pending.Count -gt 0) {
    $next = $pending | Select-Object -First 1
    $exp = if ($next.expectedAvailability) { "$($next.expectedAvailability.month)/$($next.expectedAvailability.year)" } else { 'unknown' }
    $msg += " Next pending version is $($next.targetVersion), expected $exp."
  }
  return (New-SkipResult $msg)
}

$requested = $RequestedVersion.Trim()

# User explicitly named the version the sandbox is already on. /updates
# wouldn't list it, so the exact-match branch would fail with a confusing
# 'not offered' - short-circuit here and just run the replay at that version.
if ($requested -ieq $currentVersion) {
  return (New-SkipResult "Sandbox is already on version '$currentVersion'.")
}

$match = $null

if ($requested -ieq 'latest') {
  if ($aliasCandidates.Count -eq 0) {
    throw "'latest' requested but no GA or Preview versions are released. Only EarlyAccessPreview is offered, which requires Partner Sandbox licensing - pass the exact version to opt in."
  }
  $match = $aliasCandidates | Select-Object -First 1
  Write-Host "'latest' resolved to $($match.targetVersion) [$($match.targetVersionType)]"
}
elseif ($requested -match '^\d+$') {
  $major = [int]$requested
  $inMajor = $aliasCandidates | Where-Object { (Parse-BcVersion $_.targetVersion).Major -eq $major }
  if (-not $inMajor) {
    # Nothing released in that major. Three sub-cases; distinguish so the
    # error tells the user the right next step.
    $currentMajor = $null
    try { $currentMajor = (Parse-BcVersion $currentVersion).Major } catch {}
    $pendingInMajor = $pending | Where-Object { (Parse-BcVersion $_.targetVersion).Major -eq $major }
    if ($currentMajor -eq $major) {
      $pendingNote = if ($pendingInMajor) { " Next pending in major ${major}: $($pendingInMajor[0].targetVersion)." } else { '' }
      return (New-SkipResult "Sandbox is already on the latest released minor in major $major ($currentVersion).$pendingNote")
    }
    if ($pendingInMajor) {
      $earliest = $pendingInMajor | Select-Object -First 1
      $exp = if ($earliest.expectedAvailability) { "$($earliest.expectedAvailability.month)/$($earliest.expectedAvailability.year)" } else { 'unknown' }
      throw "No versions in major $major are released yet. Earliest pending: $($earliest.targetVersion), expected $exp. Try 'latest' or a different major."
    }
    $releasedMajors = ($aliasCandidates | ForEach-Object { (Parse-BcVersion $_.targetVersion).Major } | Select-Object -Unique) -join ', '
    throw "No versions offered for major $major. Released majors: $releasedMajors."
  }
  $match = $inMajor | Select-Object -First 1
  Write-Host "Major '$requested' resolved to $($match.targetVersion) [$($match.targetVersionType)] (newest released minor in that wave)."
}
else {
  # Exact version requested. Match against the full offered list (including
  # EarlyAccessPreview and pending), but reject pending.
  $exactReleased = $entries | Where-Object { $_.targetVersion -eq $requested -and $_.available -eq $true } | Select-Object -First 1
  if ($exactReleased) {
    $match = $exactReleased
    Write-Host "Exact match: $($match.targetVersion) [$($match.targetVersionType)]"
  }
  else {
    $exactPending = $entries | Where-Object { $_.targetVersion -eq $requested -and $_.available -ne $true } | Select-Object -First 1
    if ($exactPending) {
      $exp = if ($exactPending.expectedAvailability) { "$($exactPending.expectedAvailability.month)/$($exactPending.expectedAvailability.year)" } else { 'unknown' }
      throw "Version '$requested' is offered but not yet released (expected $exp). Scheduling it would block the workflow until Microsoft ships it. Try 'latest' or a released version."
    }
    $releasedList = ($released | ForEach-Object { $_.targetVersion }) -join ', '
    throw "Version '$requested' is not offered for $EnvironmentName (sandbox currently on $currentVersion). Released targets: $releasedList."
  }
}

$resolved     = $match.targetVersion
$resolvedType = $match.targetVersionType

$patchUri = "$updatesUri/$resolved"
$nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# targetVersionType is required in the body whenever the target is not GA. The
# API defaults it to 'GA' when the property is omitted, and the PATCH URI
# carries only the bare version number - so during a preview window, when
# Microsoft offers both a Preview and a GA row for the same major.minor (29.0
# preview released alongside 29.0 GA pending), omitting it resolves to the GA
# row. That row has available=false, so the request fails with
#   EntityValidationFailed - "Modifying ScheduleDetails for updates with
#   available=false is not supported"
# which reads like a version-availability problem rather than a missing field.
# The GET returns the type lowercased ('preview'); the body expects the
# documented casing, so map rather than pass the value straight through.
$typeMap   = @{ 'ga' = 'GA'; 'preview' = 'Preview'; 'earlyaccesspreview' = 'EarlyAccessPreview' }
$patchType = $typeMap[([string]$resolvedType).ToLowerInvariant()]
if (-not $patchType) { $patchType = 'GA' }

$body = @{
  selected          = $true
  targetVersionType = $patchType
  scheduleDetails   = @{
    selectedDateTime   = $nowUtc
    ignoreUpdateWindow = $true
  }
} | ConvertTo-Json -Depth 3
Invoke-RestMethod -Method Patch -Uri $patchUri -Headers $headers `
  -Body $body -ContentType 'application/json' | Out-Null
Write-Host "Upgrade to $resolved [$resolvedType] scheduled for immediate start (selectedDateTime=$nowUtc, ignoreUpdateWindow=true)."

[pscustomobject]@{
  CurrentVersion = $currentVersion
  Resolved       = $resolved
  ResolvedType   = $resolvedType
  Skipped        = $false
  SkipReason     = ''
}
