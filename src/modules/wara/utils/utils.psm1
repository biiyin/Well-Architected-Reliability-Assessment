<#
.SYNOPSIS
    Invokes an Azure Resource Graph query.

.DESCRIPTION
    The `Invoke-WAFQuery` function executes an Azure Resource Graph query and returns the results. It handles pagination and consolidates results from multiple subscriptions if provided.

.PARAMETER Query
    The Kusto query string to execute against Azure Resource Graph.

.PARAMETER SubscriptionId
    An array of subscription IDs to scope the query to.

.INPUTS
    System.String. The query string.
    System.String[]. The array of subscription IDs.

.OUTPUTS
    System.Object[]. Returns an array of query results.

.EXAMPLE
    PS> $query = "Resources | where type =~ 'Microsoft.Compute/virtualMachines'"
    PS> $results = Invoke-WAFQuery -Query $query -SubscriptionId @("59f6f1ab-6d68-4c90-b4e5-ad2d71cefc57")

    This example retrieves all virtual machines within the specified subscription.

.EXAMPLE
    PS> $results = Invoke-WAFQuery -Query $query -SubscriptionId $subscriptionIds

    This example executes the query across multiple subscriptions.

.NOTES
    Author: Kyle Poineal
    Date: [Today's Date]
#>
function Invoke-WAFQuery {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]] $SubscriptionIds,

        [Parameter(Mandatory = $false)]
        [string] $Query = @'
resources
| extend inventorySku = case(
    type =~ 'microsoft.compute/virtualmachines', pack('name', tostring(properties.hardwareProfile.vmSize)),
    isnotnull(sku), sku,
    isnotnull(properties.sku), properties.sku,
    dynamic(null)
)
| extend inventoryVersion = case(
    type =~ 'microsoft.containerservice/managedclusters', tostring(properties.currentKubernetesVersion),
    type =~ 'microsoft.dbformysql/flexibleservers', tostring(properties.version),
    type =~ 'microsoft.dbforpostgresql/flexibleservers', tostring(properties.version),
    type =~ 'microsoft.dbformysql/servers', tostring(properties.version),
    type =~ 'microsoft.dbforpostgresql/servers', tostring(properties.version),
    type =~ 'microsoft.dbformariadb/servers', tostring(properties.version),
    type =~ 'microsoft.sql/servers', tostring(properties.version),
    type =~ 'microsoft.cache/redis', tostring(properties.redisVersion),
    type =~ 'microsoft.cache/redisenterprise', tostring(properties.redisVersion),
    type =~ 'microsoft.documentdb/databaseaccounts', tostring(properties.mongoServerVersion),
    type =~ 'microsoft.hdinsight/clusters', tostring(properties.clusterVersion),
    type =~ 'microsoft.kusto/clusters', tostring(properties.engineType),
    type =~ 'microsoft.databricks/workspaces', tostring(properties.parameters.customerManagedKeyVersion),
    type =~ 'microsoft.elasticsan/elasticsans', tostring(properties.provisioningState),
    ''
)
| project name, type, kind, location, resourceGroup, subscriptionId, id, managedBy, sku = inventorySku, plan, zones, version = inventoryVersion
'@
    )

    $startedAt = Get-Date
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $queryPreview = $null
    try {
        $queryPreview = ($Query -replace '[\r\n\t]+', ' ') -replace '\s{2,}', ' '
        if ($queryPreview.Length -gt 200) {
            $queryPreview = $queryPreview.Substring(0, 200) + '...'
        }
    }
    catch {
        $queryPreview = '<unavailable>'
    }

    $scopeLabel = if ($SubscriptionIds -and @($SubscriptionIds).Count -gt 0) { 'Subscription' } else { 'Tenant' }
    $subCount = if ($SubscriptionIds) { @($SubscriptionIds).Count } else { 0 }
    Write-Verbose ('{0:o} Invoke-WAFQuery start. Scope={1} SubscriptionCount={2} QueryPreview="{3}"' -f $startedAt, $scopeLabel, $subCount, $queryPreview)

    function Test-WAFIsAzureChinaCloud {
        try {
            $ctx = Get-AzContext -ErrorAction Stop
            return ($ctx.Environment.Name -eq 'AzureChinaCloud')
        }
        catch {
            return $false
        }
    }

    # China cloud compatibility:
    # AzureChinaCloud blocks/disallows the logical table name 'appserviceresources'.
    # In China cloud, equivalent data can be queried using the standard 'resources' table.
    $effectiveQuery = $Query
    if (Test-WAFIsAzureChinaCloud -and $effectiveQuery -match '(?i)\bappserviceresources\b') {
        Write-Verbose "AzureChinaCloud detected; rewriting ARG table name: appserviceresources -> resources"
        $effectiveQuery = [Regex]::Replace($effectiveQuery, '(?i)\bappserviceresources\b', 'resources')
    }

    # Diagnostics: optionally dump the exact KQL that will be sent to ARG.
    # This is helpful when a run appears to hang on a specific query.
    $queryHash = $null
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($effectiveQuery))
        $sha256.Dispose()
        $queryHash = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
    }
    catch {
        $queryHash = $null
    }

    if ($queryHash) {
        Write-Verbose ("{0:o} Invoke-WAFQuery effective query SHA256={1}" -f (Get-Date), $queryHash)
    }

    $dumpDir = $env:WARA_DIAGNOSTICS_QUERY_DUMP_DIR
    if ($dumpDir -and $queryHash) {
        try {
            if (-not (Test-Path -LiteralPath $dumpDir -PathType Container)) {
                New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null
            }

            if (Test-Path -LiteralPath $dumpDir -PathType Container) {
                $dumpPath = Join-Path -Path $dumpDir -ChildPath ("ARG-Query-{0}.kql" -f $queryHash)
                if (-not (Test-Path -LiteralPath $dumpPath -PathType Leaf)) {
                    Set-Content -LiteralPath $dumpPath -Value $effectiveQuery -Encoding utf8 -NoNewline
                }
                Write-Verbose ("{0:o} Invoke-WAFQuery query dumped to: {1}" -f (Get-Date), $dumpPath)
            }
            else {
                Write-Verbose ("{0:o} Invoke-WAFQuery query dump dir does not exist: {1}" -f (Get-Date), $dumpDir)
            }
        }
        catch {
            Write-Verbose ("{0:o} Invoke-WAFQuery failed to dump query. Error: {1}" -f (Get-Date), $_.Exception.Message)
        }
    }

    # Search-AzGraph returns a PSResourceGraphResponse with .Data and .SkipToken.
    # Always return a flat object[] so downstream code can iterate naturally.

    $page = 1
    if ($SubscriptionIds -and @($SubscriptionIds).Count -gt 0) {
        Write-Verbose ("{0:o} Invoke-WAFQuery page {1}: Search-AzGraph -First 1000 -Subscription (count={2})" -f (Get-Date), $page, @($SubscriptionIds).Count)
        $response = Search-AzGraph -Query $effectiveQuery -First 1000 -Subscription $SubscriptionIds -ErrorAction Stop
    }
    else {
        Write-Verbose ("{0:o} Invoke-WAFQuery page {1}: Search-AzGraph -First 1000 -UseTenantScope" -f (Get-Date), $page)
        $response = Search-AzGraph -Query $effectiveQuery -First 1000 -UseTenantScope -ErrorAction Stop
    }

    Write-Verbose ("{0:o} Invoke-WAFQuery page {1}: Search-AzGraph returned. HasData={2} HasSkipToken={3}" -f (Get-Date), $page, ($null -ne $response.Data), ([bool]$response.SkipToken))

    $allResources = @()
    if ($null -ne $response -and $null -ne $response.Data) {
        $allResources += @($response.Data)
    }

    while ($response.SkipToken) {
        $page++
        if ($SubscriptionIds -and @($SubscriptionIds).Count -gt 0) {
            Write-Verbose ("{0:o} Invoke-WAFQuery page {1}: Search-AzGraph -SkipToken <redacted> -First 1000 -Subscription" -f (Get-Date), $page)
            $response = Search-AzGraph -Query $effectiveQuery -SkipToken $response.SkipToken -Subscription $SubscriptionIds -First 1000 -ErrorAction Stop
        }
        else {
            Write-Verbose ("{0:o} Invoke-WAFQuery page {1}: Search-AzGraph -SkipToken <redacted> -First 1000 -UseTenantScope" -f (Get-Date), $page)
            $response = Search-AzGraph -Query $effectiveQuery -SkipToken $response.SkipToken -First 1000 -UseTenantScope -ErrorAction Stop
        }

        Write-Verbose ("{0:o} Invoke-WAFQuery page {1}: Search-AzGraph returned. HasData={2} HasSkipToken={3}" -f (Get-Date), $page, ($null -ne $response.Data), ([bool]$response.SkipToken))
        if ($null -ne $response -and $null -ne $response.Data) {
            $allResources += @($response.Data)
        }
    }

    Write-Verbose ("{0:o} Invoke-WAFQuery retrieved rows (pre-normalize)={1}" -f (Get-Date), @($allResources).Count)

    # Normalize certain ARG dynamic fields to readable strings for downstream JSON/Excel output.
    $i = 0
    foreach ($r in $allResources) {
        $i++
        if (($i % 5000) -eq 0) {
            Write-Verbose ("{0:o} Invoke-WAFQuery normalizing row {1}/{2}" -f (Get-Date), $i, @($allResources).Count)
        }
        if ($null -eq $r) { continue }

        if ($r.PSObject.Properties.Name -contains 'sku') {
            try {
                $r.sku = Format-WAFKeyValueObjectForDisplay -Value $r.sku -Multiline -TrailingSemicolon -ContextFieldName 'sku' -ContextResourceId ([string]$r.id) -ContextResourceName ([string]$r.name) -ContextResourceType ([string]$r.type)
            }
            catch {
                $rid = [string]$r.id
                if ([string]::IsNullOrWhiteSpace($rid)) { $rid = '<unknown>' }
                throw "Failed to normalize field 'sku' for resource id '$rid'. Error: $($_.Exception.Message)"
            }
        }

        if ($r.PSObject.Properties.Name -contains 'plan') {
            try {
                $r.plan = Format-WAFKeyValueObjectForDisplay -Value $r.plan -Multiline -TrailingSemicolon -ContextFieldName 'plan' -ContextResourceId ([string]$r.id) -ContextResourceName ([string]$r.name) -ContextResourceType ([string]$r.type)
            }
            catch {
                $rid = [string]$r.id
                if ([string]::IsNullOrWhiteSpace($rid)) { $rid = '<unknown>' }
                throw "Failed to normalize field 'plan' for resource id '$rid'. Error: $($_.Exception.Message)"
            }
        }

        if ($r.PSObject.Properties.Name -contains 'zones') {
            try {
                $r.zones = Format-WAFKeyValueObjectForDisplay -Value $r.zones -ContextFieldName 'zones' -ContextResourceId ([string]$r.id) -ContextResourceName ([string]$r.name) -ContextResourceType ([string]$r.type)
            }
            catch {
                $rid = [string]$r.id
                if ([string]::IsNullOrWhiteSpace($rid)) { $rid = '<unknown>' }
                throw "Failed to normalize field 'zones' for resource id '$rid'. Error: $($_.Exception.Message)"
            }
        }
    }

    $sw.Stop()
    Write-Verbose ("{0:o} Invoke-WAFQuery complete. Pages={1} Rows={2} Duration={3}ms" -f (Get-Date), $page, @($allResources).Count, $sw.ElapsedMilliseconds)

    return $allResources
}

