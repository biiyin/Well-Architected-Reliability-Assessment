<#
.SYNOPSIS
Export a simplified (deduplicated) network topology model from a WARA JSON output.

.DESCRIPTION
WARA output JSON contains a `resourceInventory` array with `topology_*` fields.
This script groups resources by (resource type + connected network), where connected
network is defined as the set of VNet/Subnet IDs referenced by:
- topology_vnetIds / topology_subnetIds
- topology_privateEndpointVnetIds / topology_privateEndpointSubnetIds

For each group it selects ONE representative resource (sample) and emits a graph
model (nodes + edges) suitable for drawing a network diagram without clutter.

.PARAMETER InputPath
Path to either:
- a WARA output JSON file (e.g. output/WARA-File-*.json) OR
- a WARA Analyzer Excel file (e.g. Expert-Analysis-v1-*.xlsx).

If the file extension is `.xlsx` (or `.xlsm`), the script reads the `WorkloadInventory` worksheet
(or `2.WorkloadInventory` / `6.WorkloadInventory`) and parses the `networkConfig` column to
reconstruct `topology_*` fields.

For other extensions (or no extension), the script treats the file as JSON (default).

.PARAMETER ExcelStartRow
Row number where the `WorkloadInventory` table header starts. Defaults to 12 (WARA Analyzer default).

.PARAMETER OutputJson
Optional path to write the graph model JSON.

.PARAMETER OutputMd
Optional path to write a human-readable Markdown summary.

.PARAMETER MermaidByResourceGroup
When set (default), emit one Mermaid diagram per Resource Group in the Markdown output.

To disable and generate a single high-level Mermaid diagram for the whole inventory, pass
`-MermaidByResourceGroup:$false`.


.EXAMPLE
pwsh -NoProfile -File .\tools\Export-WARANetworkTopology.ps1 -InputPath .\output\WARA-File-2025-12-24-20-49.json -OutputJson .\output\WARA-NetworkTopology.json -OutputMd .\output\WARA-NetworkTopology.md

.EXAMPLE
pwsh -NoProfile -File .\tools\Export-WARANetworkTopology.ps1 -InputPath .\output\WARA-File-2025-12-24-20-49.json -OutputMd .\output\WARA-NetworkTopology.md -MermaidByResourceGroup:$false

.EXAMPLE
pwsh -NoProfile -File .\tools\Export-WARANetworkTopology.ps1 -InputPath .\output\Expert-Analysis-v1-2025-12-26-00-09.xlsx -OutputMd .\output\WARA-NetworkTopology.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [Alias('Input')]
    [string]$InputPath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000)]
    [int]$ExcelStartRow = 12,

    [Parameter(Mandatory = $false)]
    [string]$OutputJson,

    [Parameter(Mandatory = $false)]
    [string]$OutputMd

    ,
    [Parameter(Mandatory = $false)]
    [switch]$MermaidByResourceGroup = $true
)

Set-StrictMode -Version Latest

function Get-CaseInsensitivePropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Obj,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Obj) { return $null }
    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $p = $Obj.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
        if ($p) { return $p.Value }
    }
    return $null
}

function Convert-NetworkConfigToHashtable {
    param([object]$NetworkConfig)

    if ($null -eq $NetworkConfig) { return @{} }

    # Case 1: Already a parsed object (rare but possible)
    if ($NetworkConfig -isnot [string]) {
        try {
            $h = @{}
            foreach ($p in $NetworkConfig.PSObject.Properties) {
                if ($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.Name)) { continue }
                $h[[string]$p.Name] = $p.Value
            }
            return $h
        }
        catch {
            return @{}
        }
    }

    $s = [string]$NetworkConfig
    if ([string]::IsNullOrWhiteSpace($s)) { return @{} }

    # Case 2: Compressed JSON string
    $trim = $s.Trim()
    if ($trim.StartsWith('{') -and $trim.EndsWith('}')) {
        try {
            $obj = $trim | ConvertFrom-Json -ErrorAction Stop
            $h2 = @{}
            foreach ($p in $obj.PSObject.Properties) {
                if ($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.Name)) { continue }
                $h2[[string]$p.Name] = $p.Value
            }
            return $h2
        }
        catch {
            # Fall through to key=value parsing
        }
    }

    # Case 3: Multiline key=value string
    $h3 = @{}
    foreach ($line in ($s -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { continue }
        $k = $line.Substring(0, $idx).Trim()
        $v = $line.Substring($idx + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        $h3[$k] = $v
    }
    return $h3
}

function Convert-WorkloadInventoryExcelToResourceInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$StartRow
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input file not found: $Path"
    }

    if (-not (Get-Command -Name Import-Excel -ErrorAction SilentlyContinue)) {
        throw "Import-Excel command not found. Install the ImportExcel module (Install-Module ImportExcel -Scope CurrentUser) or use a JSON input (.json)."
    }

    $worksheetCandidates = @(
        'WorkloadInventory',
        '2.WorkloadInventory'
    )

    $rows = $null
    foreach ($ws in $worksheetCandidates) {
        try {
            # WARA Analyzer exports tables starting at row 12 by default (header row).
            $rows = Import-Excel -Path $Path -WorksheetName $ws -StartRow $StartRow -ErrorAction Stop
            if ($rows) { break }
        }
        catch {
            $rows = $null
        }
    }

    if (-not $rows) {
        throw "Could not read WorkloadInventory sheet from Excel. Tried: $($worksheetCandidates -join ', ')"
    }

    $keyToTopologyProp = @{
        vnetIds                  = 'topology_vnetIds'
        subnetIds                = 'topology_subnetIds'
        subnetPrefixPairs         = 'topology_subnetPrefixPairs'
        nicIds                   = 'topology_nicIds'
        privateEndpointIds        = 'topology_privateEndpointIds'
        privateEndpointSubnetIds  = 'topology_privateEndpointSubnetIds'
        privateEndpointVnetIds    = 'topology_privateEndpointVnetIds'
        privateLinkTargetIds      = 'topology_privateLinkTargetIds'
        connectedResourceIds      = 'topology_connectedResourceIds'
        publicIpIds               = 'topology_publicIpIds'
        publicIpAddresses         = 'topology_publicIpAddresses'
        publicIpPrefixIds         = 'topology_publicIpPrefixIds'
        publicFqdns               = 'topology_publicFqdns'
        privateIps                = 'topology_privateIps'
        publicNetworkAccess       = 'topology_publicNetworkAccess'

        # WARA Analyzer Excel stores these without the topology_ prefix
        vnetPeeringRemoteVnetIds  = 'topology_vnetPeeringRemoteVnetIds'
        vnetPeeringDetails        = 'topology_vnetPeeringDetails'
    }

    $result = New-Object System.Collections.Generic.List[object]

    foreach ($row in @($rows)) {
        if ($null -eq $row) { continue }

        $id = [string](Get-CaseInsensitivePropertyValue -Obj $row -Names @('id', 'resourceId', 'ResourceId'))
        $name = [string](Get-CaseInsensitivePropertyValue -Obj $row -Names @('name', 'resourceName', 'ResourceName'))
        $type = [string](Get-CaseInsensitivePropertyValue -Obj $row -Names @('type', 'resourceType', 'ResourceType'))
        $location = [string](Get-CaseInsensitivePropertyValue -Obj $row -Names @('location', 'Location'))
        $resourceGroup = [string](Get-CaseInsensitivePropertyValue -Obj $row -Names @('resourceGroup', 'ResourceGroup', 'resource group', 'Resource Group'))
        $subscriptionId = [string](Get-CaseInsensitivePropertyValue -Obj $row -Names @('subscriptionId', 'SubscriptionId', 'subscription', 'Subscription'))
        $tenantId = [string](Get-CaseInsensitivePropertyValue -Obj $row -Names @('tenantId', 'TenantId', 'tenant', 'Tenant'))
        $networkConfig = Get-CaseInsensitivePropertyValue -Obj $row -Names @('networkConfig', 'NetworkConfig')

        # If a row doesn't have core identity, keep it out of the topology model.
        if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($type)) { continue }

        # Keep shape compatible with JSON inventory and StrictMode: declare commonly referenced
        # properties even when networkConfig is empty.
        $r = [pscustomobject]@{
            id   = $id
            name = $name
            type = $type.ToLowerInvariant()

            tenantId       = $tenantId
            location       = $location
            resourceGroup  = $resourceGroup
            subscriptionId = $subscriptionId

            topology_vnetIds                     = $null
            topology_subnetIds                   = $null
            topology_subnetPrefixPairs            = $null
            topology_nicIds                      = $null
            topology_privateEndpointIds           = $null
            topology_privateEndpointSubnetIds     = $null
            topology_privateEndpointVnetIds       = $null
            topology_privateLinkTargetIds         = $null
            topology_connectedResourceIds         = $null
            topology_publicIpIds                  = $null
            topology_publicIpAddresses            = $null
            topology_publicIpPrefixIds            = $null
            topology_publicFqdns                  = $null
            topology_privateIps                   = $null
            topology_publicNetworkAccess          = $null
            topology_vnetPeeringRemoteVnetIds     = $null
            topology_vnetPeeringDetails           = $null
        }

        $nc = Convert-NetworkConfigToHashtable $networkConfig
        foreach ($k in @($nc.Keys)) {
            if ([string]::IsNullOrWhiteSpace([string]$k)) { continue }
            $keyNorm = [string]$k
            if ($keyToTopologyProp.ContainsKey($keyNorm)) {
                $propName = $keyToTopologyProp[$keyNorm]
                $val = $nc[$k]
                if ($null -ne $val -and -not [string]::IsNullOrWhiteSpace([string]$val)) {
                    $r | Add-Member -NotePropertyName $propName -NotePropertyValue $val -Force
                }
            }
            elseif ($keyNorm -like 'topology_*') {
                $val2 = $nc[$k]
                if ($null -ne $val2 -and -not [string]::IsNullOrWhiteSpace([string]$val2)) {
                    $r | Add-Member -NotePropertyName $keyNorm -NotePropertyValue $val2 -Force
                }
            }
        }

        $result.Add($r) | Out-Null
    }

    return $result.ToArray()
}

