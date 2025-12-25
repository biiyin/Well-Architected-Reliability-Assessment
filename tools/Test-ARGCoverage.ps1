[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $SubscriptionIds,

    [Parameter()]
    [string[]] $ResourceGroups,

    [Parameter()]
    [string] $OutputDir = (Join-Path -Path (Get-Location) -ChildPath 'output'),

    [Parameter()]
    [switch] $IncludeArgTypeSample,

    [Parameter()]
    [int] $ArgTypeSampleLimit = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-OutputDir {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-NowStamp {
    return (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss')
}

function Safe-Count {
    param([object] $Value)
    if ($null -eq $Value) { return 0 }
    if ($Value -is [System.Array]) { return @($Value).Count }
    return @($Value).Count
}

function Try-SearchAzGraphCount {
    param(
        [Parameter(Mandatory = $true)][string] $SubscriptionId,
        [Parameter(Mandatory = $true)][string] $TypeFilterKql
    )

    $q = @"
Resources
| where subscriptionId == '$SubscriptionId'
| where $TypeFilterKql
| count
"@

    try {
        $r = Search-AzGraph -Subscription $SubscriptionId -Query $q -First 10 -ErrorAction Stop
        # Search-AzGraph returns an object or array with Count property column named 'Count'
        $count = 0
        foreach ($row in @($r)) {
            if ($null -ne $row.Count) { $count = [int]$row.Count }
        }
        return [pscustomobject]@{ ok = $true; count = $count; error = $null }
    }
    catch {
        return [pscustomobject]@{ ok = $false; count = $null; error = $_.Exception.Message }
    }
}

function Get-ControlPlaneVnetPeerings {
    param(
        [Parameter(Mandatory = $true)][string] $SubscriptionId,
        [Parameter()][string[]] $ResourceGroups
    )

    # Normalize resource group inputs:
    # - allow passing RG names (demo)
    # - allow passing RG IDs (/subscriptions/.../resourceGroups/demo)
    # - allow comma-separated lists when invoked from shells that don't preserve PowerShell array syntax
    $normalizedRgs = @()
    foreach ($rg in @($ResourceGroups)) {
        if ([string]::IsNullOrWhiteSpace([string]$rg)) { continue }
        foreach ($piece in ([string]$rg -split '\s*,\s*')) {
            if ([string]::IsNullOrWhiteSpace($piece)) { continue }
            $normalizedRgs += $piece
        }
    }

    $ctx = Get-AzContext
    if ($null -eq $ctx -or [string]::IsNullOrWhiteSpace([string]$ctx.Subscription)) {
        throw 'No Azure context. Run Connect-AzAccount first.'
    }

    # Ensure correct subscription context
    try {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    }
    catch {
        throw ("Failed to Set-AzContext to subscription {0}: {1}" -f $SubscriptionId, $_.Exception.Message)
    }

    $vnets = @()
    if ($normalizedRgs -and $normalizedRgs.Count -gt 0) {
        foreach ($rg in $normalizedRgs) {
            $rgName = $null

            if ($rg -match '/resourceGroups/([^/]+)') {
                $rgName = $Matches[1]
            }
            else {
                $rgName = $rg
            }

            $rgName = ([string]$rgName).Trim('/')
            if ([string]::IsNullOrWhiteSpace($rgName)) { continue }
            try {
                $vnets += @(Get-AzVirtualNetwork -ResourceGroupName $rgName -ErrorAction SilentlyContinue)
            }
            catch {
                # ignore per-RG failures
            }
        }
    }
    else {
        $vnets = @(Get-AzVirtualNetwork -ErrorAction SilentlyContinue)
    }

    $peerings = @()
    foreach ($vnet in @($vnets)) {
        if ($null -eq $vnet) { continue }
        $rgName = [string]$vnet.ResourceGroupName
        $vnetName = [string]$vnet.Name
        if ([string]::IsNullOrWhiteSpace($rgName) -or [string]::IsNullOrWhiteSpace($vnetName)) { continue }

        $ps = @(Get-AzVirtualNetworkPeering -ResourceGroupName $rgName -VirtualNetworkName $vnetName -ErrorAction SilentlyContinue)
        foreach ($p in $ps) {
            if ($null -eq $p) { continue }
            $peerings += [pscustomobject]@{
                id                 = [string]$p.Id
                name               = [string]$p.Name
                resourceGroup      = $rgName
                virtualNetworkName = $vnetName
                peeringState       = [string]$p.PeeringState
                remoteVnetId       = [string]$p.RemoteVirtualNetwork.Id
            }
        }
    }

    return , @($peerings)
}

function New-MarkdownReport {
    param(
        [Parameter(Mandatory = $true)][hashtable] $RunInfo,
        [Parameter(Mandatory = $true)][object[]] $Results,
        [Parameter()][object[]] $ArgTypeSample
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add('# Azure Resource Graph Coverage Report')
    $lines.Add('')
    $lines.Add(('Generated: {0}' -f $RunInfo.Timestamp))
    $lines.Add(('Cloud: {0}' -f $RunInfo.Cloud))
    $lines.Add(('Tenant: {0}' -f $RunInfo.Tenant))
    $lines.Add(('Subscriptions: {0}' -f ($RunInfo.Subscriptions -join ', ')))
    if ($RunInfo.ResourceGroups -and $RunInfo.ResourceGroups.Count -gt 0) {
        $lines.Add(('ResourceGroups filter: {0}' -f ($RunInfo.ResourceGroups -join ', ')))
    }
    $lines.Add('')

    $lines.Add('## Summary')
    $lines.Add('This report compares what Azure Resource Graph (ARG) returns vs what control-plane cmdlets return for selected checks. A mismatch usually means ARG coverage/indexing differs in this cloud/environment or for that resource type.')
    $lines.Add('')

    foreach ($r in $Results) {
        $lines.Add(('## {0} ({1})' -f $r.CheckName, $r.SubscriptionId))
        $lines.Add(('ARG query: `{0}`' -f $r.ArgQueryShort))

        if ($r.Arg.ok) {
            $lines.Add(('ARG count: {0}' -f $r.Arg.count))
        }
        else {
            $lines.Add(('ARG error: {0}' -f $r.Arg.error))
        }

        if ($r.ControlPlane.ok) {
            $lines.Add(('Control-plane count: {0}' -f $r.ControlPlane.count))
        }
        else {
            $lines.Add(('Control-plane error: {0}' -f $r.ControlPlane.error))
        }

        if ($r.Conclusion) {
            $lines.Add(('Conclusion: **{0}**' -f $r.Conclusion))
        }
        if ($r.Notes) {
            $lines.Add(('Notes: {0}' -f $r.Notes))
        }
        $lines.Add('')

        if ($r.Sample -and $r.Sample.Count -gt 0) {
            $lines.Add('Sample (first 10):')
            $lines.Add('')
            $lines.Add('```text')
            foreach ($s in @($r.Sample | Select-Object -First 10)) {
                $lines.Add([string]$s)
            }
            $lines.Add('```')
            $lines.Add('')
        }
    }

    if ($ArgTypeSample -and $ArgTypeSample.Count -gt 0) {
        $lines.Add('## ARG Type Sample')
        $lines.Add(('A sample of distinct resource types seen by ARG in this environment (first {0}).' -f $ArgTypeSample.Count))
        $lines.Add('')
        $lines.Add('```text')
        foreach ($t in $ArgTypeSample) {
            $lines.Add([string]$t)
        }
        $lines.Add('```')
        $lines.Add('')
    }

    $lines.Add('## Practical Guidance')
    $lines.Add('- If ARG returns 0 but control-plane returns >0, treat it as an ARG coverage/indexing gap for this cloud/environment and use a fallback (Az.* cmdlets or ARM REST) for that resource type.')
    $lines.Add('- For network topology, VNets/subnets/NICs usually work well in ARG, but child resources can be inconsistent across clouds.')

    return ($lines -join "`n")
}

# --- Main ---
Ensure-OutputDir -Path $OutputDir

$ctx = Get-AzContext
if ($null -eq $ctx) {
    throw 'No Azure context. Run Connect-AzAccount first.'
}

$runInfo = @{
    Timestamp      = (Get-Date).ToString('s')
    Cloud          = [string]$ctx.Environment.Name
    Tenant         = [string]$ctx.Tenant.Id
    Subscriptions  = $SubscriptionIds
    ResourceGroups = $ResourceGroups
}

$allResults = New-Object System.Collections.Generic.List[object]

foreach ($sub in $SubscriptionIds) {
    # --- Check: VNet peerings ---
    $arg = Try-SearchAzGraphCount -SubscriptionId $sub -TypeFilterKql "type =~ 'microsoft.network/virtualnetworks/virtualnetworkpeerings'"

    $cp = $null
    $cpPeerings = $null
    try {
        $cpPeerings = Get-ControlPlaneVnetPeerings -SubscriptionId $sub -ResourceGroups $ResourceGroups
        $cp = [pscustomobject]@{ ok = $true; count = (Safe-Count $cpPeerings); error = $null }
    }
    catch {
        $detail = $_.Exception.Message
        if ($_.ScriptStackTrace) {
            $detail = "{0}`n{1}" -f $detail, $_.ScriptStackTrace
        }
        $cp = [pscustomobject]@{ ok = $false; count = $null; error = $detail }
    }

    $conclusion = $null
    $notes = $null
    if ($arg.ok -and $cp.ok) {
        if ($arg.count -eq 0 -and $cp.count -gt 0) {
            $conclusion = 'ARG returns 0 but control-plane finds peerings (coverage/indexing gap)'
            $notes = 'In sovereign clouds (e.g., AzureChinaCloud), some child resource types may not be available via ARG. Use Get-AzVirtualNetworkPeering fallback.'
        }
        elseif ($arg.count -eq $cp.count) {
            $conclusion = 'ARG matches control-plane for this check'
        }
        else {
            $conclusion = 'ARG and control-plane differ (investigate scope/filters or indexing delay)'
        }
    }
    elseif (-not $arg.ok -and $cp.ok) {
        $conclusion = 'ARG query failed but control-plane succeeded'
    }
    elseif ($arg.ok -and -not $cp.ok) {
        $conclusion = 'Control-plane query failed but ARG succeeded'
    }

    $sampleLines = @()
    if ($cpPeerings) {
        foreach ($p in ($cpPeerings | Select-Object -First 10)) {
            $sampleLines += ("{0}  state={1}  remote={2}" -f $p.id, $p.peeringState, $p.remoteVnetId)
        }
    }

    $allResults.Add([pscustomobject]@{
            CheckName    = 'VNet Peerings'
            SubscriptionId = $sub
            ArgQueryShort  = "type =~ 'microsoft.network/virtualnetworks/virtualnetworkpeerings'"
            Arg          = $arg
            ControlPlane = $cp
            Conclusion   = $conclusion
            Notes        = $notes
            Sample       = $sampleLines
        })
}

$argTypeSample = @()
if ($IncludeArgTypeSample) {
    try {
        $sub0 = $SubscriptionIds | Select-Object -First 1
        $q = "Resources | where subscriptionId == '$sub0' | distinct type | order by type asc | limit $ArgTypeSampleLimit"
        $r = Search-AzGraph -Subscription $sub0 -Query $q -First $ArgTypeSampleLimit -ErrorAction Stop
        $argTypeSample = @($r | ForEach-Object { $_.type })
    }
    catch {
        $argTypeSample = @("Failed to fetch ARG type sample: $($_.Exception.Message)")
    }
}

$stamp = Get-NowStamp
$outMd = Join-Path -Path $OutputDir -ChildPath ("ARG-Coverage-Report-{0}.md" -f $stamp)
$outJson = Join-Path -Path $OutputDir -ChildPath ("ARG-Coverage-Report-{0}.json" -f $stamp)

$resultsArray = $allResults.ToArray()

$report = New-MarkdownReport -RunInfo $runInfo -Results $resultsArray -ArgTypeSample $argTypeSample
$report | Out-File -LiteralPath $outMd -Encoding utf8

@{
    runInfo  = $runInfo
    results  = $resultsArray
} | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $outJson -Encoding utf8

Write-Host ("Report written: {0}" -f $outMd) -ForegroundColor Green
Write-Host ("Raw results:  {0}" -f $outJson) -ForegroundColor Green
