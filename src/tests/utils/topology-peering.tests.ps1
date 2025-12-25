BeforeAll {
    $modulePath = "$PSScriptRoot/../../modules/wara/utils/utils.psd1"
    Import-Module -Name $modulePath -Force
}

Describe 'Add-WAFResourceTopology - VNet peering enrichment' {
    It 'Should populate VNet peering fields for VNet resources' {
        $vnetA = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnetA'
        $vnetB = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnetB'

        $inventory = @(
            [pscustomobject]@{
                id   = $vnetA
                type = 'microsoft.network/virtualnetworks'
                name = 'vnetA'
            }
        )

        $script:capturedQueries = New-Object System.Collections.Generic.List[string]

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            $script:capturedQueries.Add([string]$Query)

            if ($Query -match '(?i)virtualnetworkpeerings') {
                return @(
                    [pscustomobject]@{
                        peeringId            = "$vnetA/virtualNetworkPeerings/p1"
                        peeringName          = 'p1'
                        subscriptionId       = '11111111-1111-1111-1111-111111111111'
                        resourceGroup        = 'rg'
                        location             = 'eastus'
                        localVnetId          = $vnetA
                        remoteVnetId         = $vnetB
                        peeringState         = 'Connected'
                        allowVnetAccess      = $true
                        allowForwardedTraffic = $true
                        allowGatewayTransit  = $false
                        useRemoteGateways    = $false
                    }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        $result | Should -Not -BeNullOrEmpty
        $result[0].topology_vnetPeeringRemoteVnetIds | Should -BeExactly $vnetB
        $result[0].topology_vnetPeeringDetails | Should -Match ([regex]::Escape([string]$vnetB))
        $result[0].topology_vnetPeeringDetails | Should -Match 'state=Connected'

        # Sanity check: the peering ARG query path was executed
        ($script:capturedQueries | Where-Object { $_ -match '(?i)microsoft\.network/virtualnetworks/virtualnetworkpeerings' }).Count | Should -BeGreaterThan 0
    }

    It 'Should leave peering fields empty when no peerings exist' {
        $vnetA = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnetA'
        $inventory = @(
            [pscustomobject]@{
                id   = $vnetA
                type = 'microsoft.network/virtualnetworks'
                name = 'vnetA'
            }
        )

        Mock Invoke-WAFQuery { return @() } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        $result[0].PSObject.Properties.Name | Should -Contain 'topology_vnetPeeringRemoteVnetIds'
        $result[0].PSObject.Properties.Name | Should -Contain 'topology_vnetPeeringDetails'
        $result[0].topology_vnetPeeringRemoteVnetIds | Should -BeNullOrEmpty
        $result[0].topology_vnetPeeringDetails | Should -BeNullOrEmpty
    }
}