function Format-WAFKeyValueObjectForDisplay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [object] $Value,

        [Parameter(Mandatory = $false)]
        [string[]] $PreferredKeyOrder = @('name', 'tier', 'capacity'),

        [Parameter(Mandatory = $false)]
        [switch] $Multiline,

        [Parameter(Mandatory = $false)]
        [switch] $TrailingSemicolon,

        # Guard rails for nested/dynamic objects coming back from ARG:
        # - Prevent call depth overflow for deeply nested objects
        # - Prevent infinite recursion for self-referencing objects
        [Parameter(DontShow)]
        [int] $MaxDepth = 4,

        [Parameter(DontShow)]
        [int] $Depth = 0,

        [Parameter(DontShow)]
        [System.Collections.Generic.HashSet[int]] $Seen = $null

        ,
        # Optional context for diagnostics (helps identify which resource/field contains unexpected deep/cyclic objects)
        [Parameter(DontShow)]
        [string] $ContextFieldName = $null,

        [Parameter(DontShow)]
        [string] $ContextResourceId = $null

        ,
        [Parameter(DontShow)]
        [string] $ContextResourceName = $null,

        [Parameter(DontShow)]
        [string] $ContextResourceType = $null
    )

    if ($null -eq $Value) { return $null }

    # Treat value types (DateTime/Guid/TimeSpan/etc.) as scalars.
    # Recursing into their properties can explode call depth (e.g., DateTime.Date returns DateTime).
    if ($Value -is [System.ValueType]) {
        $s = [string]$Value
        if ([string]::IsNullOrWhiteSpace($s) -or $s -eq 'null') { return $null }
        return $s
    }

    if ($null -eq $Seen) {
        $Seen = [System.Collections.Generic.HashSet[int]]::new()
    }

    function Write-WAFFormatIssueDump {
        param(
            [Parameter(Mandatory = $true)][string] $Reason,
            [Parameter(Mandatory = $true)][object] $Obj
        )

        try {
            $dumpDir = $env:WARA_DIAGNOSTICS_QUERY_DUMP_DIR
            if ([string]::IsNullOrWhiteSpace($dumpDir)) { return }

            if (-not (Test-Path -LiteralPath $dumpDir -PathType Container)) {
                New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null
            }
            if (-not (Test-Path -LiteralPath $dumpDir -PathType Container)) { return }

            $typeName = $null
            try { $typeName = $Obj.GetType().FullName } catch { $typeName = '<unknown>' }

            $keys = @()
            try {
                if ($Obj -is [System.Collections.IDictionary]) {
                    $keys = @($Obj.Keys | ForEach-Object { [string]$_ })
                }
                else {
                    $keys = @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
                }
            }
            catch {
                $keys = @()
            }

            $payload = [pscustomobject]@{
                TimestampUtc     = (Get-Date).ToUniversalTime().ToString('o')
                Reason           = $Reason
                FieldName        = $ContextFieldName
                ResourceId       = $ContextResourceId
                ResourceName     = $ContextResourceName
                ResourceType     = $ContextResourceType
                Depth            = $Depth
                MaxDepth         = $MaxDepth
                ValueType        = $typeName
                KeysOrProperties = @($keys | Sort-Object -Unique)
                ValueString      = [string]$Obj
            }

            $ts = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $fieldTag = if ([string]::IsNullOrWhiteSpace($ContextFieldName)) { 'unknown' } else { ($ContextFieldName -replace '[^a-zA-Z0-9_-]', '_') }
            $dumpPath = Join-Path -Path $dumpDir -ChildPath ("ARG-FormatIssue-{0}-{1}.json" -f $ts, $fieldTag)
            Set-Content -LiteralPath $dumpPath -Value ($payload | ConvertTo-Json -Depth 6) -Encoding utf8

            Write-Verbose ("Format-WAFKeyValueObjectForDisplay: {0}. ResourceId={1} ResourceType={2} Field={3} ValueType={4} Depth={5}/{6}. Dump={7}" -f $Reason, $ContextResourceId, $ContextResourceType, $ContextFieldName, $typeName, $Depth, $MaxDepth, $dumpPath)
        }
        catch {
            # Diagnostics must not break normal execution.
        }
    }

    if ($Depth -ge $MaxDepth) {
        Write-WAFFormatIssueDump -Reason 'MaxDepth' -Obj $Value
        $fallback = [string]$Value
        if ([string]::IsNullOrWhiteSpace($fallback) -or $fallback -eq 'null') { return $null }
        return $fallback
    }

    if (-not ($Value -is [string]) -and -not ($Value.GetType().IsValueType)) {
        try {
            $objId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Value)
            if ($Seen.Contains($objId)) {
                Write-WAFFormatIssueDump -Reason 'CycleDetected' -Obj $Value
                $fallback = [string]$Value
                if ([string]::IsNullOrWhiteSpace($fallback) -or $fallback -eq 'null') { return $null }
                return $fallback
            }
            $null = $Seen.Add($objId)
        }
        catch {
            # If we can't hash/track, proceed without cycle detection.
        }
    }

    if ($Value -is [string]) {
        $s = [string]$Value
        if ([string]::IsNullOrWhiteSpace($s) -or $s -eq 'null') { return $null }
        return $s
    }

    if ($Value -is [System.Array]) {
        $items = @($Value) | ForEach-Object {
            if ($null -eq $_) { return $null }
            $s = [string]$_
            if ([string]::IsNullOrWhiteSpace($s) -or $s -eq 'null') { return $null }
            return $s
        } | Where-Object { $_ }

        if (@($items).Count -eq 0) { return $null }
        return ($items -join ';')
    }

    $pairs = New-Object System.Collections.Generic.List[object]

    $tryAdd = {
        param([string] $Key, [object] $Obj)

        if ([string]::IsNullOrWhiteSpace($Key)) { return }

        $v = $null
        if ($Obj -is [System.Collections.IDictionary]) {
            if ($Obj.Contains($Key)) { $v = $Obj[$Key] }
        }
        else {
            $p = $Obj.PSObject.Properties | Where-Object { $_.Name -ieq $Key } | Select-Object -First 1
            if ($null -ne $p) { $v = $p.Value }
        }

        $sv = Format-WAFKeyValueObjectForDisplay -Value $v -PreferredKeyOrder $PreferredKeyOrder -MaxDepth $MaxDepth -Depth ($Depth + 1) -Seen $Seen -ContextFieldName $ContextFieldName -ContextResourceId $ContextResourceId -ContextResourceName $ContextResourceName -ContextResourceType $ContextResourceType
        if (-not [string]::IsNullOrWhiteSpace($sv)) {
            $pairs.Add([pscustomobject]@{ k = $Key; v = $sv })
        }
    }

    foreach ($k in $PreferredKeyOrder) {
        & $tryAdd $k $Value
    }

    $allKeys = @()
    if ($Value -is [System.Collections.IDictionary]) {
        $allKeys = @($Value.Keys)
    }
    else {
        $allKeys = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    }

    $remaining = $allKeys | Where-Object { $_ -and ($_ -notin $PreferredKeyOrder) } | Sort-Object -Unique
    foreach ($k in $remaining) {
        & $tryAdd $k $Value
    }

    if ($pairs.Count -eq 0) {
        $fallback = [string]$Value
        if ([string]::IsNullOrWhiteSpace($fallback) -or $fallback -eq 'null') { return $null }
        return $fallback
    }

    $lines = $pairs | ForEach-Object {
        $suffix = if ($TrailingSemicolon) { ';' } else { '' }
        ('{0}={1}{2}' -f $_.k, $_.v, $suffix)
    }

    if ($Multiline) {
        return ($lines -join "`n")
    }

    return ($lines -join '; ')
}

function Add-WAFResourceTopology {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $ResourceInventory,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $SubscriptionIds
    )

    if ($null -eq $ResourceInventory -or @($ResourceInventory).Count -eq 0) {
        return $ResourceInventory
    }

    $topologyPropertyNames = @(
        'topology_nicIds',
        'topology_subnetIds',
        'topology_subnetPrefixPairs',
        'topology_subnetDetails',
        'topology_vnetIds',
        'topology_privateIps',
        'topology_publicIpIds',
        'topology_publicIpPrefixIds',
        'topology_publicIpAddresses',
        'topology_publicFqdns',
        'topology_privateEndpointIds',
        'topology_privateEndpointSubnetIds',
        'topology_privateEndpointVnetIds',
        'topology_privateLinkTargetIds',
        'topology_vnetPeeringRemoteVnetIds',
        'topology_vnetPeeringDetails',
        'topology_connectedResourceIds',
        'topology_publicNetworkAccess',
        'topology_expressRouteCircuitIds',
        'topology_expressRouteGatewayIds',
        'topology_gatewayType'
    )

    function ConvertTo-NormalizedStringList {
        param([object] $Value)

        if ($null -eq $Value) { return @() }

        $arr = @()
        if ($Value -is [System.Array]) {
            $arr = @($Value)
        }
        else {
            $arr = @($Value)
        }

        $arr = $arr | ForEach-Object {
            if ($null -eq $_) { return $null }
            $s = [string]$_
            if ([string]::IsNullOrWhiteSpace($s)) { return $null }
            if ($s -eq 'null') { return $null }
            return $s
        } | Where-Object { $_ }

        return @($arr | Sort-Object -Unique)
    }

    function Join-StringList {
        param([object] $Value)
        $list = ConvertTo-NormalizedStringList -Value $Value
        if (@($list).Count -eq 0) { return $null }
        return ($list -join ';')
    }

    function Split-StringList {
        param([object] $Value)

        if ($null -eq $Value) { return @() }

        if ($Value -is [string]) {
            $s = [string]$Value
            if ([string]::IsNullOrWhiteSpace($s)) { return @() }
            $parts = $s.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne 'null' }
            return @($parts | Sort-Object -Unique)
        }

        if ($Value -is [System.Collections.IEnumerable]) {
            $items = @()
            foreach ($v in $Value) {
                if ($null -eq $v) { continue }
                $sv = [string]$v
                if ([string]::IsNullOrWhiteSpace($sv)) { continue }
                if ($sv -eq 'null') { continue }
                $items += $sv.Trim()
            }
            return @($items | Sort-Object -Unique)
        }

        $s2 = [string]$Value
        if ([string]::IsNullOrWhiteSpace($s2)) { return @() }
        return @($s2.Trim())
    }

    $invById = @{}
    foreach ($r in $ResourceInventory) {
        if ($null -eq $r -or [string]::IsNullOrWhiteSpace([string]$r.id)) { continue }
        $rid = ([string]$r.id).ToLowerInvariant()
        if (-not $invById.ContainsKey($rid)) {
            $invById[$rid] = $r
        }

        foreach ($p in $topologyPropertyNames) {
            if (-not ($r.PSObject.Properties.Name -contains $p)) {
                $r | Add-Member -MemberType NoteProperty -Name $p -Value $null
            }
        }
    }

    try {
        Write-Verbose 'Querying Azure Resource Graph for topology enrichment (VNet/Subnet/NIC/PrivateEndpoint/PublicIP/AppService/LB/Bastion/AppGW/Firewall/ER)..'

        function Invoke-WAFQueryOrEmpty {
            param(
                [Parameter(Mandatory = $true)][string] $Query,
                [Parameter(Mandatory = $true)][string] $FeatureName
            )

            try {
                return @(Invoke-WAFQuery -Query $Query -SubscriptionIds $SubscriptionIds)
            }
            catch {
                $msg = $_.Exception.Message
                if ($_.Exception.InnerException -and $_.Exception.InnerException.Message) {
                    $msg = "$msg | Inner: $($_.Exception.InnerException.Message)"
                }
                Write-Verbose ("Topology enrichment: ARG query failed for {0}; continuing. Error: {1}" -f $FeatureName, $msg)
                return @()
            }
        }

        function Test-WAFCanUseAzNetworkFallback {
            try {
                if (-not (Get-Command -Name Get-AzContext -ErrorAction SilentlyContinue)) { return $false }
                if (-not (Get-Command -Name Set-AzContext -ErrorAction SilentlyContinue)) { return $false }
                if (-not (Get-AzContext -ErrorAction SilentlyContinue)) { return $false }
                return $true
            }
            catch {
                return $false
            }
        }

        function Set-WAFSubscriptionContext {
            param(
                [Parameter(Mandatory = $true)][string] $SubscriptionId
            )

            if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { return $false }

            try {
                Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
                return $true
            }
            catch {
                Write-Verbose ("Topology enrichment: failed to set Az context to subscription {0}; skipping fallback in that subscription. Error: {1}" -f $SubscriptionId, $_.Exception.Message)
                return $false
            }
        }

        function Get-InventoryItemsByType {
            param(
                [Parameter(Mandatory = $true)][string] $ResourceType
            )

            return @($ResourceInventory | Where-Object {
                    $_.type -ieq $ResourceType -and
                    -not [string]::IsNullOrWhiteSpace([string]$_.name) -and
                    -not [string]::IsNullOrWhiteSpace([string]$_.resourceGroup)
                })
        }

        function New-TopologySetFromValues {
            param([object[]] $Values)
            $out = @()
            foreach ($v in @($Values)) {
                if ($null -eq $v) { continue }
                $s = [string]$v
                if (-not [string]::IsNullOrWhiteSpace($s)) { $out += $s }
            }
            return @($out | Select-Object -Unique)
        }

        # Subnet -> VNet map (+ subnet metadata)
        $subnetQuery = @"
resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand sn = properties.subnets
| extend subnetName = tostring(sn.name)
| extend subnetId = tostring(coalesce(sn.id, strcat(id, '/subnets/', subnetName)))
| extend subnetPrefix = tostring(coalesce(sn.properties.addressPrefix, sn.properties.addressPrefixes[0]))
| extend delegations = iif(isnull(sn.properties.delegations), dynamic([dynamic(null)]), sn.properties.delegations)
| mv-expand del = delegations
| extend delegationServiceName = tostring(del.properties.serviceName)
| extend nsgId = tostring(sn.properties.networkSecurityGroup.id)
| extend routeTableId = tostring(sn.properties.routeTable.id)
| summarize delegationServiceNames = make_set(delegationServiceName) by vnetId = id, vnetName = name, subscriptionId, resourceGroup, location, subnetId, subnetName, subnetPrefix, nsgId, routeTableId
"@
        $subnets = Invoke-WAFQueryOrEmpty -Query $subnetQuery -FeatureName 'subnets'
        $subnetToVnet = @{}
        $subnetToPrefix = @{}
        $subnetToName = @{}
        $subnetToDelegations = @{}
        $vnetToSubnetIds = @{}
        foreach ($s in @($subnets)) {
            if ($null -eq $s) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$s.subnetId)) { continue }
            $sidLower = ([string]$s.subnetId).ToLowerInvariant()
            $subnetToVnet[$sidLower] = [string]$s.vnetId
            if (-not [string]::IsNullOrWhiteSpace([string]$s.subnetName)) {
                $subnetToName[$sidLower] = [string]$s.subnetName
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$s.subnetPrefix)) {
                $subnetToPrefix[$sidLower] = [string]$s.subnetPrefix
            }

            $delegations = ConvertTo-NormalizedStringList -Value $s.delegationServiceNames
            if ($delegations.Count -gt 0) {
                $subnetToDelegations[$sidLower] = ($delegations -join ',')
            }

            $vnetLower = ([string]$s.vnetId).ToLowerInvariant()
            if (-not $vnetToSubnetIds.ContainsKey($vnetLower)) {
                $vnetToSubnetIds[$vnetLower] = New-Object System.Collections.Generic.List[string]
            }
            $vnetToSubnetIds[$vnetLower].Add([string]$s.subnetId)
        }

        # VNet Peerings: map local VNet -> remote VNet(s)
        $vnetPeeringQuery = @"
