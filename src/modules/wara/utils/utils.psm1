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
        [string] $Query = 'resources | project name, type, location, resourceGroup, subscriptionId, id'
    )

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

    $result = $SubscriptionIds ? (Search-AzGraph -Query $effectiveQuery -First 1000 -Subscription $SubscriptionIds -ErrorAction Stop) : (Search-AzGraph -Query $effectiveQuery -First 1000 -UseTenantScope -ErrorAction Stop) # -first 1000 returns the first 1000 results and subsequently reduces the amount of queries required to get data.

    # Collection to store all resources
    $allResources = @($result)

    # Loop to paginate through the results using the skip token
    $result = while ($result.SkipToken) {
        # Retrieve the next set of results using the skip token
        $result = $SubscriptionIds ? (Search-AzGraph -Query $effectiveQuery -SkipToken $result.SkipToken -Subscription $SubscriptionIds -First 1000 -ErrorAction Stop) : (Search-AzGraph -Query $effectiveQuery -SkipToken $result.SkipToken -First 1000 -UseTenantScope -ErrorAction Stop)
        # Add the results to the collection
        Write-Output $result
    }

    $allResources += $result

    # Output all resources
    return , $allResources
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
        'topology_vnetIds',
        'topology_privateIps',
        'topology_publicIpIds',
        'topology_publicIpAddresses',
        'topology_publicFqdns',
        'topology_privateEndpointIds',
        'topology_privateEndpointSubnetIds',
        'topology_privateEndpointVnetIds',
        'topology_privateLinkTargetIds',
        'topology_connectedResourceIds',
        'topology_publicNetworkAccess'
    )

    function Normalize-StringList {
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
        $list = Normalize-StringList -Value $Value
        if (@($list).Count -eq 0) { return $null }
        return ($list -join ';')
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
        Write-Verbose 'Querying Azure Resource Graph for topology enrichment (VNet/Subnet/NIC/PrivateEndpoint/PublicIP/AppService)..'

        # Subnet -> VNet map (+ subnet metadata)
        $subnetQuery = @"
resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand sn = properties.subnets
| extend subnetId = tostring(sn.id)
| extend subnetName = tostring(sn.name)
| extend subnetPrefix = tostring(sn.properties.addressPrefix)
| extend nsgId = tostring(sn.properties.networkSecurityGroup.id)
| extend routeTableId = tostring(sn.properties.routeTable.id)
| project vnetId = id, vnetName = name, subscriptionId, resourceGroup, location, subnetId, subnetName, subnetPrefix, nsgId, routeTableId
"@
        $subnets = Invoke-WAFQuery -Query $subnetQuery -SubscriptionIds $SubscriptionIds
        $subnetToVnet = @{}
        foreach ($s in @($subnets)) {
            if ($null -eq $s) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$s.subnetId)) { continue }
            $subnetToVnet[([string]$s.subnetId).ToLowerInvariant()] = [string]$s.vnetId
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
        $nics = Invoke-WAFQuery -Query $nicQuery -SubscriptionIds $SubscriptionIds
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
        $pips = Invoke-WAFQuery -Query $pipQuery -SubscriptionIds $SubscriptionIds
        $pipById = @{}
        foreach ($p in @($pips)) {
            if ($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.id)) { continue }
            $pipById[([string]$p.id).ToLowerInvariant()] = $p
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
        $pes = Invoke-WAFQuery -Query $peQuery -SubscriptionIds $SubscriptionIds
        $peById = @{}
        $targetToPeIds = @{}
        foreach ($pe in @($pes)) {
            if ($null -eq $pe -or [string]::IsNullOrWhiteSpace([string]$pe.id)) { continue }
            $peid = ([string]$pe.id).ToLowerInvariant()
            $peById[$peid] = $pe
            foreach ($t in (Normalize-StringList -Value $pe.targetIds)) {
                $tid = $t.ToLowerInvariant()
                if (-not $targetToPeIds.ContainsKey($tid)) { $targetToPeIds[$tid] = New-Object System.Collections.Generic.List[string] }
                $targetToPeIds[$tid].Add([string]$pe.id)
            }
        }

        # App Services: VNet integration subnet + publicNetworkAccess
        $appQuery = @"
