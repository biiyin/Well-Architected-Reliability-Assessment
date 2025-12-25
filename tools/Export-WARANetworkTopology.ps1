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

function Try-Get-AzSubnetMetadata {
    param(
        [string[]]$SubscriptionIds
    )

    $result = [ordered]@{
        subnetToPrefix = @{}
        subnetToVnet    = @{}
    }

    try {
        if (-not (Get-Command -Name Search-AzGraph -ErrorAction SilentlyContinue)) { return $result }
        if (-not (Get-Command -Name Get-AzContext -ErrorAction SilentlyContinue)) { return $result }
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $ctx) { return $result }

        $subs = @($SubscriptionIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        if ($subs.Count -eq 0) { return $result }

        $subnetQuery = @"
resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand sn = properties.subnets
| extend subnetId = tostring(sn.id)
| extend subnetPrefix = tostring(coalesce(sn.properties.addressPrefix, sn.properties.addressPrefixes[0]))
| project vnetId = id, subnetId, subnetPrefix
"@

        $rows = Search-AzGraph -Query $subnetQuery -Subscription $subs -First 1000 -ErrorAction Stop
        foreach ($row in @($rows)) {
            if ($null -eq $row) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$row.subnetId)) { continue }
            $sid = ([string]$row.subnetId).ToLowerInvariant()
            $result.subnetToVnet[$sid] = [string]$row.vnetId
            if (-not [string]::IsNullOrWhiteSpace([string]$row.subnetPrefix)) {
                $result.subnetToPrefix[$sid] = [string]$row.subnetPrefix
            }
        }
    }
    catch {
        # Diagram generation should remain best-effort; don't fail the exporter.
        return $result
    }

    return $result
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

    # ------------------------------
    # High-level Mermaid topology
    # Only show: resource-group (deduped) -> VNet, subnet prefixes (if resolvable), and VNet peerings.
    # ------------------------------
    $lines.Add("## Mermaid Topology Diagram (High-level)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add('```mermaid') | Out-Null
    $lines.Add("flowchart LR") | Out-Null

    # Keep the Mermaid diagram high-level: show workload resources -> VNet.
    # Exclude Microsoft.Network/* resource groups (NICs, PEs, etc.) to reduce noise.
    $groupsWithVnet = @(
        $groupSummaries |
        Where-Object { @($_.vnetIds).Count -gt 0 -and ($_.resourceType -notmatch '(?i)^microsoft\.network/') }
    )
    $allVnetIds = @()
    foreach ($gs2 in $groupsWithVnet) { $allVnetIds += @($gs2.vnetIds) }
    $allVnetIds = @($allVnetIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    # Collect subscription IDs from known resource IDs (best-effort)
    $subsForLookup = @()
    foreach ($vid in $allVnetIds) { $subsForLookup += (Get-SubscriptionIdFromArmId $vid) }
    # Include subnet IDs from all groups so we can annotate Private Endpoint subnet prefixes too.
    foreach ($gs2 in $groupSummaries) { foreach ($sid2 in @($gs2.subnetIds)) { $subsForLookup += (Get-SubscriptionIdFromArmId $sid2) } }
    $subsForLookup = @($subsForLookup | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    $subnetMeta = Try-Get-AzSubnetMetadata -SubscriptionIds $subsForLookup
    $subnetToPrefix = $subnetMeta.subnetToPrefix
    $subnetToVnet = $subnetMeta.subnetToVnet

    # Build a best-effort map of VNet -> Private Endpoint names so the diagram can show the
    # actual Private Link connection name(s) instead of a generic label.
    $peNamesByVnetId = @{}
    foreach ($r in @($inventory)) {
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

    # Mermaid IDs
    $mIdVnet = @{}
    $mIdSubnet = @{}
    $mIdGroup = @{}
    $mIdPlTarget = @{}
    $mIdPrivateLinkHub = @{}
    $vnetCounter = 0
    $subnetCounter = 0
    $grpCounter = 0
    $plTargetCounter = 0
    $plHubCounter = 0

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

    # Emit VNet nodes
    foreach ($vnetId in $allVnetIds) {
        $mid = Get-MermaidId -Map $mIdVnet -Key $vnetId -Prefix 'vnet_' -CounterRef ([ref]$vnetCounter)
        $vnetName = Get-DisplayNameFromId $vnetId
        $label = ConvertTo-MermaidSafeLabel ("{0}<br/>Virtual Network" -f $vnetName)
        $lines.Add("  $mid[`"$label`"]") | Out-Null
    }

    # Emit group nodes + group->vnet edges
    foreach ($gs2 in $groupsWithVnet) {
        $gid = Get-MermaidId -Map $mIdGroup -Key $gs2.groupId -Prefix 'grp_' -CounterRef ([ref]$grpCounter)
        $gLabelRaw = $null
        if ([int]$gs2.count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$gs2.sampleName)) {
            $gLabelRaw = "{0}<br/>{1}" -f $gs2.sampleName, $gs2.resourceType
        }
        else {
            $gLabelRaw = [string]$gs2.resourceType
        }
        $gLabel = ConvertTo-MermaidSafeLabel $gLabelRaw
        $lines.Add("  $gid[`"$gLabel`"]") | Out-Null

        # Pre-compute subnet info by parent VNet so we can annotate the edge.
        $subnetsByVnetId = @{}
        foreach ($subnetId in @($gs2.subnetIds)) {
            if ([string]::IsNullOrWhiteSpace($subnetId)) { continue }
            $sidLower = ([string]$subnetId).ToLowerInvariant()

            $parentVnetId = $null
            if ($subnetToVnet.ContainsKey($sidLower)) {
                $parentVnetId = [string]$subnetToVnet[$sidLower]
            }
            else {
                $m2 = [regex]::Match([string]$subnetId, '(?i)(.*/providers/Microsoft\.Network/virtualNetworks/[^/]+)')
                if ($m2.Success) { $parentVnetId = $m2.Groups[1].Value }
            }

            if ([string]::IsNullOrWhiteSpace($parentVnetId)) { continue }

            $subnetName = Get-DisplayNameFromId $subnetId
            $prefix = $null
            if ($subnetToPrefix.ContainsKey($sidLower)) { $prefix = [string]$subnetToPrefix[$sidLower] }
            $text = $prefix ? ("{0} {1}" -f $subnetName, $prefix) : $subnetName

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
                $lines.Add("  $mid[`"$label`"]") | Out-Null
            }

            $edgeLabel = $null
            if ($subnetsByVnetId.ContainsKey($vnetId)) {
                $items = @($subnetsByVnetId[$vnetId] | Sort-Object -Unique)
                if ($items.Count -gt 0) {
                    $edgeLabel = ConvertTo-MermaidSafeLabel ($items -join '<br/>')
                }
            }

            if ([string]::IsNullOrWhiteSpace($edgeLabel)) {
                $lines.Add("  $gid --> $mid") | Out-Null
            }
            else {
                # Put subnet+prefix info on the edge (preferred by user)
                $lines.Add("  $gid -->|$edgeLabel| $mid") | Out-Null
            }
        }
    }

    # Emit Private Link relationships (best-effort)
    # We keep the diagram high-level by adding a "Private Link" hub node per VNet and routing
    # VNet -> Private Link -> PaaS target. This avoids drawing Private Endpoint resources directly.
    $privateLinkGroups = @(
        $groupSummaries |
        Where-Object { @($_.privateLinkTargetIds).Count -gt 0 }
    )

    foreach ($plg in $privateLinkGroups) {
        $subnetsByVnetId = @{}

        foreach ($subnetId in @($plg.subnetIds)) {
            if ([string]::IsNullOrWhiteSpace($subnetId)) { continue }
            $sidLower = ([string]$subnetId).ToLowerInvariant()

            $parentVnetId = $null
            if ($subnetToVnet.ContainsKey($sidLower)) {
                $parentVnetId = [string]$subnetToVnet[$sidLower]
            }
            else {
                $m2 = [regex]::Match([string]$subnetId, '(?i)(.*/providers/Microsoft\.Network/virtualNetworks/[^/]+)')
                if ($m2.Success) { $parentVnetId = $m2.Groups[1].Value }
            }

            if ([string]::IsNullOrWhiteSpace($parentVnetId)) { continue }

            $subnetName = Get-DisplayNameFromId $subnetId
            $prefix = $null
            if ($subnetToPrefix.ContainsKey($sidLower)) { $prefix = [string]$subnetToPrefix[$sidLower] }
            $text = $prefix ? ("{0} {1}" -f $subnetName, $prefix) : $subnetName

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
                $lines.Add("  $vnetMid[`"$vLabel`"]") | Out-Null
            }

            $subnetLabel = $null
            if ($subnetsByVnetId.ContainsKey($vnetId)) {
                $items = @($subnetsByVnetId[$vnetId] | Sort-Object -Unique)
                if ($items.Count -gt 0) {
                    $subnetLabel = ($items -join '<br/>')
                }
            }

            # One Private Link hub per VNet, reused across all targets.
            $hubMid = $mIdPrivateLinkHub[$vnetId]
            if (-not $hubMid) {
                $hubMid = Get-MermaidId -Map $mIdPrivateLinkHub -Key $vnetId -Prefix 'plhub_' -CounterRef ([ref]$plHubCounter)
                # Mermaid supports Font Awesome icons via fa:fa-*
                $hubNameLines = @()
                if ($peNamesByVnetId.ContainsKey($vnetId)) {
                    $hubNameLines = @($peNamesByVnetId[$vnetId] | Sort-Object -Unique)
                }

                $hubLabel = $null
                $hubTypeLabel = 'Private Endpoint'
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
                $lines.Add("  $hubMid[`"$hubLabel`"]") | Out-Null
            }

            # VNet -> Private Link edge annotated with PE subnet(s) when we can resolve them.
            if ([string]::IsNullOrWhiteSpace($subnetLabel)) {
                $lines.Add("  $vnetMid --> $hubMid") | Out-Null
            }
            else {
                $vToHubLabel = ConvertTo-MermaidSafeLabel $subnetLabel
                $lines.Add("  $vnetMid -->|$vToHubLabel| $hubMid") | Out-Null
            }

            foreach ($t in @($plg.privateLinkTargetIds | Sort-Object -Unique)) {
                if ([string]::IsNullOrWhiteSpace($t)) { continue }

                $tMid = $mIdPlTarget[$t]
                if (-not $tMid) {
                    $tMid = Get-MermaidId -Map $mIdPlTarget -Key $t -Prefix 'pl_' -CounterRef ([ref]$plTargetCounter)
                    $tName = Get-DisplayNameFromId $t
                    $tType = Get-ResourceTypeFromId $t
                    $tLabelRaw = [string]::IsNullOrWhiteSpace($tType) ? $tName : ("{0}<br/>{1}" -f $tName, $tType)
                    $tLabel = ConvertTo-MermaidSafeLabel $tLabelRaw
                    $lines.Add("  $tMid[`"$tLabel`"]") | Out-Null
                }

                # Private Link hub -> target edge. Keep dashed to visually distinguish from "in-VNet" links.
                $edgeLabel = ConvertTo-MermaidSafeLabel 'PrivateLink'
                $lines.Add("  $hubMid -.->|$edgeLabel| $tMid") | Out-Null
            }
        }
    }

    # Emit VNet peering edges (best-effort)
    $peeringPairs = @{}

    # 1) Prefer peering info already present in the JSON (after running WARA with the new enrichment)
    foreach ($r in $inventory) {
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

    # 2) If no peering info found in file, query ARG (same query as enrichment) and connect VNets seen in this diagram
    if ($peeringPairs.Count -eq 0 -and $subsForLookup.Count -gt 0) {
        try {
            if ((Get-Command -Name Search-AzGraph -ErrorAction SilentlyContinue) -and (Get-AzContext -ErrorAction SilentlyContinue)) {
                $peeringQuery = @"
resources
| where type =~ 'microsoft.network/virtualnetworks/virtualnetworkpeerings'
| extend localVnetId = tostring(extract('(.+)/virtualNetworkPeerings/[^/]+$', 1, id))
| extend remoteVnetId = tostring(properties.remoteVirtualNetwork.id)
| project localVnetId, remoteVnetId
"@
                $rows = Search-AzGraph -Query $peeringQuery -Subscription $subsForLookup -First 1000 -ErrorAction Stop
                foreach ($p in @($rows)) {
                    if ($null -eq $p) { continue }
                    if ([string]::IsNullOrWhiteSpace([string]$p.localVnetId)) { continue }
                    if ([string]::IsNullOrWhiteSpace([string]$p.remoteVnetId)) { continue }
                    $a = ([string]$p.localVnetId).ToLowerInvariant()
                    $b = ([string]$p.remoteVnetId).ToLowerInvariant()
                    $k = ($a -lt $b) ? ("$a|$b") : ("$b|$a")
                    if (-not $peeringPairs.ContainsKey($k)) {
                        $peeringPairs[$k] = @([string]$p.localVnetId, [string]$p.remoteVnetId)
                    }
                }
            }
        }
        catch {
            # ignore
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
            $lines.Add("  $lmid[`"$label`"]") | Out-Null
        }

        $rmid = $mIdVnet[$right]
        if (-not $rmid) {
            $rmid = Get-MermaidId -Map $mIdVnet -Key $right -Prefix 'vnet_' -CounterRef ([ref]$vnetCounter)
            $vnetName = Get-DisplayNameFromId $right
            $label = ConvertTo-MermaidSafeLabel ("{0}<br/>Virtual Network" -f $vnetName)
            $lines.Add("  $rmid[`"$label`"]") | Out-Null
        }

        if ($lmid -ne $rmid) {
            $lines.Add("  $lmid ---|peering| $rmid") | Out-Null
        }
    }

    $lines.Add('```') | Out-Null
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