resources
| where type =~ 'microsoft.network/virtualnetworks/virtualnetworkpeerings'
| extend localVnetId = tostring(extract('(.+)/virtualNetworkPeerings/[^/]+$', 1, id))
| extend remoteVnetId = tostring(properties.remoteVirtualNetwork.id)
| extend peeringState = tostring(properties.peeringState)
| extend allowVnetAccess = tobool(properties.allowVirtualNetworkAccess)
| extend allowForwardedTraffic = tobool(properties.allowForwardedTraffic)
| extend allowGatewayTransit = tobool(properties.allowGatewayTransit)
| extend useRemoteGateways = tobool(properties.useRemoteGateways)
| project peeringId = id, peeringName = name, subscriptionId, resourceGroup, location, localVnetId, remoteVnetId, peeringState, allowVnetAccess, allowForwardedTraffic, allowGatewayTransit, useRemoteGateways
"@
        $vnetPeerings = Invoke-WAFQueryOrEmpty -Query $vnetPeeringQuery -FeatureName 'vnetPeerings'
        $vnetToRemoteVnetIds = @{}
        $vnetToPeeringDetails = @{}
        foreach ($p in @($vnetPeerings)) {
            if ($null -eq $p) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$p.localVnetId)) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$p.remoteVnetId)) { continue }

            $localId = ([string]$p.localVnetId).ToLowerInvariant()
            if (-not $vnetToRemoteVnetIds.ContainsKey($localId)) { $vnetToRemoteVnetIds[$localId] = New-Object System.Collections.Generic.List[string] }
            if (-not $vnetToPeeringDetails.ContainsKey($localId)) { $vnetToPeeringDetails[$localId] = New-Object System.Collections.Generic.List[string] }

            $vnetToRemoteVnetIds[$localId].Add([string]$p.remoteVnetId)

            $detail = "{0} (state={1}, fwd={2}, gwT={3}, useRGW={4})" -f [string]$p.remoteVnetId, [string]$p.peeringState, [string]$p.allowForwardedTraffic, [string]$p.allowGatewayTransit, [string]$p.useRemoteGateways
            $vnetToPeeringDetails[$localId].Add($detail)
        }

        # Fallback for clouds/tenants where ARG does not return virtualNetworkPeerings (e.g., AzureChinaCloud):
        # Use control-plane cmdlets to enumerate peerings per VNet already present in resource inventory.
        if ($vnetToRemoteVnetIds.Count -eq 0) {
            $getPeeringCmd = Get-Command -Name Get-AzVirtualNetworkPeering -ErrorAction SilentlyContinue
            if ($null -ne $getPeeringCmd -and (Test-WAFCanUseAzNetworkFallback)) {
                Write-Verbose 'No VNet peerings returned by ARG query; falling back to Get-AzVirtualNetworkPeering.'

                $vnetsInInventory = @($ResourceInventory | Where-Object {
                        $_.type -eq 'microsoft.network/virtualnetworks' -and -not [string]::IsNullOrWhiteSpace([string]$_.id)
                    })

                foreach ($vnet in $vnetsInInventory) {
                    $localVnetId = ([string]$vnet.id).ToLowerInvariant()
                    $rg = [string]$vnet.resourceGroup
                    $vnetName = [string]$vnet.name
                    if ([string]::IsNullOrWhiteSpace($rg) -or [string]::IsNullOrWhiteSpace($vnetName)) { continue }

                    try {
                        $peerings = @(Get-AzVirtualNetworkPeering -ResourceGroupName $rg -VirtualNetworkName $vnetName -ErrorAction SilentlyContinue)
                    }
                    catch {
                        Write-Verbose ("Topology enrichment: Get-AzVirtualNetworkPeering failed for {0}/{1}; continuing. Error: {2}" -f $rg, $vnetName, $_.Exception.Message)
                        continue
                    }
                    foreach ($peering in $peerings) {
                        if ($null -eq $peering) { continue }
                        $remoteId = [string]$peering.RemoteVirtualNetwork.Id
                        if ([string]::IsNullOrWhiteSpace($remoteId)) { continue }

                        if (-not $vnetToRemoteVnetIds.ContainsKey($localVnetId)) { $vnetToRemoteVnetIds[$localVnetId] = New-Object System.Collections.Generic.List[string] }
                        if (-not $vnetToPeeringDetails.ContainsKey($localVnetId)) { $vnetToPeeringDetails[$localVnetId] = New-Object System.Collections.Generic.List[string] }

                        $vnetToRemoteVnetIds[$localVnetId].Add($remoteId)

                        $detail = "{0} (state={1}, fwd={2}, gwT={3}, useRGW={4})" -f $remoteId, [string]$peering.PeeringState, [string]$peering.AllowForwardedTraffic, [string]$peering.AllowGatewayTransit, [string]$peering.UseRemoteGateways
                        $vnetToPeeringDetails[$localVnetId].Add($detail)
                    }
                }
            }
            else {
                Write-Verbose 'No VNet peerings returned by ARG query and Get-AzVirtualNetworkPeering is unavailable or Az context is missing; skipping peering enrichment.'
            }
        }

        # NICs: map NIC -> subnet/publicIP/privateIP and VM -> NICs
        $nicQuery = @"
resources
| where type =~ 'microsoft.network/networkinterfaces'
| mv-expand ipconf = properties.ipConfigurations
| extend subnetId = tostring(ipconf.properties.subnet.id)
| extend publicIpId = tostring(ipconf.properties.publicIPAddress.id)
| extend privateIp = tostring(ipconf.properties.privateIPAddress)
| summarize subnetIds = make_set(subnetId), publicIpIds = make_set(publicIpId), privateIps = make_set(privateIp), vmId = any(tostring(properties.virtualMachine.id)) by id, name, subscriptionId, resourceGroup, location
"@
        $nics = Invoke-WAFQueryOrEmpty -Query $nicQuery -FeatureName 'nics'
        $nicById = @{}
        $vmToNicIds = @{}
        foreach ($n in @($nics)) {
            if ($null -eq $n -or [string]::IsNullOrWhiteSpace([string]$n.id)) { continue }
            $nid = ([string]$n.id).ToLowerInvariant()
            $nicById[$nid] = $n

            if (-not [string]::IsNullOrWhiteSpace([string]$n.vmId)) {
                $vmid = ([string]$n.vmId).ToLowerInvariant()
                if (-not $vmToNicIds.ContainsKey($vmid)) { $vmToNicIds[$vmid] = New-Object System.Collections.Generic.List[string] }
                $vmToNicIds[$vmid].Add([string]$n.id)
            }
        }

        # Public IPs: id -> ip/fqdn
        $pipQuery = @"
resources
| where type =~ 'microsoft.network/publicipaddresses'
| extend ipAddress = tostring(properties.ipAddress)
| extend fqdn = tostring(properties.dnsSettings.fqdn)
| project id, name, ipAddress, fqdn, subscriptionId, resourceGroup, location
"@
        $pips = Invoke-WAFQueryOrEmpty -Query $pipQuery -FeatureName 'publicIps'
        $pipById = @{}
        foreach ($p in @($pips)) {
            if ($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.id)) { continue }
            $pipById[([string]$p.id).ToLowerInvariant()] = $p
        }

        # Load Balancers: frontends (subnet/publicIP/privateIP) + backends (NIC ipConfig IDs)
        $lbQuery = @"
resources
| where type =~ 'microsoft.network/loadbalancers'
| mv-expand fe = properties.frontendIPConfigurations to typeof(dynamic)
| extend feSubnetId = tostring(fe.properties.subnet.id)
| extend fePublicIpId = tostring(fe.properties.publicIPAddress.id)
| extend fePrivateIp = tostring(fe.properties.privateIPAddress)
| mv-expand be = properties.backendAddressPools to typeof(dynamic) limit 100
| mv-expand beip = be.properties.backendIPConfigurations to typeof(dynamic) limit 200
| extend backendIpConfigId = tostring(beip.id)
| summarize frontendSubnetIds = make_set(feSubnetId), frontendPublicIpIds = make_set(fePublicIpId), frontendPrivateIps = make_set(fePrivateIp), backendIpConfigIds = make_set(backendIpConfigId) by id, name, subscriptionId, resourceGroup, location
"@
        $lbs = Invoke-WAFQueryOrEmpty -Query $lbQuery -FeatureName 'loadBalancers'

        if (@($lbs).Count -eq 0 -and (Test-WAFCanUseAzNetworkFallback)) {
            $getLbCmd = Get-Command -Name Get-AzLoadBalancer -ErrorAction SilentlyContinue
            if ($null -ne $getLbCmd) {
                $lbItems = Get-InventoryItemsByType -ResourceType 'microsoft.network/loadbalancers'
                if ($lbItems.Count -gt 0) {
                    Write-Verbose 'No Load Balancers returned by ARG; falling back to Get-AzLoadBalancer (scoped to inventory).'
                    $lbFallbackById = @{}
                    foreach ($item in $lbItems) {
                        $subId = [string]$item.subscriptionId
                        if (-not (Set-WAFSubscriptionContext -SubscriptionId $subId)) { continue }

                        $rg = [string]$item.resourceGroup
                        $name = [string]$item.name
                        try {
                            $lb0 = Get-AzLoadBalancer -ResourceGroupName $rg -Name $name -ErrorAction Stop
                        }
                        catch {
                            Write-Verbose ("Topology enrichment: Get-AzLoadBalancer failed for {0}/{1}. Error: {2}" -f $rg, $name, $_.Exception.Message)
                            continue
                        }

                        if ($null -eq $lb0 -or [string]::IsNullOrWhiteSpace([string]$lb0.Id)) { continue }
                        $idLower = ([string]$lb0.Id).ToLowerInvariant()
                        if ($lbFallbackById.ContainsKey($idLower)) { continue }

                        $feSubnetIds = @()
                        $fePipIds = @()
                        $fePrivateIps = @()
                        foreach ($fe0 in @($lb0.FrontendIpConfigurations)) {
                            if ($null -eq $fe0) { continue }
                            if ($fe0.Subnet -and $fe0.Subnet.Id) { $feSubnetIds += [string]$fe0.Subnet.Id }
                            if ($fe0.PublicIpAddress -and $fe0.PublicIpAddress.Id) { $fePipIds += [string]$fe0.PublicIpAddress.Id }
                            if (-not [string]::IsNullOrWhiteSpace([string]$fe0.PrivateIpAddress)) { $fePrivateIps += [string]$fe0.PrivateIpAddress }
                        }

                        $backendIpConfigIds = @()
                        foreach ($pool0 in @($lb0.BackendAddressPools)) {
                            if ($null -eq $pool0) { continue }
                            foreach ($beip0 in @($pool0.BackendIpConfigurations)) {
                                if ($null -eq $beip0) { continue }
                                if (-not [string]::IsNullOrWhiteSpace([string]$beip0.Id)) { $backendIpConfigIds += [string]$beip0.Id }
                            }
                        }

                        $lbFallbackById[$idLower] = [pscustomobject]@{
                            id                = [string]$lb0.Id
                            name              = [string]$lb0.Name
                            subscriptionId    = $subId
                            resourceGroup     = $rg
                            location          = [string]$lb0.Location
                            frontendSubnetIds = New-TopologySetFromValues -Values $feSubnetIds
                            frontendPublicIpIds = New-TopologySetFromValues -Values $fePipIds
                            frontendPrivateIps = New-TopologySetFromValues -Values $fePrivateIps
                            backendIpConfigIds  = New-TopologySetFromValues -Values $backendIpConfigIds
                        }
                    }
                    $lbs = @($lbFallbackById.Values)
                }
            }
            else {
                Write-Verbose 'No Load Balancers returned by ARG and Get-AzLoadBalancer is unavailable; skipping LB fallback.'
            }
        }

        $lbById = @{}
        foreach ($lb in @($lbs)) {
            if ($null -eq $lb -or [string]::IsNullOrWhiteSpace([string]$lb.id)) { continue }
            $lbById[([string]$lb.id).ToLowerInvariant()] = $lb
        }

        # Bastion Hosts: subnet + publicIP/privateIP
        $bastionQuery = @"
resources
| where type =~ 'microsoft.network/bastionhosts'
| mv-expand ipconf = properties.ipConfigurations to typeof(dynamic)
| extend subnetId = tostring(ipconf.properties.subnet.id)
| extend publicIpId = tostring(ipconf.properties.publicIPAddress.id)
| extend privateIp = tostring(ipconf.properties.privateIPAddress)
| summarize subnetIds = make_set(subnetId), publicIpIds = make_set(publicIpId), privateIps = make_set(privateIp) by id, name, subscriptionId, resourceGroup, location
"@
        $bastions = Invoke-WAFQueryOrEmpty -Query $bastionQuery -FeatureName 'bastionHosts'

        if (@($bastions).Count -eq 0 -and (Test-WAFCanUseAzNetworkFallback)) {
            $getBastionCmd = Get-Command -Name Get-AzBastion -ErrorAction SilentlyContinue
            if ($null -ne $getBastionCmd) {
                $bastionItems = Get-InventoryItemsByType -ResourceType 'microsoft.network/bastionhosts'
                if ($bastionItems.Count -gt 0) {
                    Write-Verbose 'No Bastion Hosts returned by ARG; falling back to Get-AzBastion (scoped to inventory).'
                    $bastionFallbackById = @{}
                    foreach ($item in $bastionItems) {
                        $subId = [string]$item.subscriptionId
                        if (-not (Set-WAFSubscriptionContext -SubscriptionId $subId)) { continue }

                        $rg = [string]$item.resourceGroup
                        $name = [string]$item.name
                        try {
                            $b0 = Get-AzBastion -ResourceGroupName $rg -Name $name -ErrorAction Stop
                        }
                        catch {
                            Write-Verbose ("Topology enrichment: Get-AzBastion failed for {0}/{1}. Error: {2}" -f $rg, $name, $_.Exception.Message)
                            continue
                        }

                        if ($null -eq $b0 -or [string]::IsNullOrWhiteSpace([string]$b0.Id)) { continue }
                        $idLower = ([string]$b0.Id).ToLowerInvariant()
                        if ($bastionFallbackById.ContainsKey($idLower)) { continue }

                        $subnetIds = @()
                        $pipIds = @()
                        $privateIps = @()
                        foreach ($ip0 in @($b0.IpConfigurations)) {
                            if ($null -eq $ip0) { continue }
                            if ($ip0.Subnet -and $ip0.Subnet.Id) { $subnetIds += [string]$ip0.Subnet.Id }
                            if ($ip0.PublicIpAddress -and $ip0.PublicIpAddress.Id) { $pipIds += [string]$ip0.PublicIpAddress.Id }
                            if (-not [string]::IsNullOrWhiteSpace([string]$ip0.PrivateIpAddress)) { $privateIps += [string]$ip0.PrivateIpAddress }
                        }

                        $bastionFallbackById[$idLower] = [pscustomobject]@{
                            id = [string]$b0.Id
                            name = [string]$b0.Name
                            subscriptionId = $subId
                            resourceGroup = $rg
                            location = [string]$b0.Location
                            subnetIds = New-TopologySetFromValues -Values $subnetIds
                            publicIpIds = New-TopologySetFromValues -Values $pipIds
                            privateIps = New-TopologySetFromValues -Values $privateIps
                        }
                    }
                    $bastions = @($bastionFallbackById.Values)
                }
            }
            else {
                Write-Verbose 'No Bastion Hosts returned by ARG and Get-AzBastion is unavailable; skipping Bastion fallback.'
            }
        }

        $bastionById = @{}
        foreach ($bh in @($bastions)) {
            if ($null -eq $bh -or [string]::IsNullOrWhiteSpace([string]$bh.id)) { continue }
            $bastionById[([string]$bh.id).ToLowerInvariant()] = $bh
        }

        # Application Gateways: gateway subnet + frontends (publicIP/privateIP) + backends (NIC ipConfig IDs)
        $appGwQuery = @"
