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

.PARAMETER InputJson
Path to a WARA output JSON file (e.g. output/WARA-File-*.json).

.PARAMETER OutputJson
Optional path to write the graph model JSON.

.PARAMETER OutputMd
Optional path to write a human-readable Markdown summary.

.EXAMPLE
pwsh -NoProfile -File .\tools\Export-WARANetworkTopology.ps1 -InputJson .\output\WARA-File-2025-12-24-20-49.json -OutputJson .\output\WARA-NetworkTopology.json -OutputMd .\output\WARA-NetworkTopology.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InputJson,

    [Parameter(Mandatory = $false)]
    [string]$OutputJson,

    [Parameter(Mandatory = $false)]
    [string]$OutputMd
)

Set-StrictMode -Version Latest

function Normalize-IdList {
    param([object]$Value)

    if ($null -eq $Value) { return @() }

    # WARA usually serializes arrays as JSON arrays, but be defensive.
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value.Trim())
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

function Join-Ids {
    param([string[]]$Ids)
    if (-not $Ids -or $Ids.Count -eq 0) { return '' }
    return ($Ids | Sort-Object -Unique) -join ';'
}

function Get-NetworkKey {
    param($r)

    $vnetIds = @(
        (Normalize-IdList $r.topology_vnetIds) +
        (Normalize-IdList $r.topology_privateEndpointVnetIds)
    ) | Sort-Object -Unique

    $subnetIds = @(
        (Normalize-IdList $r.topology_subnetIds) +
        (Normalize-IdList $r.topology_privateEndpointSubnetIds)
    ) | Sort-Object -Unique

    $v = Join-Ids $vnetIds
    $s = Join-Ids $subnetIds

    if ([string]::IsNullOrWhiteSpace($v) -and [string]::IsNullOrWhiteSpace($s)) {
        return 'no-network'
    }

    return "vnet:$v|subnet:$s"
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

if (-not (Test-Path -LiteralPath $InputJson)) {
    throw "InputJson not found: $InputJson"
}

$raw = Get-Content -LiteralPath $InputJson -Raw
$data = $raw | ConvertFrom-Json

if ($null -eq $data.resourceInventory) {
    throw "Input JSON does not contain resourceInventory. File: $InputJson"
}

$inventory = @($data.resourceInventory)

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

    $vnetIds = @(
        (Normalize-IdList $sample.topology_vnetIds) +
        (Normalize-IdList $sample.topology_privateEndpointVnetIds)
    ) | Sort-Object -Unique

    $subnetIds = @(
        (Normalize-IdList $sample.topology_subnetIds) +
        (Normalize-IdList $sample.topology_privateEndpointSubnetIds)
    ) | Sort-Object -Unique

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

    # Optional: public IP presence -> a Public Internet node, for diagram readability
    $publicIpIds = @(Normalize-IdList $sample.topology_publicIpIds)
    $publicIps = @(Normalize-IdList $sample.topology_publicIpAddresses)
    $publicFqdns = @(Normalize-IdList $sample.topology_publicFqdns)

    if (($publicIpIds.Count + $publicIps.Count + $publicFqdns.Count) -gt 0) {
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
        privateLinkTargetIds = $privateLinkTargetIds
        publicIpIds     = $publicIpIds
        publicIps       = $publicIps
        publicFqdns     = $publicFqdns
    })) | Out-Null
}

$model = [pscustomobject]([ordered]@{
    sourceFile = $InputJson
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
    $lines.Add("- Source: $InputJson") | Out-Null
    $lines.Add("- Generated: $((Get-Date).ToString('s'))") | Out-Null
    $lines.Add("- Groups: $($groups.Count)") | Out-Null
    $lines.Add("- Nodes: $($nodes.Count)") | Out-Null
    $lines.Add("- Edges: $($edges.Count)") | Out-Null
    $lines.Add("") | Out-Null

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
    input     = $InputJson
    groups    = $groups.Count
    nodes     = $nodes.Count
    edges     = $edges.Count
    outJson   = $OutputJson
    outMd     = $OutputMd
} | Format-List