function Normalize-IdList {
    param([object]$Value)

    if ($null -eq $Value) { return @() }

    # WARA sometimes serializes lists as a ';' delimited string (e.g., Join-StringList in topology enrichment).
    # Also accept JSON arrays.
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        $parts = $Value.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        return @($parts | Sort-Object -Unique)
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($v in $Value) {
            if ($null -eq $v) { continue }
            $s = [string]$v
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            $items += $s.Trim()
        }
        return @($items | Sort-Object -Unique)
    }

    $s2 = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s2)) { return @() }
    return @($s2.Trim())
}


function Get-SubscriptionIdFromArmId {
    param([string]$ResourceId)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return $null }
    $m = [regex]::Match($ResourceId, '(?i)/subscriptions/([^/]+)')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function ConvertTo-MermaidSafeLabel {
    param([string]$Label)
    if ($null -eq $Label) { return '' }
    return ([string]$Label).Replace('"', "'")
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Obj,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Join-Ids {
    param([string[]]$Ids)
    if (-not $Ids -or $Ids.Count -eq 0) { return '' }
    return ($Ids | Sort-Object -Unique) -join ';'
}

function Convert-SubnetPrefixPairsToMap {
    param([object]$Value)

    $map = @{}
    foreach ($pair in @(Normalize-IdList $Value)) {
        if ([string]::IsNullOrWhiteSpace([string]$pair)) { continue }
        $idx = ([string]$pair).IndexOf('|')
        if ($idx -lt 1) { continue }
        $sid = ([string]$pair).Substring(0, $idx).Trim()
        $pfx = ([string]$pair).Substring($idx + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($sid) -or [string]::IsNullOrWhiteSpace($pfx)) { continue }
        $map[$sid.ToLowerInvariant()] = $pfx
    }
    return $map
}

function Get-NetworkKey {
    param($r)

    # IMPORTANT: For connectivity grouping/diagramming, treat Private Endpoint reverse-mapping fields
    # (topology_privateEndpointVnetIds / topology_privateEndpointSubnetIds) as *Private Link metadata*.
    # Do NOT mix them into the general "resource is in this VNet" concept, otherwise a PaaS target will
    # appear both directly connected to a VNet and also via Private Link (duplicate-looking path).
    $vnetIds = @(Normalize-IdList $r.topology_vnetIds) | Sort-Object -Unique
    $subnetIds = @(Normalize-IdList $r.topology_subnetIds) | Sort-Object -Unique

    # Private Link connectivity (reverse mapping for targets): a PaaS resource may not be "in" a VNet
    # but can still be connected via one or more private endpoints in specific VNets/Subnets.
    $plVnetIds = @(Normalize-IdList $r.topology_privateEndpointVnetIds) | Sort-Object -Unique
    $plSubnetIds = @(Normalize-IdList $r.topology_privateEndpointSubnetIds) | Sort-Object -Unique

    $v = Join-Ids $vnetIds
    $s = Join-Ids $subnetIds
    $plv = Join-Ids $plVnetIds
    $pls = Join-Ids $plSubnetIds

    # Internet connectivity signals (offline)
    $publicIpIds = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $r -Name 'topology_publicIpIds'))
    $publicIps = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $r -Name 'topology_publicIpAddresses'))
    $publicFqdns = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $r -Name 'topology_publicFqdns'))

    $publicNetworkAccessRaw = [string](Get-OptionalPropertyValue -Obj $r -Name 'topology_publicNetworkAccess')
    $publicNetworkAccessNorm = [string]::IsNullOrWhiteSpace($publicNetworkAccessRaw) ? $null : $publicNetworkAccessRaw.Trim().ToLowerInvariant()
    $pnaEnabled = $false
    $pnaDisabled = $false
    if ($publicNetworkAccessNorm) {
        if ($publicNetworkAccessNorm -in @('enabled', 'true', 'yes')) { $pnaEnabled = $true }
        if ($publicNetworkAccessNorm -in @('disabled', 'false', 'no')) { $pnaDisabled = $true }
    }

    $privateEndpointIds = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $r -Name 'topology_privateEndpointIds'))
    $privateEndpointSubnetIds = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $r -Name 'topology_privateEndpointSubnetIds'))
    $privateEndpointVnetIds = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $r -Name 'topology_privateEndpointVnetIds'))

    $hasAnyPublicIpOrFqdn = ((@($publicIpIds).Count + @($publicIps).Count + @($publicFqdns).Count) -gt 0)

    # Internet connectivity signals (offline)
    # Signals (offline-only):
    # 1) Public IP / Public FQDNs captured during collect/enrich
    # 2) topology_publicNetworkAccess explicitly enabled/disabled
    $internetConnected = $false
    if (-not $pnaDisabled) {
        $internetConnected = ($hasAnyPublicIpOrFqdn -or $pnaEnabled)
    }
    $internetKey = $internetConnected ? 'internet:yes' : 'internet:no'

    if ([string]::IsNullOrWhiteSpace($v) -and [string]::IsNullOrWhiteSpace($s) -and [string]::IsNullOrWhiteSpace($plv) -and [string]::IsNullOrWhiteSpace($pls)) {
        return "no-network||$internetKey"
    }

    # Include method-separated keys so same-type resources only group when both network AND connection method match.
    return "direct:vnet:$v|subnet:$s||privatelink:vnet:$plv|subnet:$pls||$internetKey"
}