resources
| where type =~ 'microsoft.network/applicationgateways'
| mv-expand gip = properties.gatewayIPConfigurations to typeof(dynamic)
| extend gwSubnetId = tostring(gip.properties.subnet.id)
| mv-expand fe = properties.frontendIPConfigurations to typeof(dynamic)
| extend fePublicIpId = tostring(fe.properties.publicIPAddress.id)
| extend fePrivateIp = tostring(fe.properties.privateIPAddress)
| mv-expand be = properties.backendAddressPools to typeof(dynamic) limit 100
| mv-expand beip = be.properties.backendIPConfigurations to typeof(dynamic) limit 200
| extend backendIpConfigId = tostring(beip.id)
| summarize subnetIds = make_set(gwSubnetId), publicIpIds = make_set(fePublicIpId), privateIps = make_set(fePrivateIp), backendIpConfigIds = make_set(backendIpConfigId) by id, name, subscriptionId, resourceGroup, location
"@
        $appGws = Invoke-WAFQueryOrEmpty -Query $appGwQuery -FeatureName 'applicationGateways'

        if (@($appGws).Count -eq 0 -and (Test-WAFCanUseAzNetworkFallback)) {
            $getAgCmd = Get-Command -Name Get-AzApplicationGateway -ErrorAction SilentlyContinue
            if ($null -ne $getAgCmd) {
                $agItems = Get-InventoryItemsByType -ResourceType 'microsoft.network/applicationgateways'
                if ($agItems.Count -gt 0) {
                    Write-Verbose 'No Application Gateways returned by ARG; falling back to Get-AzApplicationGateway (scoped to inventory).'
                    $agFallbackById = @{}
                    foreach ($item in $agItems) {
                        $subId = [string]$item.subscriptionId
                        if (-not (Set-WAFSubscriptionContext -SubscriptionId $subId)) { continue }

                        $rg = [string]$item.resourceGroup
                        $name = [string]$item.name
                        try {
                            $ag0 = Get-AzApplicationGateway -ResourceGroupName $rg -Name $name -ErrorAction Stop
                        }
                        catch {
                            Write-Verbose ("Topology enrichment: Get-AzApplicationGateway failed for {0}/{1}. Error: {2}" -f $rg, $name, $_.Exception.Message)
                            continue
                        }

                        if ($null -eq $ag0 -or [string]::IsNullOrWhiteSpace([string]$ag0.Id)) { continue }
                        $idLower = ([string]$ag0.Id).ToLowerInvariant()
                        if ($agFallbackById.ContainsKey($idLower)) { continue }

                        $subnetIds = @()
                        foreach ($gip0 in @($ag0.GatewayIPConfigurations)) {
                            if ($null -eq $gip0) { continue }
                            if ($gip0.Subnet -and $gip0.Subnet.Id) { $subnetIds += [string]$gip0.Subnet.Id }
                        }

                        $pipIds = @()
                        $privateIps = @()
                        foreach ($fe0 in @($ag0.FrontendIpConfigurations)) {
                            if ($null -eq $fe0) { continue }
                            if ($fe0.PublicIpAddress -and $fe0.PublicIpAddress.Id) { $pipIds += [string]$fe0.PublicIpAddress.Id }
                            if (-not [string]::IsNullOrWhiteSpace([string]$fe0.PrivateIpAddress)) { $privateIps += [string]$fe0.PrivateIpAddress }
                        }

                        $backendIpConfigIds = @()
                        foreach ($pool0 in @($ag0.BackendAddressPools)) {
                            if ($null -eq $pool0) { continue }
                            foreach ($beip0 in @($pool0.BackendIpConfigurations)) {
                                if ($null -eq $beip0) { continue }
                                if (-not [string]::IsNullOrWhiteSpace([string]$beip0.Id)) { $backendIpConfigIds += [string]$beip0.Id }
                            }
                        }

                        $agFallbackById[$idLower] = [pscustomobject]@{
                            id = [string]$ag0.Id
                            name = [string]$ag0.Name
                            subscriptionId = $subId
                            resourceGroup = $rg
                            location = [string]$ag0.Location
                            subnetIds = New-TopologySetFromValues -Values $subnetIds
                            publicIpIds = New-TopologySetFromValues -Values $pipIds
                            privateIps = New-TopologySetFromValues -Values $privateIps
                            backendIpConfigIds = New-TopologySetFromValues -Values $backendIpConfigIds
                        }
                    }
                    $appGws = @($agFallbackById.Values)
                }
            }
            else {
                Write-Verbose 'No Application Gateways returned by ARG and Get-AzApplicationGateway is unavailable; skipping AppGW fallback.'
            }
        }

        $appGwById = @{}
        foreach ($ag in @($appGws)) {
            if ($null -eq $ag -or [string]::IsNullOrWhiteSpace([string]$ag.id)) { continue }
            $appGwById[([string]$ag.id).ToLowerInvariant()] = $ag
        }

        # Azure Firewalls: subnet + publicIP/privateIP
        $fwQuery = @"
resources
| where type =~ 'microsoft.network/azurefirewalls'
| mv-expand ipconf = properties.ipConfigurations to typeof(dynamic)
| extend subnetId = tostring(ipconf.properties.subnet.id)
| extend publicIpId = tostring(ipconf.properties.publicIPAddress.id)
| extend privateIp = tostring(ipconf.properties.privateIPAddress)
| summarize subnetIds = make_set(subnetId), publicIpIds = make_set(publicIpId), privateIps = make_set(privateIp) by id, name, subscriptionId, resourceGroup, location
"@
        $firewalls = Invoke-WAFQueryOrEmpty -Query $fwQuery -FeatureName 'azureFirewalls'

        if (@($firewalls).Count -eq 0 -and (Test-WAFCanUseAzNetworkFallback)) {
            $getFwCmd = Get-Command -Name Get-AzFirewall -ErrorAction SilentlyContinue
            if ($null -ne $getFwCmd) {
                $fwItems = Get-InventoryItemsByType -ResourceType 'microsoft.network/azurefirewalls'
                if ($fwItems.Count -gt 0) {
                    Write-Verbose 'No Azure Firewalls returned by ARG; falling back to Get-AzFirewall (scoped to inventory).'
                    $fwFallbackById = @{}
                    foreach ($item in $fwItems) {
                        $subId = [string]$item.subscriptionId
                        if (-not (Set-WAFSubscriptionContext -SubscriptionId $subId)) { continue }

                        $rg = [string]$item.resourceGroup
                        $name = [string]$item.name
                        try {
                            $fw0 = Get-AzFirewall -ResourceGroupName $rg -Name $name -ErrorAction Stop
                        }
                        catch {
                            Write-Verbose ("Topology enrichment: Get-AzFirewall failed for {0}/{1}. Error: {2}" -f $rg, $name, $_.Exception.Message)
                            continue
                        }

                        if ($null -eq $fw0 -or [string]::IsNullOrWhiteSpace([string]$fw0.Id)) { continue }
                        $idLower = ([string]$fw0.Id).ToLowerInvariant()
                        if ($fwFallbackById.ContainsKey($idLower)) { continue }

                        $subnetIds = @()
                        $pipIds = @()
                        $privateIps = @()
                        foreach ($ip0 in @($fw0.IpConfigurations)) {
                            if ($null -eq $ip0) { continue }
                            if ($ip0.Subnet -and $ip0.Subnet.Id) { $subnetIds += [string]$ip0.Subnet.Id }
                            if ($ip0.PublicIpAddress -and $ip0.PublicIpAddress.Id) { $pipIds += [string]$ip0.PublicIpAddress.Id }
                            if (-not [string]::IsNullOrWhiteSpace([string]$ip0.PrivateIpAddress)) { $privateIps += [string]$ip0.PrivateIpAddress }
                        }

                        $fwFallbackById[$idLower] = [pscustomobject]@{
                            id = [string]$fw0.Id
                            name = [string]$fw0.Name
                            subscriptionId = $subId
                            resourceGroup = $rg
                            location = [string]$fw0.Location
                            subnetIds = New-TopologySetFromValues -Values $subnetIds
                            publicIpIds = New-TopologySetFromValues -Values $pipIds
                            privateIps = New-TopologySetFromValues -Values $privateIps
                        }
                    }
                    $firewalls = @($fwFallbackById.Values)
                }
            }
            else {
                Write-Verbose 'No Azure Firewalls returned by ARG and Get-AzFirewall is unavailable; skipping Firewall fallback.'
            }
        }

        $fwById = @{}
        foreach ($fw in @($firewalls)) {
            if ($null -eq $fw -or [string]::IsNullOrWhiteSpace([string]$fw.id)) { continue }
            $fwById[([string]$fw.id).ToLowerInvariant()] = $fw
        }

        # Virtual Network Gateways: ipConfigs (subnet/publicIP/privateIP) + gateway type
        $vngQuery = @"
resources
| where type =~ 'microsoft.network/virtualnetworkgateways'
| extend gatewayType = tostring(properties.gatewayType)
| mv-expand ipconf = properties.ipConfigurations to typeof(dynamic)
| extend subnetId = tostring(ipconf.properties.subnet.id)
| extend publicIpId = tostring(ipconf.properties.publicIPAddress.id)
| extend privateIp = tostring(ipconf.properties.privateIPAddress)
| summarize gatewayType = any(gatewayType), subnetIds = make_set(subnetId), publicIpIds = make_set(publicIpId), privateIps = make_set(privateIp) by id, name, subscriptionId, resourceGroup, location
"@
        $vngs = Invoke-WAFQueryOrEmpty -Query $vngQuery -FeatureName 'virtualNetworkGateways'

        if (@($vngs).Count -eq 0 -and (Test-WAFCanUseAzNetworkFallback)) {
            $getVngCmd = Get-Command -Name Get-AzVirtualNetworkGateway -ErrorAction SilentlyContinue
            if ($null -ne $getVngCmd) {
                $vngItems = Get-InventoryItemsByType -ResourceType 'microsoft.network/virtualnetworkgateways'
                if ($vngItems.Count -gt 0) {
                    Write-Verbose 'No Virtual Network Gateways returned by ARG; falling back to Get-AzVirtualNetworkGateway (scoped to inventory).'
                    $vngFallbackById = @{}
                    foreach ($item in $vngItems) {
                        $subId = [string]$item.subscriptionId
                        if (-not (Set-WAFSubscriptionContext -SubscriptionId $subId)) { continue }

                        $rg = [string]$item.resourceGroup
                        $name = [string]$item.name
                        try {
                            $g0 = Get-AzVirtualNetworkGateway -ResourceGroupName $rg -Name $name -ErrorAction Stop
                        }
                        catch {
                            Write-Verbose ("Topology enrichment: Get-AzVirtualNetworkGateway failed for {0}/{1}. Error: {2}" -f $rg, $name, $_.Exception.Message)
                            continue
                        }

                        if ($null -eq $g0 -or [string]::IsNullOrWhiteSpace([string]$g0.Id)) { continue }
                        $idLower = ([string]$g0.Id).ToLowerInvariant()
                        if ($vngFallbackById.ContainsKey($idLower)) { continue }

                        $subnetIds = @()
                        $pipIds = @()
                        $privateIps = @()
                        foreach ($ip0 in @($g0.IpConfigurations)) {
                            if ($null -eq $ip0) { continue }
                            if ($ip0.Subnet -and $ip0.Subnet.Id) { $subnetIds += [string]$ip0.Subnet.Id }
                            if ($ip0.PublicIpAddress -and $ip0.PublicIpAddress.Id) { $pipIds += [string]$ip0.PublicIpAddress.Id }
                            if (-not [string]::IsNullOrWhiteSpace([string]$ip0.PrivateIpAddress)) { $privateIps += [string]$ip0.PrivateIpAddress }
                        }

                        $vngFallbackById[$idLower] = [pscustomobject]@{
                            id = [string]$g0.Id
                            name = [string]$g0.Name
                            subscriptionId = $subId
                            resourceGroup = $rg
                            location = [string]$g0.Location
                            gatewayType = if ([string]::IsNullOrWhiteSpace([string]$g0.GatewayType)) { $null } else { [string]$g0.GatewayType }
                            subnetIds = New-TopologySetFromValues -Values $subnetIds
                            publicIpIds = New-TopologySetFromValues -Values $pipIds
                            privateIps = New-TopologySetFromValues -Values $privateIps
                        }
                    }
                    $vngs = @($vngFallbackById.Values)
                }
            }
            else {
                Write-Verbose 'No Virtual Network Gateways returned by ARG and Get-AzVirtualNetworkGateway is unavailable; skipping VNG fallback.'
            }
        }

        $vngById = @{}
        foreach ($g in @($vngs)) {
            if ($null -eq $g -or [string]::IsNullOrWhiteSpace([string]$g.id)) { continue }
            $vngById[([string]$g.id).ToLowerInvariant()] = $g
        }

        # NAT Gateways: attached subnets + public IPs / prefixes
        $natGwQuery = @"
resources
| where type =~ 'microsoft.network/natgateways'
    | extend subnets = iif(isnull(properties.subnets), dynamic([dynamic(null)]), properties.subnets)
    | mv-expand sn = subnets
| extend subnetId = tostring(sn.id)
    | extend publicIpAddresses = iif(isnull(properties.publicIpAddresses), dynamic([dynamic(null)]), properties.publicIpAddresses)
    | mv-expand pip = publicIpAddresses
| extend publicIpId = tostring(pip.id)
    | extend publicIpPrefixes = iif(isnull(properties.publicIpPrefixes), dynamic([dynamic(null)]), properties.publicIpPrefixes)
    | mv-expand pfx = publicIpPrefixes
