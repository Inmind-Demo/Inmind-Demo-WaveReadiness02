# Copyright (c) 2026 inMind Technologies. Licensed under the MIT License.
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
  Replay every .yml page script under one PageScriptLibrary area using
  @microsoft/bc-replay, sequentially, in natural file-name order (numbers
  inside a name compare by value, so "Script 2" runs before "Script 10").

.DESCRIPTION
  Shared by the master-data and replay jobs in WaveReadinessValidation.yaml.
  The caller is responsible for installing bc-replay first (see
  .github/actions/setup-bc-replay) and for setting BC_USER / BC_PASS /
  BC_TOTP environment variables from job secrets — this script never sees
  raw credentials, it only tells bc-replay which env var names to read.

.PARAMETER AreaName
  Folder name under PageScriptLibrary/ (e.g. 'MasterData - 1').

.PARAMETER SandboxUrl
  Full start URL for bc-replay, e.g.
  https://businesscentral.dynamics.com/<tenant>/<env>/

.PARAMETER WorkspaceRoot
  Repo checkout root. Scripts are read from
    $WorkspaceRoot/PageScriptLibrary/$AreaName/*.yml
  Results are written under
    $WorkspaceRoot/replay-results/$AreaName/<script-name>/

.OUTPUTS
  [pscustomobject] with Area, Total, Failed. Does NOT throw on failures —
  the caller decides whether to throw, and with what message, because the
  wording differs across phases (master-data blocks the matrix, plain replay
  reports the failed area list, etc.).
#>
param(
  [Parameter(Mandatory)][string]$AreaName,
  [Parameter(Mandatory)][string]$SandboxUrl,
  [Parameter(Mandatory)][string]$WorkspaceRoot
)

$ErrorActionPreference = 'Stop'

$areaDir     = Join-Path $WorkspaceRoot "PageScriptLibrary/$AreaName"
$areaResults = Join-Path $WorkspaceRoot "replay-results/$AreaName"
New-Item -ItemType Directory -Force -Path $areaResults | Out-Null

# Natural sort: "Page Scripting 10 - ..." must run after "Page Scripting 9 - ...",
# not straight after "Page Scripting 1 - ..." as a plain name sort would have it.
# Every digit run in the name is left-padded to a fixed width so an ordinary
# string comparison orders numbers by value; the raw name breaks ties.
function Get-NaturalSortKey {
  param([Parameter(Mandatory)][string]$Name)
  [regex]::Replace($Name, '\d+', { param($m) $m.Value.PadLeft(20, '0') })
}

$scripts = Get-ChildItem -Path $areaDir -Filter '*.yml' -File |
  Sort-Object { Get-NaturalSortKey $_.Name }, Name
Write-Host "Area '$AreaName': found $($scripts.Count) script(s) in $areaDir"

# npx --no-install resolves `replay` from the CWD's node_modules/.bin. The
# setup-bc-replay composite action installs into $RUNNER_TEMP, so run npx
# from there regardless of what the caller's working-directory happens to be.
$replayHome = $env:RUNNER_TEMP
if (-not $replayHome) {
  throw "RUNNER_TEMP is not set — run setup-bc-replay before Invoke-ReplayArea."
}

$failed = New-Object System.Collections.Generic.List[string]
Push-Location $replayHome
try {
  foreach ($script in $scripts) {
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($script.Name)
    $scriptResultDir = Join-Path $areaResults $scriptName
    New-Item -ItemType Directory -Force -Path $scriptResultDir | Out-Null
    Write-Host "::group::Running $($script.Name)"

    $replayArgs = @(
      $script.FullName,
      '-StartAddress',   $SandboxUrl,
      '-Authentication', 'AAD',
      '-UserNameKey',    'BC_USER',
      '-PasswordKey',    'BC_PASS',
      '-ResultDir',      $scriptResultDir
    )
    if ($env:BC_TOTP) {
      $replayArgs += @('-MultiFactorType', 'TOTP', '-MultiFactorSecretKey', 'BC_TOTP')
    }

    npx --no-install replay @replayArgs
    $exit = $LASTEXITCODE
    Write-Host "::endgroup::"
    if ($exit -ne 0) {
      Write-Host "::error::Script $($script.Name) failed with exit code $exit"
      $failed.Add($script.Name)
    }
  }
}
finally {
  Pop-Location
}

[pscustomobject]@{
  Area   = $AreaName
  Total  = $scripts.Count
  Failed = $failed
}