function Get-DisplayNameFromId {
    param([string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return '' }

    # Common ARM id format: .../providers/<RP>/<type>/<name>[/<childType>/<childName>]
    $parts = $ResourceId.Trim('/').Split('/')
    if ($parts.Count -lt 1) { return $ResourceId }

    return $parts[-1]
}

function Get-ResourceTypeFromId {
    param([string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return '' }

    # ARM id typically includes .../providers/<RP>/<type>/<name>[/<childType>/<childName>]
    $m = [regex]::Match($ResourceId, '(?i)/providers/([^/]+)/(.+)$')
    if (-not $m.Success) { return '' }

    $afterProviders = $m.Groups[2].Value
    $segments = $afterProviders.Split('/')
    if ($segments.Count -lt 2) { return '' }

    $types = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $segments.Count; $i += 2) {
        $types.Add($segments[$i]) | Out-Null
    }

    return "{0}/{1}" -f $m.Groups[1].Value, ($types -join '/')
}

function Get-GroupSummariesFromInventory {
    param(
        [Parameter(Mandatory = $true)][object[]]$InventorySubset
    )

    # Group by: resource type + connected network key
    $localGroups = @($InventorySubset | Group-Object -Property @{ Expression = { "{0}|{1}" -f $_.type, (Get-NetworkKey $_) } })

    $groupCounterLocal = 0
    $groupSummariesLocal = @()
    $resourceIdToGroupNodeIdLocal = @{}

    foreach ($g in $localGroups) {
        $groupCounterLocal++

        $items = @($g.Group)
        if ($items.Count -eq 0) { continue }

        $sample = $items[0]
        $resourceType = [string]$sample.type

        $groupNodeId = "group:$groupCounterLocal"

        foreach ($it in $items) {
            if ($null -eq $it) { continue }
            $rid = [string](Get-OptionalPropertyValue -Obj $it -Name 'id')
            if ([string]::IsNullOrWhiteSpace($rid)) { continue }
            $resourceIdToGroupNodeIdLocal[$rid.ToLowerInvariant()] = $groupNodeId
        }

        $subnetIds = @(
            (Normalize-IdList $sample.topology_subnetIds)
        ) | Sort-Object -Unique

        # Derive parent VNets from subnet ids (some subnet-attached resources don't have topology_vnetIds)
        $derivedVnetIdsFromSubnets = @()
        foreach ($subnetId in $subnetIds) {
            $m = [regex]::Match($subnetId, '(?i)(.*/providers/Microsoft\.Network/virtualNetworks/[^/]+)')
            if ($m.Success) {
                $derivedVnetIdsFromSubnets += $m.Groups[1].Value
            }
        }

        $vnetIds = @()
        $vnetIds += @(Normalize-IdList $sample.topology_vnetIds)
        $vnetIds += @($derivedVnetIdsFromSubnets)
        $vnetIds = @($vnetIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

        $privateLinkTargetIds = @(Normalize-IdList $sample.topology_privateLinkTargetIds)

        # Internet connectivity signals (offline)
        $publicIpIds = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $sample -Name 'topology_publicIpIds'))
        $publicIps = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $sample -Name 'topology_publicIpAddresses'))
        $publicFqdns = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $sample -Name 'topology_publicFqdns'))

        $publicNetworkAccessRaw = [string](Get-OptionalPropertyValue -Obj $sample -Name 'topology_publicNetworkAccess')
        $publicNetworkAccessNorm = [string]::IsNullOrWhiteSpace($publicNetworkAccessRaw) ? $null : $publicNetworkAccessRaw.Trim().ToLowerInvariant()

        $privateEndpointIds = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $sample -Name 'topology_privateEndpointIds'))
        $privateEndpointSubnetIds = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $sample -Name 'topology_privateEndpointSubnetIds'))
        $privateEndpointVnetIds = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $sample -Name 'topology_privateEndpointVnetIds'))

        $hasPublicIpOrFqdn = (($publicIpIds.Count + $publicIps.Count + $publicFqdns.Count) -gt 0)

        $publicNetworkAccessEnabled = $false
        $publicNetworkAccessDisabled = $false
        if ($publicNetworkAccessNorm) {
            if ($publicNetworkAccessNorm -in @('enabled', 'true', 'yes')) { $publicNetworkAccessEnabled = $true }
            if ($publicNetworkAccessNorm -in @('disabled', 'false', 'no')) { $publicNetworkAccessDisabled = $true }
        }

        $internetConnected = $false
        if (-not $publicNetworkAccessDisabled) {
            $internetConnected = ($hasPublicIpOrFqdn -or $publicNetworkAccessEnabled)
        }

        $groupSummariesLocal += [pscustomobject]@{
            groupId         = $groupNodeId
            resourceType    = $resourceType
            count           = $items.Count
            sampleName      = $sample.name
            sampleResourceId= $sample.id
            vnetIds         = $vnetIds
            subnetIds       = $subnetIds
            subnetPrefixPairs = (Get-OptionalPropertyValue -Obj $sample -Name 'topology_subnetPrefixPairs')
            privateLinkTargetIds = $privateLinkTargetIds
            publicIpIds     = $publicIpIds
            publicIps       = $publicIps
            publicFqdns     = $publicFqdns
            publicNetworkAccess = $publicNetworkAccessRaw
            privateEndpointIds = $privateEndpointIds
            privateEndpointSubnetIds = $privateEndpointSubnetIds
            privateEndpointVnetIds = $privateEndpointVnetIds
            internetConnected = $internetConnected
        }
    }

    return @{
        groupSummaries          = @($groupSummariesLocal)
        resourceIdToGroupNodeId = $resourceIdToGroupNodeIdLocal
    }
}

