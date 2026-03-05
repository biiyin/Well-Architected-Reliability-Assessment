BeforeAll {
    $modulePath = "$PSScriptRoot/../../modules/wara/utils/utils.psd1"
    Import-Module -Name $modulePath -Force
}

function script:Split-TopologyList {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

Describe 'Add-WAFResourceTopology - VNet subnet inventory in topology' {
    It 'Should populate topology_subnetIds for VNet resources' {
        $subId = '11111111-1111-1111-1111-111111111111'
        $vnetId = "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet1"
        $subnetId1 = "$vnetId/subnets/snet-a"
        $subnetId2 = "$vnetId/subnets/snet-b"

        $inventory = @(
            [pscustomobject]@{
                id            = $vnetId
                type          = 'microsoft.network/virtualnetworks'
                name          = 'vnet1'
                resourceGroup = 'rg'
            }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ($Query -match '(?i)microsoft\.network/virtualnetworks' -and $Query -match '(?i)mv-expand\s+sn\s*=\s*properties\.subnets') {
                return @(
                    [pscustomobject]@{
                        vnetId = $vnetId
                        vnetName = 'vnet1'
                        subscriptionId = $subId
                        resourceGroup = 'rg'
                        location = 'eastus'
                        subnetId = $subnetId1
                        subnetName = 'snet-a'
                        subnetPrefix = '10.0.0.0/24'
                        delegationServiceNames = @()
                        nsgId = $null
                        routeTableId = $null
                    },
                    [pscustomobject]@{
                        vnetId = $vnetId
                        vnetName = 'vnet1'
                        subscriptionId = $subId
                        resourceGroup = 'rg'
                        location = 'eastus'
                        subnetId = $subnetId2
                        subnetName = 'snet-b'
                        subnetPrefix = '10.0.1.0/24'
                        delegationServiceNames = @('Microsoft.Web/serverFarms')
                        nsgId = $null
                        routeTableId = $null
                    }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @($subId)

        (Split-TopologyList -Value $result[0].topology_subnetIds) | Should -Contain $subnetId1
        (Split-TopologyList -Value $result[0].topology_subnetIds) | Should -Contain $subnetId2

        $details = Split-TopologyList -Value $result[0].topology_subnetDetails
        $details.Count | Should -Be 2
        ($details | Where-Object { $_ -match '\|snet-a\|10\.0\.0\.0/24\|' }).Count | Should -Be 1
        ($details | Where-Object { $_ -match '\|snet-b\|10\.0\.1\.0/24\|Microsoft\.Web/serverFarms' }).Count | Should -Be 1
    }
}