| extend publicIpPrefixId = tostring(pfx.id)
| summarize subnetIds = make_set(subnetId), publicIpIds = make_set(publicIpId), publicIpPrefixIds = make_set(publicIpPrefixId) by id, name, subscriptionId, resourceGroup, location
"@
        $natGws = Invoke-WAFQueryOrEmpty -Query $natGwQuery -FeatureName 'natGateways'

        if (@($natGws).Count -eq 0 -and (Test-WAFCanUseAzNetworkFallback)) {
            $getNatCmd = Get-Command -Name Get-AzNatGateway -ErrorAction SilentlyContinue
            if ($null -ne $getNatCmd) {
                $natItems = Get-InventoryItemsByType -ResourceType 'microsoft.network/natgateways'
                if ($natItems.Count -gt 0) {
                    Write-Verbose 'No NAT Gateways returned by ARG; falling back to Get-AzNatGateway (scoped to inventory).'
                    $natFallbackById = @{}
                    foreach ($item in $natItems) {
                        $subId = [string]$item.subscriptionId
                        if (-not (Set-WAFSubscriptionContext -SubscriptionId $subId)) { continue }

                        $rg = [string]$item.resourceGroup
                        $name = [string]$item.name
                        try {
                            $ng0 = Get-AzNatGateway -ResourceGroupName $rg -Name $name -ErrorAction Stop
                        }
                        catch {
                            Write-Verbose ("Topology enrichment: Get-AzNatGateway failed for {0}/{1}. Error: {2}" -f $rg, $name, $_.Exception.Message)
                            continue
                        }

                        if ($null -eq $ng0 -or [string]::IsNullOrWhiteSpace([string]$ng0.Id)) { continue }
                        $idLower = ([string]$ng0.Id).ToLowerInvariant()
                        if ($natFallbackById.ContainsKey($idLower)) { continue }

                        $subnetIds = @()
                        foreach ($sn0 in @($ng0.Subnets)) {
                            if ($null -eq $sn0) { continue }
                            if (-not [string]::IsNullOrWhiteSpace([string]$sn0.Id)) { $subnetIds += [string]$sn0.Id }
                        }

                        $pipIds = @()
                        foreach ($pip0 in @($ng0.PublicIpAddresses)) {
                            if ($null -eq $pip0) { continue }
                            if (-not [string]::IsNullOrWhiteSpace([string]$pip0.Id)) { $pipIds += [string]$pip0.Id }
                        }

                        $pfxIds = @()
                        foreach ($pfx0 in @($ng0.PublicIpPrefixes)) {
                            if ($null -eq $pfx0) { continue }
                            if (-not [string]::IsNullOrWhiteSpace([string]$pfx0.Id)) { $pfxIds += [string]$pfx0.Id }
                        }

                        $natFallbackById[$idLower] = [pscustomobject]@{
                            id = [string]$ng0.Id
                            name = [string]$ng0.Name
                            subscriptionId = $subId
                            resourceGroup = $rg
                            location = [string]$ng0.Location
                            subnetIds = New-TopologySetFromValues -Values $subnetIds
                            publicIpIds = New-TopologySetFromValues -Values $pipIds
                            publicIpPrefixIds = New-TopologySetFromValues -Values $pfxIds
                        }
                    }
                    $natGws = @($natFallbackById.Values)
                }
            }
            else {
                Write-Verbose 'No NAT Gateways returned by ARG and Get-AzNatGateway is unavailable; skipping NAT gateway fallback.'
            }
        }

        $natGwById = @{}
        foreach ($ng in @($natGws)) {
            if ($null -eq $ng -or [string]::IsNullOrWhiteSpace([string]$ng.id)) { continue }
            $natGwById[([string]$ng.id).ToLowerInvariant()] = $ng
        }

        # ExpressRoute circuits (for naming + diagram nodes)
        $erCircuitQuery = @"
resources
| where type =~ 'microsoft.network/expressroutecircuits'
| project id, name, subscriptionId, resourceGroup, location
"@
        $erCircuits = Invoke-WAFQueryOrEmpty -Query $erCircuitQuery -FeatureName 'expressRouteCircuits'

        if (@($erCircuits).Count -eq 0 -and (Test-WAFCanUseAzNetworkFallback)) {
            $getErCmd = Get-Command -Name Get-AzExpressRouteCircuit -ErrorAction SilentlyContinue
            if ($null -ne $getErCmd) {
                $erItems = Get-InventoryItemsByType -ResourceType 'microsoft.network/expressroutecircuits'
                if ($erItems.Count -gt 0) {
                    Write-Verbose 'No ExpressRoute Circuits returned by ARG; falling back to Get-AzExpressRouteCircuit (scoped to inventory).'
                    $erFallbackById = @{}
                    foreach ($item in $erItems) {
                        $subId = [string]$item.subscriptionId
                        if (-not (Set-WAFSubscriptionContext -SubscriptionId $subId)) { continue }

                        $rg = [string]$item.resourceGroup
                        $name = [string]$item.name
                        try {
                            $c0 = Get-AzExpressRouteCircuit -ResourceGroupName $rg -Name $name -ErrorAction Stop
                        }
                        catch {
                            Write-Verbose ("Topology enrichment: Get-AzExpressRouteCircuit failed for {0}/{1}. Error: {2}" -f $rg, $name, $_.Exception.Message)
                            continue
                        }

                        if ($null -eq $c0 -or [string]::IsNullOrWhiteSpace([string]$c0.Id)) { continue }
                        $idLower = ([string]$c0.Id).ToLowerInvariant()
                        if ($erFallbackById.ContainsKey($idLower)) { continue }

                        $erFallbackById[$idLower] = [pscustomobject]@{
                            id = [string]$c0.Id
                            name = [string]$c0.Name
                            subscriptionId = $subId
                            resourceGroup = $rg
                            location = [string]$c0.Location
                        }
                    }
                    $erCircuits = @($erFallbackById.Values)
                }
            }
            else {
                Write-Verbose 'No ExpressRoute Circuits returned by ARG and Get-AzExpressRouteCircuit is unavailable; skipping ER circuit fallback.'
            }
        }

        $erCircuitById = @{}
        foreach ($c in @($erCircuits)) {
            if ($null -eq $c -or [string]::IsNullOrWhiteSpace([string]$c.id)) { continue }
            $erCircuitById[([string]$c.id).ToLowerInvariant()] = $c
        }

        # Gateway connections: virtualNetworkGateway <-> expressRouteCircuit
        # Resource type is typically Microsoft.Network/connections with connectionType == ExpressRoute.
        $erConnQuery = @"
resources
| where type =~ 'microsoft.network/connections'
| extend connectionType = tostring(properties.connectionType)
| where connectionType =~ 'ExpressRoute'
| extend vngId = tostring(properties.virtualNetworkGateway1.id)
| extend erCircuitId = tostring(properties.expressRouteCircuit.id)
| project id, name, subscriptionId, resourceGroup, location, vngId, erCircuitId
"@
        $erConns = Invoke-WAFQueryOrEmpty -Query $erConnQuery -FeatureName 'expressRouteConnections'

        if (@($erConns).Count -eq 0 -and (Test-WAFCanUseAzNetworkFallback)) {
            $getConnCmd = Get-Command -Name Get-AzVirtualNetworkGatewayConnection -ErrorAction SilentlyContinue
            if ($null -ne $getConnCmd) {
                $connItems = Get-InventoryItemsByType -ResourceType 'microsoft.network/connections'
                if ($connItems.Count -gt 0) {
                    Write-Verbose 'No ExpressRoute Connections returned by ARG; falling back to Get-AzVirtualNetworkGatewayConnection (scoped to inventory).'
                    $connFallback = New-Object System.Collections.Generic.List[object]
                    foreach ($item in $connItems) {
                        $subId = [string]$item.subscriptionId
                        if (-not (Set-WAFSubscriptionContext -SubscriptionId $subId)) { continue }

                        $rg = [string]$item.resourceGroup
                        $name = [string]$item.name
                        try {
                            $conn0 = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $rg -Name $name -ErrorAction Stop
                        }
                        catch {
                            Write-Verbose ("Topology enrichment: Get-AzVirtualNetworkGatewayConnection failed for {0}/{1}. Error: {2}" -f $rg, $name, $_.Exception.Message)
                            continue
                        }

                        if ($null -eq $conn0) { continue }
                        if (-not [string]::IsNullOrWhiteSpace([string]$conn0.ConnectionType) -and [string]$conn0.ConnectionType -ne 'ExpressRoute') { continue }

                        $vngId = $null
                        if ($conn0.VirtualNetworkGateway1 -and $conn0.VirtualNetworkGateway1.Id) { $vngId = [string]$conn0.VirtualNetworkGateway1.Id }
                        $erCircuitId = $null
                        if ($conn0.ExpressRouteCircuit -and $conn0.ExpressRouteCircuit.Id) { $erCircuitId = [string]$conn0.ExpressRouteCircuit.Id }

                        if ([string]::IsNullOrWhiteSpace($vngId) -or [string]::IsNullOrWhiteSpace($erCircuitId)) { continue }

                        $connFallback.Add([pscustomobject]@{
                                id = if ([string]::IsNullOrWhiteSpace([string]$conn0.Id)) { $null } else { [string]$conn0.Id }
                                name = [string]$conn0.Name
                                subscriptionId = $subId
                                resourceGroup = $rg
                                location = [string]$conn0.Location
                                vngId = $vngId
                                erCircuitId = $erCircuitId
                            })
                    }

                    $erConns = @($connFallback.ToArray())
                }
            }
            else {
                Write-Verbose 'No ExpressRoute Connections returned by ARG and Get-AzVirtualNetworkGatewayConnection is unavailable; skipping ER connection fallback.'
            }
        }
        $vngToErCircuitIds = @{}
        $erCircuitToVngIds = @{}
        foreach ($c in @($erConns)) {
            if ($null -eq $c) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$c.vngId)) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$c.erCircuitId)) { continue }

            $vngIdLower = ([string]$c.vngId).ToLowerInvariant()
            $erIdLower = ([string]$c.erCircuitId).ToLowerInvariant()

            if (-not $vngToErCircuitIds.ContainsKey($vngIdLower)) { $vngToErCircuitIds[$vngIdLower] = New-Object System.Collections.Generic.List[string] }
            if (-not $erCircuitToVngIds.ContainsKey($erIdLower)) { $erCircuitToVngIds[$erIdLower] = New-Object System.Collections.Generic.List[string] }

            $vngToErCircuitIds[$vngIdLower].Add([string]$c.erCircuitId)
            $erCircuitToVngIds[$erIdLower].Add([string]$c.vngId)
        }

        # Private Endpoints: PE -> subnet + targets, and reverse target -> PEs
        $peQuery = @"
resources
| where type =~ 'microsoft.network/privateendpoints'
| mv-expand conn = properties.privateLinkServiceConnections
| extend targetId = tostring(conn.properties.privateLinkServiceId)
| extend subnetId = tostring(properties.subnet.id)
| summarize targetIds = make_set(targetId), subnetIds = make_set(subnetId) by id, name, subscriptionId, resourceGroup, location
"@
        $pes = Invoke-WAFQueryOrEmpty -Query $peQuery -FeatureName 'privateEndpoints'
        $peById = @{}
        $targetToPeIds = @{}
        foreach ($pe in @($pes)) {
            if ($null -eq $pe -or [string]::IsNullOrWhiteSpace([string]$pe.id)) { continue }
            $peid = ([string]$pe.id).ToLowerInvariant()
            $peById[$peid] = $pe
            foreach ($t in (ConvertTo-NormalizedStringList -Value $pe.targetIds)) {
                $tid = $t.ToLowerInvariant()
                if (-not $targetToPeIds.ContainsKey($tid)) { $targetToPeIds[$tid] = New-Object System.Collections.Generic.List[string] }
                $targetToPeIds[$tid].Add([string]$pe.id)
            }
        }

        # PostgreSQL Flexible Server: publicNetworkAccess (+ delegated subnet for VNet integration)
        # Field lives under properties.network.publicNetworkAccess (validated via ARG).
        $pgFlexQuery = @"
resources
| where type =~ 'microsoft.dbforpostgresql/flexibleservers'
| extend publicNetworkAccess = tostring(coalesce(properties.network.publicNetworkAccess, properties.publicNetworkAccess))
| extend delegatedSubnetId = tostring(coalesce(properties.network.delegatedSubnetResourceId, properties.delegatedSubnetResourceId))
| project id, publicNetworkAccess, delegatedSubnetId
"@
        $pgFlexServers = Invoke-WAFQueryOrEmpty -Query $pgFlexQuery -FeatureName 'postgresFlexibleServers'
        $pgFlexById = @{}
        foreach ($p in @($pgFlexServers)) {
            if ($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.id)) { continue }
            $pgFlexById[([string]$p.id).ToLowerInvariant()] = $p
        }

        # MySQL Flexible Server: delegated subnet for VNet integration
        $mysqlFlexQuery = @"
resources
| where type =~ 'microsoft.dbformysql/flexibleservers'
| extend delegatedSubnetId = tostring(coalesce(properties.network.delegatedSubnetResourceId, properties.delegatedSubnetResourceId))
| project id, delegatedSubnetId
"@
        $mysqlFlexServers = Invoke-WAFQueryOrEmpty -Query $mysqlFlexQuery -FeatureName 'mysqlFlexibleServers'
        $mysqlFlexById = @{}
        foreach ($m in @($mysqlFlexServers)) {
            if ($null -eq $m -or [string]::IsNullOrWhiteSpace([string]$m.id)) { continue }
            $mysqlFlexById[([string]$m.id).ToLowerInvariant()] = $m
        }

        # Azure SQL Servers: publicNetworkAccess
        $sqlServerQuery = @"
resources
| where type =~ 'microsoft.sql/servers'
| extend publicNetworkAccess = tostring(properties.publicNetworkAccess)
| project id, publicNetworkAccess
"@
        $sqlServers = Invoke-WAFQueryOrEmpty -Query $sqlServerQuery -FeatureName 'sqlServers'
        $sqlServerById = @{}
        foreach ($s in @($sqlServers)) {
            if ($null -eq $s -or [string]::IsNullOrWhiteSpace([string]$s.id)) { continue }
            $sqlServerById[([string]$s.id).ToLowerInvariant()] = $s
        }

        # Storage Accounts: publicNetworkAccess
        $storageQuery = @"
resources
| where type =~ 'microsoft.storage/storageaccounts'
| extend publicNetworkAccess = tostring(properties.publicNetworkAccess)
| project id, publicNetworkAccess
"@
        $storageAccounts = Invoke-WAFQueryOrEmpty -Query $storageQuery -FeatureName 'storageAccounts'
        $storageById = @{}
        foreach ($s in @($storageAccounts)) {
            if ($null -eq $s -or [string]::IsNullOrWhiteSpace([string]$s.id)) { continue }
            $storageById[([string]$s.id).ToLowerInvariant()] = $s
        }

        # App Services: VNet integration subnet + publicNetworkAccess (+ App Service Plan mapping for SKU backfill)
        $appQuery = @"