function Get-HighLevelMermaidDiagramLines {
    param(
        [Parameter(Mandatory = $true)][object[]]$InventorySubset,
        [Parameter(Mandatory = $true)][object[]]$GroupSummaries,
        [Parameter(Mandatory = $true)][hashtable]$ResourceIdToGroupNodeId,
        [Parameter(Mandatory = $true)][string]$DiagramTitle
    )

    $Lines = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($DiagramTitle)) {
        $Lines.Add("### $DiagramTitle") | Out-Null
        $Lines.Add("") | Out-Null
    }
    $Lines.Add('```mermaid') | Out-Null
    $Lines.Add('flowchart LR') | Out-Null

    function Should-ExcludeGroupFromDiagram {
        param([Parameter(Mandatory = $true)][object]$GroupSummary)

        $rt = [string]$GroupSummary.resourceType
        if ([string]::IsNullOrWhiteSpace($rt)) { return $false }
        $rtNorm = $rt.Trim().ToLowerInvariant()

        # Network interfaces are an implementation detail for VM connectivity; emitting
        # them in the Mermaid diagram creates redundant nodes/edges.
        if ($rtNorm -eq 'microsoft.network/networkinterfaces') { return $true }

        return $false
    }

    $networkResourceTypeAllowlist = @(
        'microsoft.network/bastionhosts'
    )

    $groupsWithVnet = @(
        $GroupSummaries |
        Where-Object {
            (Should-ExcludeGroupFromDiagram -GroupSummary $_) -eq $false -and
            @($_.vnetIds).Count -gt 0 -and (
                ($_.resourceType -notmatch '(?i)^microsoft\.network/') -or
                ($networkResourceTypeAllowlist -contains ([string]$_.resourceType).ToLowerInvariant())
            )
        }
    )

    $allVnetIds = @()
    foreach ($gs2 in $groupsWithVnet) { $allVnetIds += @($gs2.vnetIds) }
    $allVnetIds = @($allVnetIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    # Best-effort map: VNet -> Private Endpoint names (only from the subset inventory)
    $peNamesByVnetId = @{}
    foreach ($r in @($InventorySubset)) {
        if ($null -eq $r) { continue }
        if ([string]$r.type -ine 'microsoft.network/privateendpoints') { continue }

        $peName = [string](Get-OptionalPropertyValue -Obj $r -Name 'name')
        if ([string]::IsNullOrWhiteSpace($peName)) { continue }

        $vnetIdsForPe = @(
            (Normalize-IdList (Get-OptionalPropertyValue -Obj $r -Name 'topology_privateEndpointVnetIds')) +
            (Normalize-IdList (Get-OptionalPropertyValue -Obj $r -Name 'topology_vnetIds'))
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique

        foreach ($vid in $vnetIdsForPe) {
            if (-not $peNamesByVnetId.ContainsKey($vid)) {
                $peNamesByVnetId[$vid] = New-Object System.Collections.Generic.List[string]
            }
            $peNamesByVnetId[$vid].Add($peName)
        }
    }

    $mIdVnet = @{}
    $mIdGroup = @{}
    $mIdPrivateLinkHub = @{}
    $vnetCounter = 0
    $grpCounter = 0
    $plHubCounter = 0
    $emittedGroupNodes = @{}

    function Get-MermaidId {
        param(
            [Parameter(Mandatory = $true)][hashtable]$Map,
            [Parameter(Mandatory = $true)][string]$Key,
            [Parameter(Mandatory = $true)][string]$Prefix,
            [Parameter(Mandatory = $true)][ref]$CounterRef
        )
        if ($Map.ContainsKey($Key)) { return $Map[$Key] }
        $CounterRef.Value++
        $id = "{0}{1}" -f $Prefix, $CounterRef.Value
        $Map[$Key] = $id
        return $id
    }

    foreach ($vnetId in $allVnetIds) {
        $mid = Get-MermaidId -Map $mIdVnet -Key $vnetId -Prefix 'vnet_' -CounterRef ([ref]$vnetCounter)
        $vnetName = Get-DisplayNameFromId $vnetId
        $label = ConvertTo-MermaidSafeLabel ("{0}<br/>Virtual Network" -f $vnetName)
        $Lines.Add(('  {0}["{1}"]' -f $mid, $label)) | Out-Null
    }

    function Get-GroupMermaidLabel {
        param([Parameter(Mandatory = $true)][object]$GroupSummary)

        if ([int]$GroupSummary.count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$GroupSummary.sampleName)) {
            return ("{0}<br/>{1}" -f $GroupSummary.sampleName, $GroupSummary.resourceType)
        }
        return ("{0}<br/>(x{1})" -f $GroupSummary.resourceType, [int]$GroupSummary.count)
    }

    foreach ($gs2 in $groupsWithVnet) {
        $gid = Get-MermaidId -Map $mIdGroup -Key $gs2.groupId -Prefix 'grp_' -CounterRef ([ref]$grpCounter)
        $gLabel = ConvertTo-MermaidSafeLabel (Get-GroupMermaidLabel -GroupSummary $gs2)
        $Lines.Add(('  {0}["{1}"]' -f $gid, $gLabel)) | Out-Null
        $emittedGroupNodes[$gs2.groupId] = $true

        $subnetsByVnetId = @{}
        $subnetPrefixMap = Convert-SubnetPrefixPairsToMap $gs2.subnetPrefixPairs

        foreach ($subnetId in @($gs2.subnetIds)) {
            if ([string]::IsNullOrWhiteSpace($subnetId)) { continue }
            $sidLower = ([string]$subnetId).ToLowerInvariant()

            $parentVnetId = $null
            $m2 = [regex]::Match([string]$subnetId, '(?i)(.*/providers/Microsoft\.Network/virtualNetworks/[^/]+)')
            if ($m2.Success) { $parentVnetId = $m2.Groups[1].Value }
            if ([string]::IsNullOrWhiteSpace($parentVnetId)) { continue }

            $subnetName = Get-DisplayNameFromId $subnetId
            $prefix = $null
            if ($subnetPrefixMap.ContainsKey($sidLower)) { $prefix = [string]$subnetPrefixMap[$sidLower] }
            $text = [string]::IsNullOrWhiteSpace($prefix) ? $subnetName : ("{0} {1}" -f $subnetName, $prefix)

            if (-not $subnetsByVnetId.ContainsKey($parentVnetId)) {
                $subnetsByVnetId[$parentVnetId] = New-Object System.Collections.Generic.List[string]
            }
            $subnetsByVnetId[$parentVnetId].Add($text)
        }

        foreach ($vnetId in @($gs2.vnetIds | Sort-Object -Unique)) {
            if ([string]::IsNullOrWhiteSpace($vnetId)) { continue }

            $mid = $mIdVnet[$vnetId]
            if (-not $mid) {
                $mid = Get-MermaidId -Map $mIdVnet -Key $vnetId -Prefix 'vnet_' -CounterRef ([ref]$vnetCounter)
                $vnetName = Get-DisplayNameFromId $vnetId
                $label = ConvertTo-MermaidSafeLabel ("{0}<br/>Virtual Network" -f $vnetName)
                $Lines.Add(('  {0}["{1}"]' -f $mid, $label)) | Out-Null
            }

            $edgeLabel = $null
            if ($subnetsByVnetId.ContainsKey($vnetId)) {
                $items = @($subnetsByVnetId[$vnetId] | Sort-Object -Unique)
                if ($items.Count -gt 0) {
                    $edgeLabel = ConvertTo-MermaidSafeLabel ($items -join '<br/>')
                }
            }

            if ([string]::IsNullOrWhiteSpace($edgeLabel)) {
                $Lines.Add("  $gid --> $mid") | Out-Null
            }
            else {
                $Lines.Add("  $gid -->|$edgeLabel| $mid") | Out-Null
            }
        }
    }

    $privateLinkGroups = @(
        $GroupSummaries |
        Where-Object {
            (Should-ExcludeGroupFromDiagram -GroupSummary $_) -eq $false -and
            @($_.privateLinkTargetIds).Count -gt 0
        }
    )

    foreach ($plg in $privateLinkGroups) {
        $subnetsByVnetId = @{}
        $subnetPrefixMap = Convert-SubnetPrefixPairsToMap $plg.subnetPrefixPairs

        foreach ($subnetId in @($plg.subnetIds)) {
            if ([string]::IsNullOrWhiteSpace($subnetId)) { continue }
            $sidLower = ([string]$subnetId).ToLowerInvariant()

            $parentVnetId = $null
            $m2 = [regex]::Match([string]$subnetId, '(?i)(.*/providers/Microsoft\.Network/virtualNetworks/[^/]+)')
            if ($m2.Success) { $parentVnetId = $m2.Groups[1].Value }
            if ([string]::IsNullOrWhiteSpace($parentVnetId)) { continue }

            $subnetName = Get-DisplayNameFromId $subnetId
            $prefix = $null
            if ($subnetPrefixMap.ContainsKey($sidLower)) { $prefix = [string]$subnetPrefixMap[$sidLower] }
            $text = [string]::IsNullOrWhiteSpace($prefix) ? $subnetName : ("{0} {1}" -f $subnetName, $prefix)

            if (-not $subnetsByVnetId.ContainsKey($parentVnetId)) {
                $subnetsByVnetId[$parentVnetId] = New-Object System.Collections.Generic.List[string]
            }
            $subnetsByVnetId[$parentVnetId].Add($text)
        }

        foreach ($vnetId in @($plg.vnetIds | Sort-Object -Unique)) {
            if ([string]::IsNullOrWhiteSpace($vnetId)) { continue }

            $vnetMid = $mIdVnet[$vnetId]
            if (-not $vnetMid) {
                $vnetMid = Get-MermaidId -Map $mIdVnet -Key $vnetId -Prefix 'vnet_' -CounterRef ([ref]$vnetCounter)
                $vnetName = Get-DisplayNameFromId $vnetId
                $vLabel = ConvertTo-MermaidSafeLabel ("{0}<br/>Virtual Network" -f $vnetName)
                $Lines.Add(('  {0}["{1}"]' -f $vnetMid, $vLabel)) | Out-Null
            }

            $subnetLabel = $null
            if ($subnetsByVnetId.ContainsKey($vnetId)) {
                $items = @($subnetsByVnetId[$vnetId] | Sort-Object -Unique)
                if ($items.Count -gt 0) { $subnetLabel = ($items -join '<br/>') }
            }

            $hubMid = $mIdPrivateLinkHub[$vnetId]
            if (-not $hubMid) {
                $hubMid = Get-MermaidId -Map $mIdPrivateLinkHub -Key $vnetId -Prefix 'plhub_' -CounterRef ([ref]$plHubCounter)

                $hubNameLines = @()
                if ($peNamesByVnetId.ContainsKey($vnetId)) {
                    $hubNameLines = @($peNamesByVnetId[$vnetId] | Sort-Object -Unique)
                }

                $hubTypeLabel = 'Private Endpoint'
                $hubLabel = $null
                if ($hubNameLines.Count -eq 1) {
                    $hubLabel = "fa:fa-lock $($hubNameLines[0])<br/>$hubTypeLabel"
                }
                elseif ($hubNameLines.Count -gt 1) {
                    $hubLabel = "fa:fa-lock $hubTypeLabel"
                }
                else {
                    $hubLabel = "fa:fa-lock $hubTypeLabel"
                }

                $hubLabel = ConvertTo-MermaidSafeLabel $hubLabel
                $Lines.Add(('  {0}["{1}"]' -f $hubMid, $hubLabel)) | Out-Null
            }

            if ([string]::IsNullOrWhiteSpace($subnetLabel)) {
                $Lines.Add("  $vnetMid --> $hubMid") | Out-Null
            }
            else {
                $vToHubLabel = ConvertTo-MermaidSafeLabel $subnetLabel
                $Lines.Add("  $vnetMid -->|$vToHubLabel| $hubMid") | Out-Null
            }

            foreach ($t in @($plg.privateLinkTargetIds | Sort-Object -Unique)) {
                if ([string]::IsNullOrWhiteSpace($t)) { continue }

                $targetGroupNodeId = $null
                $tLower = ([string]$t).ToLowerInvariant()
                if ($ResourceIdToGroupNodeId.ContainsKey($tLower)) {
                    $targetGroupNodeId = [string]$ResourceIdToGroupNodeId[$tLower]
                }

                if (-not [string]::IsNullOrWhiteSpace($targetGroupNodeId)) {
                    $targetGs = $GroupSummaries | Where-Object { $_.groupId -eq $targetGroupNodeId } | Select-Object -First 1
                    if ($null -ne $targetGs) {
                        $targetMid = Get-MermaidId -Map $mIdGroup -Key $targetGs.groupId -Prefix 'grp_' -CounterRef ([ref]$grpCounter)
                        if (-not $emittedGroupNodes.ContainsKey($targetGs.groupId)) {
                            $tgLabel = ConvertTo-MermaidSafeLabel (Get-GroupMermaidLabel -GroupSummary $targetGs)
                            $Lines.Add(('  {0}["{1}"]' -f $targetMid, $tgLabel)) | Out-Null
                            $emittedGroupNodes[$targetGs.groupId] = $true
                        }

                        $edgeLabel = ConvertTo-MermaidSafeLabel 'PrivateLink'
                        $Lines.Add("  $hubMid -.->|$edgeLabel| $targetMid") | Out-Null
                        continue
                    }
                }

                $tMid = 'pl_' + ([Math]::Abs($tLower.GetHashCode()))
                $tName = Get-DisplayNameFromId $t
                $tType = Get-ResourceTypeFromId $t
                $tLabelRaw = [string]::IsNullOrWhiteSpace($tType) ? $tName : ("{0}<br/>{1}" -f $tName, $tType)
                $tLabel = ConvertTo-MermaidSafeLabel $tLabelRaw
                $Lines.Add(('  {0}["{1}"]' -f $tMid, $tLabel)) | Out-Null
                $edgeLabel = ConvertTo-MermaidSafeLabel 'PrivateLink'
                $Lines.Add("  $hubMid -.->|$edgeLabel| $tMid") | Out-Null
            }
        }
    }

    # VNet peering edges (best-effort, within subset inventory)
    $peeringPairs = @{}
    foreach ($r in $InventorySubset) {
        if ($null -eq $r -or [string]::IsNullOrWhiteSpace([string]$r.id)) { continue }
        if ([string]$r.type -ine 'microsoft.network/virtualnetworks') { continue }
        $localVnetId = [string]$r.id
        $remoteVnetIds = Normalize-IdList (Get-OptionalPropertyValue -Obj $r -Name 'topology_vnetPeeringRemoteVnetIds')
        foreach ($remote in $remoteVnetIds) {
            if ([string]::IsNullOrWhiteSpace($remote)) { continue }
            $a = $localVnetId.ToLowerInvariant()
            $b = ([string]$remote).ToLowerInvariant()
            $k = ($a -lt $b) ? ("$a|$b") : ("$b|$a")
            $peeringPairs[$k] = @($localVnetId, [string]$remote)
        }
    }

    foreach ($pair in $peeringPairs.Values) {
        $left = [string]$pair[0]
        $right = [string]$pair[1]

        $lmid = $mIdVnet[$left]
        if (-not $lmid) {
            $lmid = Get-MermaidId -Map $mIdVnet -Key $left -Prefix 'vnet_' -CounterRef ([ref]$vnetCounter)
            $vnetName = Get-DisplayNameFromId $left
            $label = ConvertTo-MermaidSafeLabel ("{0}<br/>Virtual Network" -f $vnetName)
            $Lines.Add(('  {0}["{1}"]' -f $lmid, $label)) | Out-Null
        }

        $rmid = $mIdVnet[$right]
        if (-not $rmid) {
            $rmid = Get-MermaidId -Map $mIdVnet -Key $right -Prefix 'vnet_' -CounterRef ([ref]$vnetCounter)
            $vnetName = Get-DisplayNameFromId $right
            $label = ConvertTo-MermaidSafeLabel ("{0}<br/>Virtual Network" -f $vnetName)
            $Lines.Add(('  {0}["{1}"]' -f $rmid, $label)) | Out-Null
        }

        if ($lmid -ne $rmid) {
            $Lines.Add("  $lmid ---|peering| $rmid") | Out-Null
        }
    }

    $groupsWithInternet = @(
        $GroupSummaries |
        Where-Object {
            (Should-ExcludeGroupFromDiagram -GroupSummary $_) -eq $false -and
            $_.internetConnected -eq $true -and (
                ($_.resourceType -notmatch '(?i)^microsoft\\.network/') -or
                ($networkResourceTypeAllowlist -contains ([string]$_.resourceType).ToLowerInvariant())
            )
        }
    )

    if ($groupsWithInternet.Count -gt 0) {
        $internetMid = 'internet_public'
        $internetLabel = ConvertTo-MermaidSafeLabel 'Public Internet'
        $Lines.Add(('  {0}["{1}"]' -f $internetMid, $internetLabel)) | Out-Null

        foreach ($gsInternet in $groupsWithInternet) {
            $gid = Get-MermaidId -Map $mIdGroup -Key $gsInternet.groupId -Prefix 'grp_' -CounterRef ([ref]$grpCounter)
            if (-not $emittedGroupNodes.ContainsKey($gsInternet.groupId)) {
                $gLabel = ConvertTo-MermaidSafeLabel (Get-GroupMermaidLabel -GroupSummary $gsInternet)
                $Lines.Add(('  {0}["{1}"]' -f $gid, $gLabel)) | Out-Null
                $emittedGroupNodes[$gsInternet.groupId] = $true
            }

            # Prefer showing actual public IP(s) on the edge when this is a single resource.
            # Falls back to a generic label when we don't have offline public IP data.
            $edgeLabelRaw = 'Internet'
            if ([int]$gsInternet.count -eq 1) {
                $pubIpsArr = @(@($gsInternet.publicIps) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
                $pubIpsCount = $pubIpsArr.Length
                if ($pubIpsCount -gt 0) {
                    if ($pubIpsCount -eq 1) {
                        $edgeLabelRaw = [string]$pubIpsArr[0]
                    }
                    else {
                        $edgeLabelRaw = ("{0}<br/>..." -f [string]$pubIpsArr[0])
                    }
                }
            }

            $edgeLabel = ConvertTo-MermaidSafeLabel $edgeLabelRaw
            $Lines.Add("  $gid -->|$edgeLabel| $internetMid") | Out-Null
        }
    }

    $Lines.Add('```') | Out-Null
    $Lines.Add('') | Out-Null

    # If we only emitted an empty diagram (no nodes/edges beyond flowchart), suppress it.
    # Mermaid diagram skeleton is always:
    #   ```mermaid
    #   flowchart LR
    #   ```
    $hasAnyGraphItems = @(
        $Lines |
        Where-Object {
            $_ -match '^\s{2,}\S' -and
            $_ -notmatch '^\s*flowchart\s'
        }
    ).Count -gt 0

    if (-not $hasAnyGraphItems) {
        return @()
    }

    return @($Lines)
}

# Allow dot-sourcing for unit testing and reuse of helper functions.
# When dot-sourced, we only define functions and skip script execution.
if ($MyInvocation.InvocationName -ne '.') {
    $sourceLabel = $null

    if (-not (Test-Path -LiteralPath $InputPath)) {
        throw "Input not found: $InputPath"
    }

    $sourceLabel = $InputPath
    $ext = [System.IO.Path]::GetExtension($InputPath)
    if ($null -eq $ext) { $ext = '' }
    $ext = $ext.ToLowerInvariant()

    if ($ext -in @('.xlsx', '.xlsm')) {
        $inventory = Convert-WorkloadInventoryExcelToResourceInventory -Path $InputPath -StartRow $ExcelStartRow
        $data = [pscustomobject]@{ resourceInventory = $inventory }
    }
    else {
        $raw = Get-Content -LiteralPath $InputPath -Raw
        $data = $raw | ConvertFrom-Json

        if ($null -eq $data.resourceInventory) {
            throw "Input JSON does not contain resourceInventory. File: $InputPath"
        }

        $inventory = @($data.resourceInventory)
    }

# Group by: resource type + connected network key
$groups = $inventory | Group-Object -Property @{ Expression = { "{0}|{1}" -f $_.type, (Get-NetworkKey $_) } }

$nodes = New-Object System.Collections.Generic.List[object]
$edges = New-Object System.Collections.Generic.List[object]

# Add helper tables to avoid duplicates
$nodeIndex = @{}
$edgeIndex = @{}

function Add-Node {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [hashtable]$Props
    )

    if ($nodeIndex.ContainsKey($Id)) { return }

    $obj = [ordered]@{
        id    = $Id
        kind  = $Kind
        label = $Label
    }

    if ($Props) {
        foreach ($k in $Props.Keys) { $obj[$k] = $Props[$k] }
    }

    $nodeIndex[$Id] = $true
    $nodes.Add([pscustomobject]$obj) | Out-Null
}

function Add-Edge {
    param(
        [Parameter(Mandatory = $true)]
        [string]$From,
        [Parameter(Mandatory = $true)]
        [string]$To,
        [Parameter(Mandatory = $true)]
        [string]$Relation
    )

    $key = "$From|$To|$Relation"
    if ($edgeIndex.ContainsKey($key)) { return }

    $edgeIndex[$key] = $true
    $edges.Add([pscustomobject]([ordered]@{
        from     = $From
        to       = $To
        relation = $Relation
    })) | Out-Null
}

# Build network nodes and group nodes
$groupCounter = 0
$groupSummaries = New-Object System.Collections.Generic.List[object]
$resourceIdToGroupNodeId = @{}

foreach ($g in $groups) {
    $groupCounter++

    $items = @($g.Group)
    if ($items.Count -eq 0) { continue }

    $sample = $items[0]
    $resourceType = [string]$sample.type
    $networkKey = Get-NetworkKey $sample

    $groupNodeId = "group:$groupCounter"
    $groupLabel = "{0} (x{1})" -f $resourceType, $items.Count

    Add-Node -Id $groupNodeId -Kind 'resourceGroup' -Label $groupLabel -Props @{
        resourceType     = $resourceType
        count            = $items.Count
        networkKey       = $networkKey
        sampleResourceId = $sample.id
        sampleName       = $sample.name
        sampleRg         = $sample.resourceGroup
        sampleLocation   = $sample.location
    }

    # Index every resource id -> group node id so Mermaid can reuse group nodes
    # for Private Link targets (avoids drawing the same resource twice as grp_* and pl_*).
    foreach ($it in $items) {
        if ($null -eq $it) { continue }
        $rid = [string](Get-OptionalPropertyValue -Obj $it -Name 'id')
        if ([string]::IsNullOrWhiteSpace($rid)) { continue }
        $resourceIdToGroupNodeId[$rid.ToLowerInvariant()] = $groupNodeId
    }

    $subnetIds = @(
        (Normalize-IdList $sample.topology_subnetIds)
    ) | Sort-Object -Unique

    # Some resources (e.g., BastionHosts/NAT gateways) are subnet-attached and may not have
    # topology_vnetIds populated. Derive parent VNets from subnet ARM ids so the high-level
    # Mermaid can still show group -> VNet connectivity offline.
    $derivedVnetIdsFromSubnets = @()
    foreach ($subnetId in $subnetIds) {
        $m = [regex]::Match($subnetId, '(?i)(.*/providers/Microsoft\.Network/virtualNetworks/[^/]+)')
        if ($m.Success) {
            $derivedVnetIdsFromSubnets += $m.Groups[1].Value
        }
    }

    # Build a stable list of VNet IDs. Avoid accidental string concatenation when both sources
    # happen to be single-valued.
    $vnetIds = @()
    $vnetIds += @(Normalize-IdList $sample.topology_vnetIds)
    $vnetIds += @($derivedVnetIdsFromSubnets)
    $vnetIds = @($vnetIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    $privateLinkTargetIds = @(Normalize-IdList $sample.topology_privateLinkTargetIds)

    foreach ($vnetId in $vnetIds) {
        $vnetNodeId = "vnet:$vnetId"
        Add-Node -Id $vnetNodeId -Kind 'vnet' -Label (Get-DisplayNameFromId $vnetId) -Props @{
            resourceId = $vnetId
        }
        Add-Edge -From $groupNodeId -To $vnetNodeId -Relation 'connected_to_vnet'
    }

    foreach ($subnetId in $subnetIds) {
        $subnetNodeId = "subnet:$subnetId"
        Add-Node -Id $subnetNodeId -Kind 'subnet' -Label (Get-DisplayNameFromId $subnetId) -Props @{
            resourceId = $subnetId
        }
        Add-Edge -From $groupNodeId -To $subnetNodeId -Relation 'connected_to_subnet'

        # Also link subnet -> vnet when possible (subnet ARM id embeds vnet path)
        # /.../virtualNetworks/<vnetName>/subnets/<subnetName>
        $m = [regex]::Match($subnetId, '(?i)(.*/providers/Microsoft\.Network/virtualNetworks/[^/]+)')
        if ($m.Success) {
            $parentVnetId = $m.Groups[1].Value
            $parentVnetNodeId = "vnet:$parentVnetId"
            Add-Node -Id $parentVnetNodeId -Kind 'vnet' -Label (Get-DisplayNameFromId $parentVnetId) -Props @{
                resourceId = $parentVnetId
            }
            Add-Edge -From $subnetNodeId -To $parentVnetNodeId -Relation 'subnet_of'
        }
    }

    foreach ($t in $privateLinkTargetIds) {
        $targetNodeId = "pltarget:$t"
        Add-Node -Id $targetNodeId -Kind 'privateLinkTarget' -Label (Get-DisplayNameFromId $t) -Props @{
            resourceId   = $t
            resourceType = (Get-ResourceTypeFromId $t)
        }
        Add-Edge -From $groupNodeId -To $targetNodeId -Relation 'private_endpoint_to'
    }

    # Optional: public Internet connectivity (offline)
    # Signals (offline-only):
    # 1) Public IP / Public FQDNs captured during collect/enrich
    # 2) topology_publicNetworkAccess explicitly enabled
    # 3) topology_publicNetworkAccess explicitly disabled
    $publicIpIds = @(Normalize-IdList $sample.topology_publicIpIds)
    $publicIps = @(Normalize-IdList $sample.topology_publicIpAddresses)
    $publicFqdns = @(Normalize-IdList $sample.topology_publicFqdns)

    $publicNetworkAccessRaw = [string](Get-OptionalPropertyValue -Obj $sample -Name 'topology_publicNetworkAccess')
    $publicNetworkAccessNorm = [string]::IsNullOrWhiteSpace($publicNetworkAccessRaw) ? $null : $publicNetworkAccessRaw.Trim().ToLowerInvariant()

    $privateEndpointIds = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $sample -Name 'topology_privateEndpointIds'))
    $privateEndpointSubnetIds = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $sample -Name 'topology_privateEndpointSubnetIds'))
    $privateEndpointVnetIds = @(Normalize-IdList (Get-OptionalPropertyValue -Obj $sample -Name 'topology_privateEndpointVnetIds'))

    $hasPublicIpOrFqdn = (($publicIpIds.Count + $publicIps.Count + $publicFqdns.Count) -gt 0)

    $publicNetworkAccessEnabled = $false
    $publicNetworkAccessDisabled = $false
    if ($publicNetworkAccessNorm) {
        if ($publicNetworkAccessNorm -in @('enabled', 'true', 'yes')) { $publicNetworkAccessEnabled = $true }
        if ($publicNetworkAccessNorm -in @('disabled', 'false', 'no')) { $publicNetworkAccessDisabled = $true }
    }

    $internetConnected = $false
    if (-not $publicNetworkAccessDisabled) {
        $internetConnected = ($hasPublicIpOrFqdn -or $publicNetworkAccessEnabled)
    }

    if ($internetConnected) {
        Add-Node -Id 'internet:public' -Kind 'internet' -Label 'Public Internet' -Props $null
        Add-Edge -From $groupNodeId -To 'internet:public' -Relation 'publicly_exposed'
    }

    $groupSummaries.Add([pscustomobject]([ordered]@{
        groupId         = $groupNodeId
        resourceType    = $resourceType
        count           = $items.Count
        sampleName      = $sample.name
        sampleResourceId= $sample.id
        vnetIds         = $vnetIds
        subnetIds       = $subnetIds
        subnetPrefixPairs = (Get-OptionalPropertyValue -Obj $sample -Name 'topology_subnetPrefixPairs')
        privateLinkTargetIds = $privateLinkTargetIds
        publicIpIds     = $publicIpIds
        publicIps       = $publicIps
        publicFqdns     = $publicFqdns
        publicNetworkAccess = $publicNetworkAccessRaw
        privateEndpointIds = $privateEndpointIds
        privateEndpointSubnetIds = $privateEndpointSubnetIds
        privateEndpointVnetIds = $privateEndpointVnetIds
        internetConnected = $internetConnected
    })) | Out-Null
}

