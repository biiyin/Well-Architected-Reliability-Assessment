BeforeAll {
    $modulePath = "$PSScriptRoot/../../modules/wara/utils/utils.psd1"
    Import-Module -Name $modulePath -Force
}

function script:Split-TopologyList {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

Describe 'Add-WAFResourceTopology - MySQL Flexible Server VNet integration enrichment' {
    It 'Should set topology_subnetIds and topology_vnetIds from delegatedSubnetResourceId' {
        $subId = '11111111-1111-1111-1111-111111111111'
        $vnetId = "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet1"
        $subnetId = "$vnetId/subnets/snet-db"
        $mysqlId = "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.DBforMySQL/flexibleServers/my1"

        $inventory = @(
            [pscustomobject]@{
                id            = $mysqlId
                type          = 'microsoft.dbformysql/flexibleservers'
                name          = 'my1'
                resourceGroup = 'rg'
            }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ($Query -match '(?i)microsoft\.network/virtualnetworks') {
                return @(
                    [pscustomobject]@{
                        vnetId = $vnetId
                        vnetName = 'vnet1'
                        subscriptionId = $subId
                        resourceGroup = 'rg'
                        location = 'eastus'
                        subnetId = $subnetId
                        subnetName = 'snet-db'
                        subnetPrefix = '10.0.1.0/24'
                        delegationServiceNames = @('Microsoft.DBforMySQL/flexibleServers')
                        nsgId = $null
                        routeTableId = $null
                    }
                )
            }

            if ($Query -match '(?i)microsoft\.dbformysql/flexibleservers') {
                return @(
                    [pscustomobject]@{
                        id = $mysqlId
                        delegatedSubnetId = $subnetId
                    }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @($subId)

        $result | Should -Not -BeNullOrEmpty
        (Split-TopologyList -Value $result[0].topology_subnetIds) | Should -Contain $subnetId
        (Split-TopologyList -Value $result[0].topology_vnetIds) | Should -Contain $vnetId
    }

    It 'Should NOT populate topology_subnetDetails for MySQL resources (only subnetIds are required)' {
        $subId = '11111111-1111-1111-1111-111111111111'
        $vnetId = "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet1"
        $subnetId = "$vnetId/subnets/snet-db"
        $mysqlId = "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.DBforMySQL/flexibleServers/my1"

        $inventory = @(
            [pscustomobject]@{
                id            = $mysqlId
                type          = 'microsoft.dbformysql/flexibleservers'
                name          = 'my1'
                resourceGroup = 'rg'
            }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ($Query -match '(?i)microsoft\.network/virtualnetworks') {
                return @(
                    [pscustomobject]@{
                        vnetId = $vnetId
                        vnetName = 'vnet1'
                        subscriptionId = $subId
                        resourceGroup = 'rg'
                        location = 'eastus'
                        subnetId = $subnetId
                        subnetName = 'snet-db'
                        subnetPrefix = '10.0.1.0/24'
                        delegationServiceNames = @('Microsoft.DBforMySQL/flexibleServers')
                        nsgId = $null
                        routeTableId = $null
                    }
                )
            }

            if ($Query -match '(?i)microsoft\.dbformysql/flexibleservers') {
                return @(
                    [pscustomobject]@{
                        id = $mysqlId
                        delegatedSubnetId = $subnetId
                    }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @($subId)

        $details = Split-TopologyList -Value $result[0].topology_subnetDetails
        $details.Count | Should -Be 0
    }
}