resources
| where type =~ 'microsoft.web/sites'
| extend vnetSubnetId = tostring(properties.virtualNetworkSubnetId)
| extend publicNetworkAccess = tostring(properties.publicNetworkAccess)
| extend serverFarmId = tostring(properties.serverFarmId)
| project id, name, subscriptionId, resourceGroup, location, vnetSubnetId, publicNetworkAccess, serverFarmId
"@
        $apps = Invoke-WAFQueryOrEmpty -Query $appQuery -FeatureName 'appServices'
        $appById = @{}
        foreach ($a in @($apps)) {
            if ($null -eq $a -or [string]::IsNullOrWhiteSpace([string]$a.id)) { continue }
            $appById[([string]$a.id).ToLowerInvariant()] = $a
        }

        # App Service Plans: SKU (used to backfill sites SKU when missing)
        $aspQuery = @"
resources
| where type =~ 'microsoft.web/serverfarms'
| project id, sku
"@
        $appServicePlans = Invoke-WAFQueryOrEmpty -Query $aspQuery -FeatureName 'appServicePlans'
        $aspById = @{}
        foreach ($p in @($appServicePlans)) {
            if ($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.id)) { continue }
            $aspById[([string]$p.id).ToLowerInvariant()] = $p
        }

        foreach ($r in $ResourceInventory) {
            if ($null -eq $r -or [string]::IsNullOrWhiteSpace([string]$r.id)) { continue }
            $rid = ([string]$r.id).ToLowerInvariant()
            $rtype = [string]$r.type

            # If resource is a VNet, include its subnets in topology_subnetIds (to make networkConfig more useful)
            if ($rtype -ieq 'microsoft.network/virtualnetworks') {
                if ($vnetToSubnetIds.ContainsKey($rid)) {
                    $r.topology_subnetIds = Join-StringList -Value $vnetToSubnetIds[$rid]
                    $r.topology_vnetIds = Join-StringList -Value @([string]$r.id)
                }
            }

            # If resource is an App Service
            if ($appById.ContainsKey($rid)) {
                $a = $appById[$rid]
                $r.topology_publicNetworkAccess = if ([string]::IsNullOrWhiteSpace([string]$a.publicNetworkAccess)) { $null } else { [string]$a.publicNetworkAccess }

                # Backfill SKU for sites when missing: derive from the associated App Service Plan (serverFarmId)
                if ([string]::IsNullOrWhiteSpace([string]$r.sku)) {
                    $sfid = [string]$a.serverFarmId
                    if (-not [string]::IsNullOrWhiteSpace($sfid)) {
                        $sfidKey = $sfid.ToLowerInvariant()
                        if ($aspById.ContainsKey($sfidKey) -and -not [string]::IsNullOrWhiteSpace([string]$aspById[$sfidKey].sku)) {
                            $r.sku = [string]$aspById[$sfidKey].sku
                        }
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace([string]$a.vnetSubnetId)) {
                    $r.topology_subnetIds = Join-StringList -Value @([string]$a.vnetSubnetId)
                    $vnetId = $subnetToVnet[([string]$a.vnetSubnetId).ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($vnetId)) {
                        $r.topology_vnetIds = Join-StringList -Value @($vnetId)
                    }
                }
            }

            # If resource is a PostgreSQL Flexible Server
            if ($rtype -ieq 'microsoft.dbforpostgresql/flexibleservers' -and $pgFlexById.ContainsKey($rid)) {
                $p = $pgFlexById[$rid]
                if ([string]::IsNullOrWhiteSpace([string]$r.topology_publicNetworkAccess)) {
                    $r.topology_publicNetworkAccess = if ([string]::IsNullOrWhiteSpace([string]$p.publicNetworkAccess)) { $null } else { [string]$p.publicNetworkAccess }
                }

                # VNet integration (delegated subnet)
                $ds = [string]$p.delegatedSubnetId
                if (-not [string]::IsNullOrWhiteSpace($ds)) {
                    $existing = Split-StringList -Value $r.topology_subnetIds
                    $merged = @($existing + @($ds))
                    $r.topology_subnetIds = Join-StringList -Value $merged

                    $vnetId = $subnetToVnet[$ds.ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($vnetId)) {
                        $existingV = Split-StringList -Value $r.topology_vnetIds
                        $r.topology_vnetIds = Join-StringList -Value @($existingV + @($vnetId))
                    }
                }
            }

            # If resource is a MySQL Flexible Server (VNet integration delegated subnet)
            if ($rtype -ieq 'microsoft.dbformysql/flexibleservers' -and $mysqlFlexById.ContainsKey($rid)) {
                $m = $mysqlFlexById[$rid]
                $ds = [string]$m.delegatedSubnetId
                if (-not [string]::IsNullOrWhiteSpace($ds)) {
                    $existing = Split-StringList -Value $r.topology_subnetIds
                    $r.topology_subnetIds = Join-StringList -Value @($existing + @($ds))

                    $vnetId = $subnetToVnet[$ds.ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($vnetId)) {
                        $existingV = Split-StringList -Value $r.topology_vnetIds
                        $r.topology_vnetIds = Join-StringList -Value @($existingV + @($vnetId))
                    }
                }
            }

            # If resource is an Azure SQL Server
            if ($rtype -ieq 'microsoft.sql/servers' -and $sqlServerById.ContainsKey($rid)) {
                $s = $sqlServerById[$rid]
                if ([string]::IsNullOrWhiteSpace([string]$r.topology_publicNetworkAccess)) {
                    $r.topology_publicNetworkAccess = if ([string]::IsNullOrWhiteSpace([string]$s.publicNetworkAccess)) { $null } else { [string]$s.publicNetworkAccess }
                }
            }

            # If resource is a Storage Account
            if ($rtype -ieq 'microsoft.storage/storageaccounts' -and $storageById.ContainsKey($rid)) {
                $s = $storageById[$rid]
                if ([string]::IsNullOrWhiteSpace([string]$r.topology_publicNetworkAccess)) {
                    $r.topology_publicNetworkAccess = if ([string]::IsNullOrWhiteSpace([string]$s.publicNetworkAccess)) { $null } else { [string]$s.publicNetworkAccess }
                }
            }

            # If resource is a NIC
            if ($rtype -ieq 'microsoft.network/networkinterfaces' -and $nicById.ContainsKey($rid)) {
                $n = $nicById[$rid]
                $subnetIds = ConvertTo-NormalizedStringList -Value $n.subnetIds
                $publicIpResourceIds = ConvertTo-NormalizedStringList -Value $n.publicIpIds
                $privateIps = ConvertTo-NormalizedStringList -Value $n.privateIps

                $r.topology_subnetIds = Join-StringList -Value $subnetIds
                $r.topology_privateIps = Join-StringList -Value $privateIps
                $r.topology_publicIpIds = Join-StringList -Value $publicIpResourceIds

                $vnetIds = @()
                foreach ($sid in $subnetIds) {
                    $v = $subnetToVnet[$sid.ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $vnetIds += $v }
                }
                $r.topology_vnetIds = Join-StringList -Value $vnetIds

                $pipAddresses = @()
                $pipFqdns = @()
                $publicIpResourceIds | ForEach-Object {
                    $publicIpResourceId0 = [string]$_
                    if ([string]::IsNullOrWhiteSpace($publicIpResourceId0)) { return }
                    $p = $pipById[$publicIpResourceId0.ToLowerInvariant()]
                    if ($null -ne $p) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$p.ipAddress)) { $pipAddresses += [string]$p.ipAddress }
                        if (-not [string]::IsNullOrWhiteSpace([string]$p.fqdn)) { $pipFqdns += [string]$p.fqdn }
                    }
                }
                $r.topology_publicIpAddresses = Join-StringList -Value $pipAddresses
                $r.topology_publicFqdns = Join-StringList -Value $pipFqdns

                if (-not [string]::IsNullOrWhiteSpace([string]$n.vmId)) {
                    $r.topology_connectedResourceIds = Join-StringList -Value @([string]$n.vmId)
                }
            }

            # If resource is a VM, derive networking via NICs
            if ($rtype -ieq 'microsoft.compute/virtualmachines' -and $vmToNicIds.ContainsKey($rid)) {
                $nicIds = ConvertTo-NormalizedStringList -Value $vmToNicIds[$rid]
                $r.topology_nicIds = Join-StringList -Value $nicIds

                $subnetIds = @()
                $publicIpResourceIds = @()
                $privateIps = @()
                foreach ($nid in $nicIds) {
                    $n = $nicById[$nid.ToLowerInvariant()]
                    if ($null -eq $n) { continue }
                    $subnetIds += ConvertTo-NormalizedStringList -Value $n.subnetIds
                    $publicIpResourceIds += ConvertTo-NormalizedStringList -Value $n.publicIpIds
                    $privateIps += ConvertTo-NormalizedStringList -Value $n.privateIps
                }

                $r.topology_subnetIds = Join-StringList -Value $subnetIds
                $r.topology_privateIps = Join-StringList -Value $privateIps
                $r.topology_publicIpIds = Join-StringList -Value $publicIpResourceIds

                $vnetIds = @()
                foreach ($sid in (ConvertTo-NormalizedStringList -Value $subnetIds)) {
                    $v = $subnetToVnet[$sid.ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $vnetIds += $v }
                }
                $r.topology_vnetIds = Join-StringList -Value $vnetIds

                $pipAddresses = @()
                $pipFqdns = @()
                (ConvertTo-NormalizedStringList -Value $publicIpResourceIds) | ForEach-Object {
                    $publicIpResourceId0 = [string]$_
                    if ([string]::IsNullOrWhiteSpace($publicIpResourceId0)) { return }
                    $p = $pipById[$publicIpResourceId0.ToLowerInvariant()]
                    if ($null -ne $p) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$p.ipAddress)) { $pipAddresses += [string]$p.ipAddress }
                        if (-not [string]::IsNullOrWhiteSpace([string]$p.fqdn)) { $pipFqdns += [string]$p.fqdn }
                    }
                }
                $r.topology_publicIpAddresses = Join-StringList -Value $pipAddresses
                $r.topology_publicFqdns = Join-StringList -Value $pipFqdns
            }

            function Get-NicIdsFromIpConfigIds {
                param([object] $IpConfigIds)

                $nicIds = @()
                foreach ($ipconfId in (ConvertTo-NormalizedStringList -Value $IpConfigIds)) {
                    if ([string]::IsNullOrWhiteSpace([string]$ipconfId)) { continue }
                    $m = [regex]::Match([string]$ipconfId, '(?i)(.*/providers/Microsoft\.Network/networkInterfaces/[^/]+)')
                    if ($m.Success) {
                        $nicIds += [string]$m.Groups[1].Value
                    }
                }
                return @(ConvertTo-NormalizedStringList -Value $nicIds)
            }

            function Get-VmIdsFromNicIds {
                param([string[]] $NicIds)
                $vmIds = @()
                foreach ($nid2 in (ConvertTo-NormalizedStringList -Value $NicIds)) {
                    $n2 = $nicById[$nid2.ToLowerInvariant()]
                    if ($null -ne $n2 -and -not [string]::IsNullOrWhiteSpace([string]$n2.vmId)) {
                        $vmIds += [string]$n2.vmId
                    }
                }
                return @(ConvertTo-NormalizedStringList -Value $vmIds)
            }

            function Set-NetworkFromSubnetsAndPips {
                param(
                    [object] $Resource,
                    [object] $SubnetIds,
                    [object] $PublicIpIds,
                    [object] $PrivateIps
                )

                $subnetIds2 = ConvertTo-NormalizedStringList -Value $SubnetIds
                $publicIpIds2 = ConvertTo-NormalizedStringList -Value $PublicIpIds
                $privateIps2 = ConvertTo-NormalizedStringList -Value $PrivateIps

                if ($subnetIds2.Count -gt 0) { $Resource.topology_subnetIds = Join-StringList -Value $subnetIds2 }
                if ($publicIpIds2.Count -gt 0) { $Resource.topology_publicIpIds = Join-StringList -Value $publicIpIds2 }
                if ($privateIps2.Count -gt 0) { $Resource.topology_privateIps = Join-StringList -Value $privateIps2 }

                $vnetIds2 = @()
                foreach ($sid2 in $subnetIds2) {
                    $v = $subnetToVnet[$sid2.ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $vnetIds2 += $v }
                }
                if ($vnetIds2.Count -gt 0) { $Resource.topology_vnetIds = Join-StringList -Value $vnetIds2 }

                if ($publicIpIds2.Count -gt 0) {
                    $pipAddresses2 = @()
                    $pipFqdns2 = @()
                    foreach ($pipId2 in $publicIpIds2) {
                        $p2 = $pipById[$pipId2.ToLowerInvariant()]
                        if ($null -ne $p2) {
                            if (-not [string]::IsNullOrWhiteSpace([string]$p2.ipAddress)) { $pipAddresses2 += [string]$p2.ipAddress }
                            if (-not [string]::IsNullOrWhiteSpace([string]$p2.fqdn)) { $pipFqdns2 += [string]$p2.fqdn }
                        }
                    }
                    $Resource.topology_publicIpAddresses = Join-StringList -Value $pipAddresses2
                    $Resource.topology_publicFqdns = Join-StringList -Value $pipFqdns2
                }
            }

            # If resource is a Load Balancer
            if ($rtype -ieq 'microsoft.network/loadbalancers' -and $lbById.ContainsKey($rid)) {
                $lb = $lbById[$rid]
                Set-NetworkFromSubnetsAndPips -Resource $r -SubnetIds $lb.frontendSubnetIds -PublicIpIds $lb.frontendPublicIpIds -PrivateIps $lb.frontendPrivateIps

                $backendNicIds = Get-NicIdsFromIpConfigIds -IpConfigIds $lb.backendIpConfigIds
                if ($backendNicIds.Count -gt 0) {
                    $r.topology_nicIds = Join-StringList -Value $backendNicIds

                    # Helpful: connect LB -> backend VMs too (if resolvable via NIC -> VM)
                    $backendVmIds = Get-VmIdsFromNicIds -NicIds $backendNicIds
                    $connected = @($backendNicIds + $backendVmIds)
                    if ($connected.Count -gt 0) {
                        $r.topology_connectedResourceIds = Join-StringList -Value $connected
                    }
                }
            }

            # If resource is a Bastion Host
            if ($rtype -ieq 'microsoft.network/bastionhosts' -and $bastionById.ContainsKey($rid)) {
                $bh = $bastionById[$rid]
                Set-NetworkFromSubnetsAndPips -Resource $r -SubnetIds $bh.subnetIds -PublicIpIds $bh.publicIpIds -PrivateIps $bh.privateIps
            }

            # If resource is an Application Gateway
            if ($rtype -ieq 'microsoft.network/applicationgateways' -and $appGwById.ContainsKey($rid)) {
                $ag = $appGwById[$rid]
                Set-NetworkFromSubnetsAndPips -Resource $r -SubnetIds $ag.subnetIds -PublicIpIds $ag.publicIpIds -PrivateIps $ag.privateIps

                $backendNicIds = Get-NicIdsFromIpConfigIds -IpConfigIds $ag.backendIpConfigIds
                if ($backendNicIds.Count -gt 0) {
                    $r.topology_nicIds = Join-StringList -Value $backendNicIds

                    $backendVmIds = Get-VmIdsFromNicIds -NicIds $backendNicIds
                    $connected = @($backendNicIds + $backendVmIds)
                    if ($connected.Count -gt 0) {
                        $r.topology_connectedResourceIds = Join-StringList -Value $connected
                    }
                }
            }

            # If resource is an Azure Firewall
            if ($rtype -ieq 'microsoft.network/azurefirewalls' -and $fwById.ContainsKey($rid)) {
                $fw = $fwById[$rid]
                Set-NetworkFromSubnetsAndPips -Resource $r -SubnetIds $fw.subnetIds -PublicIpIds $fw.publicIpIds -PrivateIps $fw.privateIps
            }

            # If resource is a Virtual Network Gateway
            if ($rtype -ieq 'microsoft.network/virtualnetworkgateways' -and $vngById.ContainsKey($rid)) {
                $g = $vngById[$rid]
                Set-NetworkFromSubnetsAndPips -Resource $r -SubnetIds $g.subnetIds -PublicIpIds $g.publicIpIds -PrivateIps $g.privateIps
                $r.topology_gatewayType = if ([string]::IsNullOrWhiteSpace([string]$g.gatewayType)) { $null } else { [string]$g.gatewayType }

                if ($vngToErCircuitIds.ContainsKey($rid)) {
                    $r.topology_expressRouteCircuitIds = Join-StringList -Value $vngToErCircuitIds[$rid]

                    # Also expose as generic connectedResourceIds for downstream renderers.
                    $r.topology_connectedResourceIds = Join-StringList -Value $vngToErCircuitIds[$rid]
                }
            }

            # If resource is a NAT Gateway
            if ($rtype -ieq 'microsoft.network/natgateways' -and $natGwById.ContainsKey($rid)) {
                $ng = $natGwById[$rid]
                Set-NetworkFromSubnetsAndPips -Resource $r -SubnetIds $ng.subnetIds -PublicIpIds $ng.publicIpIds -PrivateIps @()
                $pfxIds = ConvertTo-NormalizedStringList -Value $ng.publicIpPrefixIds
                if ($pfxIds.Count -gt 0) {
                    $r.topology_publicIpPrefixIds = Join-StringList -Value $pfxIds
                }
            }

            # If resource is an ExpressRoute circuit
            if ($rtype -ieq 'microsoft.network/expressroutecircuits') {
                if ($erCircuitToVngIds.ContainsKey($rid)) {
                    $r.topology_expressRouteGatewayIds = Join-StringList -Value $erCircuitToVngIds[$rid]
                    $r.topology_connectedResourceIds = Join-StringList -Value $erCircuitToVngIds[$rid]
                }
            }

            # If resource is a Private Endpoint
            if ($rtype -ieq 'microsoft.network/privateendpoints' -and $peById.ContainsKey($rid)) {
                $pe = $peById[$rid]
                $peSubnetIds = ConvertTo-NormalizedStringList -Value $pe.subnetIds
                $peTargetIds = ConvertTo-NormalizedStringList -Value $pe.targetIds

                $r.topology_subnetIds = Join-StringList -Value $peSubnetIds
                $r.topology_privateLinkTargetIds = Join-StringList -Value $peTargetIds
                $r.topology_connectedResourceIds = Join-StringList -Value $peTargetIds

                $peVnetIds = @()
                foreach ($sid in $peSubnetIds) {
                    $v = $subnetToVnet[$sid.ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $peVnetIds += $v }
                }
                $r.topology_vnetIds = Join-StringList -Value $peVnetIds
            }

            # If resource is a Private Link target (reverse mapping)
            if ($targetToPeIds.ContainsKey($rid)) {
                $privateEndpointIdsList = ConvertTo-NormalizedStringList -Value $targetToPeIds[$rid]
                $r.topology_privateEndpointIds = Join-StringList -Value $privateEndpointIdsList

                $peSubnetIds = @()
                $peVnetIds = @()
                $privateEndpointIdsList | ForEach-Object {
                    $peId0 = [string]$_
                    if ([string]::IsNullOrWhiteSpace($peId0)) { return }
                    $pe = $peById[$peId0.ToLowerInvariant()]
                    if ($null -eq $pe) { return }
                    $peSubnetIds += ConvertTo-NormalizedStringList -Value $pe.subnetIds
                }
                foreach ($sid in (ConvertTo-NormalizedStringList -Value $peSubnetIds)) {
                    $v = $subnetToVnet[$sid.ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $peVnetIds += $v }
                }
                $r.topology_privateEndpointSubnetIds = Join-StringList -Value $peSubnetIds
                $r.topology_privateEndpointVnetIds = Join-StringList -Value $peVnetIds
            }

            # If resource is a VNet, add peering info (local VNet -> remote VNet)
            if ($rtype -ieq 'microsoft.network/virtualnetworks') {
                if ($vnetToRemoteVnetIds.ContainsKey($rid)) {
                    $r.topology_vnetPeeringRemoteVnetIds = Join-StringList -Value $vnetToRemoteVnetIds[$rid]
                }
                if ($vnetToPeeringDetails.ContainsKey($rid)) {
                    $r.topology_vnetPeeringDetails = Join-StringList -Value $vnetToPeeringDetails[$rid]
                }
            }
        }

        # Subnet prefix pairs (offline-friendly): write subnetId|prefix pairs into a single ';' delimited string.
        # This allows later exporters (JSON/Excel) to render subnet prefix labels without querying Azure.
        foreach ($r in $ResourceInventory) {
            if ($null -eq $r) { continue }

            $subnetIdsForResource = @(
                (Split-StringList -Value $r.topology_subnetIds) +
                (Split-StringList -Value $r.topology_privateEndpointSubnetIds)
            ) | Sort-Object -Unique

            if ($subnetIdsForResource.Count -eq 0) {
                $r.topology_subnetPrefixPairs = $null
                continue
            }

            $pairs = @()
            foreach ($sid in $subnetIdsForResource) {
                if ([string]::IsNullOrWhiteSpace([string]$sid)) { continue }
                $prefix = $subnetToPrefix[([string]$sid).ToLowerInvariant()]
                if (-not [string]::IsNullOrWhiteSpace([string]$prefix)) {
                    $pairs += ("{0}|{1}" -f [string]$sid, [string]$prefix)
                }
            }

            $r.topology_subnetPrefixPairs = Join-StringList -Value $pairs
        }

        # Subnet details (offline-friendly): subnetId|subnetName|cidr|delegations
        # Requirement: only VNets need detailed subnet metadata. Resources that merely reference a subnet
        # (e.g., MySQL/PostgreSQL Flexible Servers) only need subnet IDs.
        foreach ($r in $ResourceInventory) {
            if ($null -eq $r) { continue }

            if ($r.type -ine 'microsoft.network/virtualnetworks') {
                $r.topology_subnetDetails = $null
                continue
            }

            $subnetIdsForResource = @(
                (Split-StringList -Value $r.topology_subnetIds) +
                (Split-StringList -Value $r.topology_privateEndpointSubnetIds)
            ) | Sort-Object -Unique

            if ($subnetIdsForResource.Count -eq 0) {
                $r.topology_subnetDetails = $null
                continue
            }

            $details = @()
            foreach ($sid in $subnetIdsForResource) {
                if ([string]::IsNullOrWhiteSpace([string]$sid)) { continue }
                $sidLower = ([string]$sid).ToLowerInvariant()

                $name = $subnetToName[$sidLower]
                $cidr = $subnetToPrefix[$sidLower]
                $delegations = $subnetToDelegations[$sidLower]

                $details += ("{0}|{1}|{2}|{3}" -f [string]$sid, [string]$name, [string]$cidr, [string]$delegations)
            }

            $r.topology_subnetDetails = Join-StringList -Value $details
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException -and $_.Exception.InnerException.Message) {
            $msg = "$msg | Inner: $($_.Exception.InnerException.Message)"
        }
        Write-Warning ("Topology enrichment skipped due to error: {0}" -f $msg)
    }

    return $ResourceInventory
}

