# Copyright (c) 2026 inMind Technologies. Licensed under the MIT License.
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
  Mint an Entra access token with the client-credentials flow and mask it in
  the run log.

.DESCRIPTION
  The one place the pipeline exchanges a client secret for a bearer token.
  The acquire-entra-token composite action calls it once per step, and the
  long polls in the copy-and-upgrade job call it again from inside their
  loops: an access token lives about an hour, a sandbox copy can take that
  long, and a major-version upgrade regularly takes longer, so a token minted
  before the poll starts expires while the operation is still running and
  the admin API answers 401 to a job that is otherwise healthy.

  Emits ::add-mask:: before returning, so the token never appears in the log
  even if a caller echoes it.

.PARAMETER TenantId
  Entra tenant ID.

.PARAMETER ClientId
  Entra app (client) ID.

.PARAMETER ClientSecret
  Entra app client secret.

.PARAMETER Scope
  OAuth scope, e.g. 'https://api.businesscentral.dynamics.com/.default' or
  'https://graph.microsoft.com/.default'.

.OUTPUTS
  System.String. The bearer access token.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$TenantId,
  [Parameter(Mandatory)][string]$ClientId,
  [Parameter(Mandatory)][string]$ClientSecret,
  [Parameter(Mandatory)][string]$Scope
)
$ErrorActionPreference = 'Stop'

$body = @{
  grant_type    = 'client_credentials'
  client_id     = $ClientId
  client_secret = $ClientSecret
  scope         = $Scope
}
$uri   = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$resp  = Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded'
$token = $resp.access_token
if (-not $token) { throw "Token endpoint returned no access_token for scope '$Scope'." }
Write-Host "::add-mask::$token"
$token