resources
| where type =~ 'microsoft.web/sites'
| extend vnetSubnetId = tostring(properties.virtualNetworkSubnetId)
| extend publicNetworkAccess = tostring(properties.publicNetworkAccess)
| project id, name, subscriptionId, resourceGroup, location, vnetSubnetId, publicNetworkAccess
"@
        $apps = Invoke-WAFQuery -Query $appQuery -SubscriptionIds $SubscriptionIds
        $appById = @{}
        foreach ($a in @($apps)) {
            if ($null -eq $a -or [string]::IsNullOrWhiteSpace([string]$a.id)) { continue }
            $appById[([string]$a.id).ToLowerInvariant()] = $a
        }

        foreach ($r in $ResourceInventory) {
            if ($null -eq $r -or [string]::IsNullOrWhiteSpace([string]$r.id)) { continue }
            $rid = ([string]$r.id).ToLowerInvariant()
            $rtype = [string]$r.type

            # If resource is an App Service
            if ($appById.ContainsKey($rid)) {
                $a = $appById[$rid]
                $r.topology_publicNetworkAccess = if ([string]::IsNullOrWhiteSpace([string]$a.publicNetworkAccess)) { $null } else { [string]$a.publicNetworkAccess }
                if (-not [string]::IsNullOrWhiteSpace([string]$a.vnetSubnetId)) {
                    $r.topology_subnetIds = Join-StringList -Value @([string]$a.vnetSubnetId)
                    $vnetId = $subnetToVnet[([string]$a.vnetSubnetId).ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($vnetId)) {
                        $r.topology_vnetIds = Join-StringList -Value @($vnetId)
                    }
                }
            }

            # If resource is a NIC
            if ($rtype -ieq 'microsoft.network/networkinterfaces' -and $nicById.ContainsKey($rid)) {
                $n = $nicById[$rid]
                $subnetIds = Normalize-StringList -Value $n.subnetIds
                $publicIpIds = Normalize-StringList -Value $n.publicIpIds
                $privateIps = Normalize-StringList -Value $n.privateIps

                $r.topology_subnetIds = Join-StringList -Value $subnetIds
                $r.topology_privateIps = Join-StringList -Value $privateIps
                $r.topology_publicIpIds = Join-StringList -Value $publicIpIds

                $vnetIds = @()
                foreach ($sid in $subnetIds) {
                    $v = $subnetToVnet[$sid.ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $vnetIds += $v }
                }
                $r.topology_vnetIds = Join-StringList -Value $vnetIds

                $pipAddresses = @()
                $pipFqdns = @()
                foreach ($pid in $publicIpIds) {
                    $p = $pipById[$pid.ToLowerInvariant()]
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
                $nicIds = Normalize-StringList -Value $vmToNicIds[$rid]
                $r.topology_nicIds = Join-StringList -Value $nicIds

                $subnetIds = @()
                $publicIpIds = @()
                $privateIps = @()
                foreach ($nid in $nicIds) {
                    $n = $nicById[$nid.ToLowerInvariant()]
                    if ($null -eq $n) { continue }
                    $subnetIds += Normalize-StringList -Value $n.subnetIds
                    $publicIpIds += Normalize-StringList -Value $n.publicIpIds
                    $privateIps += Normalize-StringList -Value $n.privateIps
                }

                $r.topology_subnetIds = Join-StringList -Value $subnetIds
                $r.topology_privateIps = Join-StringList -Value $privateIps
                $r.topology_publicIpIds = Join-StringList -Value $publicIpIds

                $vnetIds = @()
                foreach ($sid in (Normalize-StringList -Value $subnetIds)) {
                    $v = $subnetToVnet[$sid.ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $vnetIds += $v }
                }
                $r.topology_vnetIds = Join-StringList -Value $vnetIds

                $pipAddresses = @()
                $pipFqdns = @()
                foreach ($pid in (Normalize-StringList -Value $publicIpIds)) {
                    $p = $pipById[$pid.ToLowerInvariant()]
                    if ($null -ne $p) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$p.ipAddress)) { $pipAddresses += [string]$p.ipAddress }
                        if (-not [string]::IsNullOrWhiteSpace([string]$p.fqdn)) { $pipFqdns += [string]$p.fqdn }
                    }
                }
                $r.topology_publicIpAddresses = Join-StringList -Value $pipAddresses
                $r.topology_publicFqdns = Join-StringList -Value $pipFqdns
            }

            # If resource is a Private Endpoint
            if ($rtype -ieq 'microsoft.network/privateendpoints' -and $peById.ContainsKey($rid)) {
                $pe = $peById[$rid]
                $peSubnetIds = Normalize-StringList -Value $pe.subnetIds
                $peTargetIds = Normalize-StringList -Value $pe.targetIds

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
                $peIds = Normalize-StringList -Value $targetToPeIds[$rid]
                $r.topology_privateEndpointIds = Join-StringList -Value $peIds

                $peSubnetIds = @()
                $peVnetIds = @()
                foreach ($pid in $peIds) {
                    $pe = $peById[$pid.ToLowerInvariant()]
                    if ($null -eq $pe) { continue }
                    $peSubnetIds += Normalize-StringList -Value $pe.subnetIds
                }
                foreach ($sid in (Normalize-StringList -Value $peSubnetIds)) {
                    $v = $subnetToVnet[$sid.ToLowerInvariant()]
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $peVnetIds += $v }
                }
                $r.topology_privateEndpointSubnetIds = Join-StringList -Value $peSubnetIds
                $r.topology_privateEndpointVnetIds = Join-StringList -Value $peVnetIds
            }
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