<#
.SYNOPSIS
    Invokes an Azure REST API then returns the response.

.DESCRIPTION
    The Invoke-AzureRestApi function invokes an Azure REST API with the specified parameters then return the response.

.PARAMETER Method
    The HTTP method to invoke the Azure REST API. The accepted values are GET, POST, PUT, PATCH, and DELETE.

.PARAMETER SubscriptionId
    The subscription ID that constitutes the URI for invoke the Azure REST API.

.PARAMETER ResourceGroupName
    The resource group name that constitutes the URI for invoke the Azure REST API.

.PARAMETER ResourceProviderName
    The resource provider name that constitutes the URI for invoke the Azure REST API. It's usually as the XXXX.XXXX format.

.PARAMETER ResourceType
    The resource type that constitutes the URI for invoke the Azure REST API.

.PARAMETER Name
    The resource name that constitutes the URI for invoke the Azure REST API.

.PARAMETER ApiVersion
    The Azure REST API version that constitutes the URI for invoke the Azure REST API. It's usually as the yyyy-mm-dd format.

.PARAMETER QueryString
    The query string that constitutes the URI for invoke the Azure REST API.

.PARAMETER RequestBody
    The request body for invoke the Azure REST API.

.OUTPUTS
    Returns a REST API response as the PSHttpResponse.

.EXAMPLE
    PS> $response = Invoke-AzureRestApi -Method 'GET' -SubscriptionId '11111111-1111-1111-1111-111111111111' -ResourceProviderName 'Microsoft.ResourceHealth' -ResourceType 'events' -ApiVersion '2024-02-01' -QueryString 'queryStartTime=2024-10-02T00:00:00'

.NOTES
    Author: Takeshi Katano
    Date: 2024-10-23

    This function requires the Az.Accounts module to be installed and imported.
#>
function Invoke-AzureRestApi {
    [CmdletBinding()]
    [OutputType([Microsoft.Azure.Commands.Profile.Models.PSHttpResponse])]
    param (
        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string] $Method,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $true)]
        [ValidateScript({ Test-WAFIsGuid -StringGuid $_ })]
        [string] $SubscriptionId,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [ValidateLength(1, 90)]
        [string] $ResourceGroupName,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $true)]
        [string] $ResourceProviderName,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $true)]
        [string] $ResourceType,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [string] $Name,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $true)]
        [ValidatePattern('^[0-9]{4}(-[0-9]{2}){2}$')]
        [string] $ApiVersion,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $false)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $false)]
        [string] $QueryString,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $false)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $false)]
        [string] $RequestBody
    )

    # Built the Azure REST API URI path.
    $cmdletParams = @{
        SubscriptionId       = $SubscriptionId
        ResourceProviderName = $ResourceProviderName
        ResourceType         = $ResourceType
        ApiVersion           = $ApiVersion
    }
    if ($PSBoundParameters.ContainsKey('ResourceGroupName')) { $cmdletParams.ResourceGroupName = $ResourceGroupName }
    if ($PSBoundParameters.ContainsKey('Name')) { $cmdletParams.Name = $Name }
    if ($PSBoundParameters.ContainsKey('QueryString')) { $cmdletParams.QueryString = $QueryString }
    $path = Get-AzureRestMethodUriPath @cmdletParams

    # Invoke the Azure REST API using the URI path.
    $cmdletParams = @{
        Method = $Method
        Path   = $path
    }
    if ($PSBoundParameters.ContainsKey('RequestBody')) { $cmdletParams.Payload = $RequestBody }
    return Invoke-AzRestMethod @cmdletParams
}

<#
.SYNOPSIS
    Retrieves the path of the Azure REST API URI.

.DESCRIPTION
    The Get-AzureRestMethodUriPath function retrieves the formatted path of the Azure REST API URI based on the specified URI parts as parameters.
    The path represents the Azure REST API URI without the protocol (e.g. https), host (e.g. management.azure.com). For example,
    /subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/stsample1234?api-version=2024-01-01

.PARAMETER SubscriptionId
    The subscription ID that constitutes the path of Azure REST API URI.

.PARAMETER ResourceGroupName
    The resource group name that constitutes the path of Azure REST API URI.

.PARAMETER ResourceProviderName
    The resource provider name that constitutes the path of Azure REST API URI. It's usually as the XXXX.XXXX format.

.PARAMETER ResourceType
    The resource type that constitutes the path of Azure REST API URI.

.PARAMETER Name
    The resource name that constitutes the path of Azure REST API URI.

.PARAMETER ApiVersion
    The Azure REST API version that constitutes the path of Azure REST API URI. It's usually as the yyyy-mm-dd format.

.PARAMETER QueryString
    The query string that constitutes the path of Azure REST API URI.

.OUTPUTS
    Returns a URI path to call Azure REST API.

.EXAMPLE
    PS> $path = Get-AzureRestMethodUriPath -SubscriptionId '11111111-1111-1111-1111-111111111111' -ResourceGroupName 'rg1' -ResourceProviderName 'Microsoft.Storage' -ResourceType 'storageAccounts' -Name 'stsample1234' -ApiVersion '2024-01-01' -QueryString 'param1=value1'

.NOTES
    Author: Takeshi Katano
    Date: 2024-10-23
#>
function Get-AzureRestMethodUriPath {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $true)]
        [ValidateScript({ Test-WAFIsGuid -StringGuid $_ })]
        [string] $SubscriptionId,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [ValidateLength(1, 90)]
        [string] $ResourceGroupName,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $true)]
        [string] $ResourceProviderName,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $true)]
        [string] $ResourceType,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [string] $Name,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $true)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $true)]
        [ValidatePattern('^[0-9]{4}(-[0-9]{2}){2}$')]
        [string] $ApiVersion,

        [Parameter(ParameterSetName = 'WithResourceGroup', Mandatory = $false)]
        [Parameter(ParameterSetName = 'WithoutResourceGroup', Mandatory = $false)]
        [string] $QueryString
    )

    $additionalQueryString = if ($PSBoundParameters.ContainsKey('QueryString')) { '&' + $QueryString } else { '' }
    $path = if ($PSCmdlet.ParameterSetName -eq 'WithResourceGroup') {
        '/subscriptions/{0}/resourcegroups/{1}/providers/{2}/{3}/{4}?api-version={5}{6}' -f $SubscriptionId, $ResourceGroupName, $ResourceProviderName, $ResourceType, $Name, $ApiVersion, $additionalQueryString
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'WithoutResourceGroup') {
        '/subscriptions/{0}/providers/{1}/{2}?api-version={3}{4}' -f $SubscriptionId, $ResourceProviderName, $ResourceType, $ApiVersion, $additionalQueryString
    }
    else {
        throw "The parameter set name [$($PSCmdlet.ParameterSetName)] is invalid."
    }
    return $path
}

