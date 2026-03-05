<#
.SYNOPSIS
    Runs a single Azure Resource Graph query and prints basic timing + sample output.

.DESCRIPTION
    This script is intended for troubleshooting Resource Graph issues independently of the full WARA collector.
    It runs a single Search-AzGraph call (optionally scoped to subscriptions) with no paging by default.

.PARAMETER AzureEnvironment
    Azure environment name (e.g., AzureChinaCloud).

.PARAMETER TenantId
    Tenant ID to authenticate against.

.PARAMETER SubscriptionIds
    Subscription IDs (GUIDs). If omitted, UseTenantScope will be used.

.PARAMETER QueryPath
    Path to a .kql file containing the query.

.PARAMETER First
    Page size to request.

.EXAMPLE
    pwsh -NoProfile -File .\tools\Test-WARAResourceGraphQuery.ps1 -AzureEnvironment AzureChinaCloud -TenantId <tenantGuid> -SubscriptionIds <subGuid> -QueryPath .\output\ARG-Query-<hash>.kql
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('AzureCloud', 'AzureChinaCloud', 'AzureUSGovernment', 'AzureGermanCloud')]
    [string] $AzureEnvironment = 'AzureChinaCloud',

    [Parameter(Mandatory = $true)]
    [Guid] $TenantId,

    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]] $SubscriptionIds,

    [Parameter(Mandatory = $true)]
    [string] $QueryPath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000)]
    [int] $First = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$QueryPath = (Resolve-Path -LiteralPath $QueryPath -ErrorAction Stop).Path
$query = Get-Content -LiteralPath $QueryPath -Raw -ErrorAction Stop

$queryPreview = ($query -replace '[\r\n\t]+', ' ') -replace '\s{2,}', ' '
if ($queryPreview.Length -gt 200) { $queryPreview = $queryPreview.Substring(0, 200) + '...' }

Write-Host ("{0:o} ARG test start. Env={1} Tenant={2} SubCount={3} First={4}" -f (Get-Date), $AzureEnvironment, $TenantId, @($SubscriptionIds).Count, $First)
Write-Host ("{0:o} QueryPath={1}" -f (Get-Date), $QueryPath)
Write-Host ('{0:o} QueryPreview="{1}"' -f (Get-Date), $queryPreview)

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.ResourceGraph -ErrorAction Stop

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Write-Host ("{0:o} Connecting to Azure..." -f (Get-Date))
    Connect-AzAccount -Environment $AzureEnvironment -Tenant $TenantId | Out-Null
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
if ($SubscriptionIds -and @($SubscriptionIds).Count -gt 0) {
    $resp = Search-AzGraph -Query $query -Subscription $SubscriptionIds -First $First -ErrorAction Stop
}
else {
    $resp = Search-AzGraph -Query $query -UseTenantScope -First $First -ErrorAction Stop
}
$sw.Stop()

$data = @()
if ($null -ne $resp -and $null -ne $resp.Data) { $data = @($resp.Data) }

Write-Host ("{0:o} ARG test complete. DurationMs={1} RowsReturned={2} HasSkipToken={3}" -f (Get-Date), $sw.ElapsedMilliseconds, $data.Count, ([bool]$resp.SkipToken))

# Print a tiny sample so it is obvious the query returned something.
if ($data.Count -gt 0) {
    $data | Select-Object -First ([Math]::Min(3, $data.Count)) | Format-List *
}