$model = [pscustomobject]([ordered]@{
    sourceFile = $sourceLabel
    generatedAt = (Get-Date).ToString('s')
    nodeCount = $nodes.Count
    edgeCount = $edges.Count
    nodes = $nodes
    edges = $edges
    groups = $groupSummaries
})

if ($OutputJson) {
    $dir = Split-Path -Parent $OutputJson
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $model | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
}

if ($OutputMd) {
    $dir2 = Split-Path -Parent $OutputMd
    if ($dir2 -and -not (Test-Path -LiteralPath $dir2)) {
        New-Item -ItemType Directory -Path $dir2 -Force | Out-Null
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# WARA Network Topology (Deduped)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Source: $sourceLabel") | Out-Null
    $lines.Add("- Generated: $((Get-Date).ToString('s'))") | Out-Null
    $lines.Add("- Groups: $($groups.Count)") | Out-Null
    $lines.Add("- Nodes: $($nodes.Count)") | Out-Null
    $lines.Add("- Edges: $($edges.Count)") | Out-Null
    $lines.Add("") | Out-Null

    if ($MermaidByResourceGroup) {
        $lines.Add('## Mermaid Topology Diagram (By Resource Group)') | Out-Null
        $lines.Add('') | Out-Null

        $rgKeyByName = @{}
        foreach ($r in @($inventory)) {
            if ($null -eq $r) { continue }
            $rg = [string](Get-OptionalPropertyValue -Obj $r -Name 'resourceGroup')
            $key = [string]::IsNullOrWhiteSpace($rg) ? '(no resourceGroup)' : $rg
            $rgKeyByName[$key] = $true
        }

        $rgNames = @($rgKeyByName.Keys | Sort-Object)
        foreach ($rgName in $rgNames) {
            $subset = @(
                $inventory |
                Where-Object {
                    $rg = [string](Get-OptionalPropertyValue -Obj $_ -Name 'resourceGroup')
                    $key = [string]::IsNullOrWhiteSpace($rg) ? '(no resourceGroup)' : $rg
                    $key -eq $rgName
                }
            )

            $local = Get-GroupSummariesFromInventory -InventorySubset $subset
            $localGroupSummaries = @($local['groupSummaries'])
            $localResourceIdToGroupNodeId = [hashtable]$local['resourceIdToGroupNodeId']
            $diagramLines = Get-HighLevelMermaidDiagramLines -InventorySubset $subset -GroupSummaries $localGroupSummaries -ResourceIdToGroupNodeId $localResourceIdToGroupNodeId -DiagramTitle ("Resource Group: {0}" -f $rgName)
            foreach ($dl in @($diagramLines)) { $lines.Add([string]$dl) | Out-Null }
        }
    }
    else {
        $lines.Add('## Mermaid Topology Diagram (High-level)') | Out-Null
        $lines.Add('') | Out-Null
        $diagramLines = Get-HighLevelMermaidDiagramLines -InventorySubset @($inventory) -GroupSummaries @($groupSummaries) -ResourceIdToGroupNodeId $resourceIdToGroupNodeId -DiagramTitle ''
        foreach ($dl in $diagramLines) { $lines.Add([string]$dl) | Out-Null }
    }

    foreach ($gs in $groupSummaries | Sort-Object resourceType, count -Descending) {
        $lines.Add("## $($gs.resourceType)  (x$($gs.count))") | Out-Null
        $lines.Add("") | Out-Null
        $lines.Add("- Representative: $($gs.sampleName)") | Out-Null
        $lines.Add("- SampleResourceId: $($gs.sampleResourceId)") | Out-Null

        $vnetList = @($gs.vnetIds)
        $subnetList = @($gs.subnetIds)
        $privateLinkTargetList = @($gs.privateLinkTargetIds)
        $publicIpList = @($gs.publicIps)
        $publicIpIdList = @($gs.publicIpIds)
        $publicFqdnList = @($gs.publicFqdns)

        if ($vnetList.Count -gt 0) {
            $lines.Add("- VNets:") | Out-Null
            foreach ($v in $vnetList) { $lines.Add("  - $v") | Out-Null }
        }

        if ($subnetList.Count -gt 0) {
            $lines.Add("- Subnets:") | Out-Null
            foreach ($s in $subnetList) { $lines.Add("  - $s") | Out-Null }
        }

        if ($privateLinkTargetList.Count -gt 0) {
            $lines.Add("- Private Link targets (PaaS):") | Out-Null
            foreach ($t in $privateLinkTargetList) { $lines.Add("  - $t") | Out-Null }
        }

        if (($publicIpList.Count + $publicIpIdList.Count + $publicFqdnList.Count) -gt 0) {
            $lines.Add("- Public exposure:") | Out-Null
            foreach ($p in $publicIpList) { $lines.Add("  - PublicIpAddress: $p") | Out-Null }
            foreach ($pipResourceId in $publicIpIdList) { $lines.Add("  - PublicIpResourceId: $pipResourceId") | Out-Null }
            foreach ($f in $publicFqdnList) { $lines.Add("  - PublicFqdn: $f") | Out-Null }
        }

        $lines.Add("") | Out-Null
    }

    $lines | Set-Content -LiteralPath $OutputMd -Encoding UTF8
}

# Always print a concise summary to stdout
[pscustomobject]@{
    input     = $sourceLabel
    groups    = $groups.Count
    nodes     = $nodes.Count
    edges     = $edges.Count
    outJson   = $OutputJson
    outMd     = $OutputMd
} | Format-List

}