<#
.SYNOPSIS
    Imports configuration data from a file.

.DESCRIPTION
    The `Import-WAFConfigFileData` function reads the content of a configuration file, extracts sections, and returns the data as a `PSCustomObject`. The configuration file should have sections defined by square brackets `[SectionName]` and key-value pairs within each section.

.PARAMETER ConfigFile
    The path to the configuration file.

.INPUTS
    System.String. The function accepts a string representing the path to the configuration file.

.OUTPUTS
    System.Management.Automation.PSCustomObject. Returns a custom object containing the configuration data.

.EXAMPLE
    PS> $configData = Import-WAFConfigFileData -ConfigFile "C:\config\settings.txt"

    This example imports configuration data from the specified file.

.EXAMPLE
    PS> Import-WAFConfigFileData -ConfigFile "config.txt"

    This example imports configuration data from 'config.txt' in the current directory.

.NOTES
    Author: Kyle Poineal
    Date: 2024-12-12
#>
function Import-WAFConfigFileData {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string] $ConfigFile
    )

    # Read the file content and store it in a variable
    $filecontent, $linetable, $objarray, $count, $start, $stop, $configsection = $null
    $filepath = (Resolve-Path -Path $configfile).Path
    $filecontent = (Get-content $filepath).trim().tolower()

    # Create an array to store the line number of each section
    $linetable = @()
    $objarray = [ordered]@{}

    $filecontent = $filecontent | Where-Object { $_ -ne '' -and $_ -notlike '*#*' }

    #Remove empty space.
    foreach ($line in $filecontent) {
        $index = $filecontent.IndexOf($line)
        if ($line -match '^\[([^\]]+)\]$' -and ($filecontent[$index + 1] -match '^\[([^\]]+)\]$' -or [string]::IsNullOrEmpty($filecontent[$index + 1]))) {
            # Set this line to empty because the next line is a section as well.
            # This is to avoid the section name being added to the object since it has no parameters.
            # This is because if we were to keep the note-property it would mess up logic for determining if a section is empty.
            # Powershell will return $true on an emtpy note property - Because the property exists.
            $filecontent[$index] = ''
        }
    }

    #Remove empty space again.
    $filecontent = $filecontent | Where-Object { $_ -ne '' -and $_ -notlike '*#*' }

    # Iterate through the file content and store the line number of each section
    foreach ($line in $filecontent) {
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.startswith('#')) {
            #Get the Index of the current line
            $index = $filecontent.IndexOf($line)
            # If the line is a section, store the line number
            if ($line -match '^\[([^\]]+)\]$') {
                # Store the section name and line number. Remove the brackets from the section name
                $linetable += $filecontent.indexof($line)
            }
        }
    }

    # Iterate through the line numbers and extract the section content
    $count = 0
    foreach ($entry in $linetable) {

        # Get the section name
        $name = $filecontent[$entry]
        # Remove the brackets from the section name
        $name = $name.replace('[', '').replace(']', '')

        # Get the start and stop line numbers for the section content
        # If the section is the last one, set the stop line number to the end of the file
        $start = $entry + 1

        if ($linetable.count -eq $count + 1) {
            $stop = $filecontent.count - 1
        }
        else {
            $stop = $linetable[$count + 1] - 1
        }

        # Extract the section content
        $configsection = $filecontent[$start..$stop]

        # Add the section content to the object array
        $objarray += @{$name = $configsection }

        # Increment the count
        $count++
    }

    # Return the object array and cast to PSCustomObject
    return [PSCustomObject]$objarray
}

<#
.SYNOPSIS
    Connects to an Azure tenant.

.DESCRIPTION
    The Connect-WAFAzure function connects to an Azure tenant using the provided Tenant ID and Subscription IDs.

.PARAMETER TenantID
    The Tenant ID to connect to.

.PARAMETER SubscriptionIds
    An array of Subscription IDs to scope the connection.

.PARAMETER AzureEnvironment
    The Azure environment to connect to. Defaults to 'AzureCloud'.

.OUTPUTS
    None.

.EXAMPLE
    PS> Connect-WAFAzure -TenantID "your-tenant-id" -SubscriptionIds @("sub1", "sub2") -AzureEnvironment "AzureCloud"
#>
function Connect-WAFAzure {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [GUID] $TenantID,

        [Parameter(Mandatory = $false)]
        [string] $AzureEnvironment = 'AzureCloud'
    )

    # Connect To Azure Tenant
    if ((Get-AzContext).Tenant.Id -ne $TenantID -or (Get-AzContext).Environment.Name -ne $AzureEnvironment) {
        Write-Debug "Connecting to Azure Tenant with Tenant ID: $TenantID and Azure Environment: $AzureEnvironment"
        Connect-AzAccount -Tenant $TenantID -WarningAction SilentlyContinue -Environment $AzureEnvironment | Out-Null
    }
}

<#
.SYNOPSIS
    Validates an array of tag patterns.

.DESCRIPTION
    The `Test-WAFTagPattern` function checks if each tag pattern in the input array follows the required format. Tags should be specified in the format 'Key!~Value||Key2!~Value2'.

.PARAMETER InputValue
    An array of tag patterns to validate.

.INPUTS
    System.String[]. The function accepts an array of tag pattern strings.

.OUTPUTS
    None. Throws an error if validation fails.

.EXAMPLE
    PS> Test-WAFTagPattern -InputValue @("Env!~Prod||Test", "Owner!~JohnDoe")

    This example validates valid tag patterns.

.EXAMPLE
    PS> Test-WAFTagPattern -InputValue @("InvalidTagPattern")

    Error:
    The tag pattern 'InvalidTagPattern' is invalid.

    This example demonstrates validation failure for an invalid tag pattern.

.NOTES
    Author: Kyle Poineal
    Date: 2024-12-12
#>
function Test-WAFTagPattern {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]] $InputValue
    )

    $pattern = '^[^<>&%\\?/]+=~[^<>&%\\?/]+$|[^<>&%\\?/]+!~[^<>&%\\?/]+$'

    $allMatch = $true
    foreach ($value in $InputValue) {
        if ($value -notmatch $pattern) {
            $allMatch = $false
            throw "Tag pattern [$value] is not valid."
            break
        }
    }
    return $allMatch
}

<#
.SYNOPSIS
    Validates an array of resource group IDs.

.DESCRIPTION
    The `Test-WAFResourceGroupId` function checks if each resource group ID in the input array follows the correct Azure resource group ID format.

.PARAMETER InputValue
    An array of resource group IDs to validate.

.INPUTS
    System.String[]. The function accepts an array of resource group ID strings.

.OUTPUTS
    None. Throws an error if validation fails.

.EXAMPLE
    PS> Test-WAFResourceGroupId -InputValue @("/subscriptions/59f6f1ab-6d68-4c90-b4e5-ad2d71cefc57/resourceGroups/MyResourceGroup")

    This example validates a valid resource group ID.

.EXAMPLE
    PS> Test-WAFResourceGroupId -InputValue @("invalid-resource-group-id")

    Error:
    The resource group ID 'invalid-resource-group-id' is invalid.

    This example demonstrates validation failure when an invalid resource group ID is provided.

.NOTES
    Author: Kyle Poineal
    Date: 2024-12-12
#>
function Test-WAFResourceGroupId {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]] $InputValue
    )

    $pattern = '\/subscriptions\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\/resourceGroups\/[a-zA-Z0-9._-]+'

    $allMatch = $true
    foreach ($value in $InputValue) {
        if ($value -notmatch $pattern) {
            $allMatch = $false
            throw "Resource Group ID [$value] is not valid."
            break
        }
    }
    return $allMatch
}

<#
.SYNOPSIS
    Validates an array of subscription IDs.

.DESCRIPTION
    The `Test-WAFSubscriptionId` function checks if each subscription ID in the input array is a valid GUID format. It throws an error if any subscription ID is invalid.

.PARAMETER InputValue
    An array of subscription IDs to validate.

.INPUTS
    System.String[]. The function accepts an array of subscription ID strings.

.OUTPUTS
    None. Throws an error if validation fails.

.EXAMPLE
    PS> Test-WAFSubscriptionId -InputValue @("59f6f1ab-6d68-4c90-b4e5-ad2d71cefc57", "invalid-guid")

    Error:
    The subscription ID 'invalid-guid' is not a valid GUID.

    This example demonstrates validation failure when an invalid subscription ID is provided.

.EXAMPLE
    PS> Test-WAFSubscriptionId -InputValue @("59f6f1ab-6d68-4c90-b4e5-ad2d71cefc57")

    This example validates a valid subscription ID without any error.

.NOTES
    Author: Kyle Poineal
    Date: 2024-12-12
#>
function Test-WAFSubscriptionId {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]] $InputValue
    )

    $pattern = '^(\/subscriptions\/)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\/?$'

    $allMatch = $true
    foreach ($value in $InputValue) {
        if ($value -notmatch $pattern) {
            $allMatch = $false
            throw "Subscription ID [$value] is not valid."
            break
        }
    }
    return $allMatch
}

<#
.SYNOPSIS
    Validates whether a string is a valid GUID.

.DESCRIPTION
    The `Test-WAFIsGuid` function checks if the input string is a valid GUID format.

.PARAMETER StringGuid
    The string to validate as a GUID.

.INPUTS
    System.String. The function accepts a string representing the GUID to validate.

.OUTPUTS
    System.Boolean. Returns `$true` if the input is a valid GUID, `$false` otherwise.

.EXAMPLE
    Test-WAFIsGuid -StringGuid "59f6f1ab-6d68-4c90-b4e5-ad2d71cefc57"

    Output:
    True

    This example checks if the provided string is a valid GUID.

.EXAMPLE
    Test-WAFIsGuid -StringGuid "invalid-guid"

    Output:
    False

    This example demonstrates that an invalid GUID returns `$false`.

.NOTES
    Author: Kyle Poineal
    Date: 2024-12-12
#>
function Test-WAFIsGuid {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $StringGuid
    )

    $ObjectGuid = [System.Guid]::Empty
    if (-not [System.Guid]::TryParse($StringGuid, [ref]$ObjectGuid)) {
        throw "The provided string [$StringGuid] is not a valid GUID."
    }
    return $true
}

<#
.SYNOPSIS
    Validates that the specified file exists.

.DESCRIPTION
    The `Test-FileExists` function checks if the specified file exists. If the file does not exist, the function throws an error.

.PARAMETER Path
    The path to the file to validate.

.OUTPUTS
    System.Boolean. Returns `$true` if the file exists, otherwise throws an error.

.EXAMPLE
    Test-FileExists -Path ".\this_file_exists.txt"

    Output:
    True

    This example demonstrates that the function returns `$true` when the specified file exists.

.EXAMPLE
    Test-FileExists -Path ".\this_file_does_not_exist.txt"

    Error:
    File [.\this_file_does_not_exist.txt] not found.

    This example demonstrates that the function throws an error when the specified file does not exist.

.NOTES
    Author: Casey Watson
    Date: 2025-02-04
#>
function Test-FileExists {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "File [$Path] not found."
    }

    return $true
}

<#
    .SYNOPSIS
        Ensures that subscription IDs are in the correct ARM resource ID format by adding "/subscriptions/" prefix if missing.

    .DESCRIPTION
        The `Repair-WAFSubscriptionId` function accepts an array of subscription IDs and checks each one to ensure it follows the Azure Resource Manager (ARM) resource ID format. If a subscription ID does not start with "/subscriptions/", the function prefixes it with "/subscriptions/". This standardizes the subscription IDs for consistent use in ARM queries and operations.

    .PARAMETER SubscriptionIds
        An array of subscription ID strings to validate and correct if necessary.

    .INPUTS
        System.String[]. You can pipe an array of subscription ID strings to this function.

    .OUTPUTS
        System.String[]. Returns an array of subscription IDs, each starting with "/subscriptions/".

    .EXAMPLE
        PS> $subs = @("59f6f1ab-6d68-4c90-b4e5-ad2d71cefc57", "/subscriptions/abcd1234-5678-90ab-cdef-1234567890ab")
        PS> $fixedSubs = Repair-WAFSubscriptionId -SubscriptionIds $subs
        PS> $fixedSubs

        Output:
        /subscriptions/59f6f1ab-6d68-4c90-b4e5-ad2d71cefc57
        /subscriptions/abcd1234-5678-90ab-cdef-1234567890ab

        This example demonstrates that the function adds the "/subscriptions/" prefix to a subscription ID that lacks it and leaves properly formatted IDs unchanged.

    .EXAMPLE
        PS> $subs = @()
        PS> $fixedSubs = Repair-WAFSubscriptionId -SubscriptionIds $subs

        This example shows that the function correctly handles an empty array without errors, returning an empty array.

    .EXAMPLE
        PS> $subs = @("invalid-guid", "12345678-1234-1234-1234-1234567890ab")
        PS> $fixedSubs = Repair-WAFSubscriptionId -SubscriptionIds $subs
        PS> $fixedSubs

        Output:
        /subscriptions/invalid-guid
        /subscriptions/12345678-1234-1234-1234-1234567890ab

        This example illustrates that the function does not validate the format of the GUID itself; it only ensures the prefix is present.

    .NOTES
        Author: Kyle Poineal
        Date: 2024-12-12
    #>
function Repair-WAFSubscriptionId {
    [CmdletBinding()]
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    param (
        [string[]] $SubscriptionIds
    )

    $fixedSubscriptionIds = @()
    foreach ($subscriptionId in $SubscriptionIds) {
        if ($subscriptionId -notmatch '\/subscriptions\/') {
            $fixedSubscriptionIds += "/subscriptions/$subscriptionId"
        }
        else {
            $fixedSubscriptionIds += $subscriptionId
        }
    }
    return $fixedSubscriptionIds
}
