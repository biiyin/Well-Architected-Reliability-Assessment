BeforeAll {
    $modulePath = "$PSScriptRoot/../../modules/wara/utils/utils.psd1"
    Import-Module -Name $modulePath -Force

    $AzFallbackPrereqs = {
        param(
            [Parameter(Mandatory = $true)][string] $SubscriptionId,
            [string[]] $ExtraCommands = @()
        )

        Mock Get-Command {
            param(
                [object] $Name,
                [Parameter(ValueFromRemainingArguments = $true)] $Rest
            )

            $n = $Name
            if ($n -is [System.Array] -and $n.Count -gt 0) { $n = $n[0] }
            $n = [string]$n

            $base = @('Get-AzContext', 'Set-AzContext')
            if ($base -contains $n -or $ExtraCommands -contains $n) {
                return [pscustomobject]@{ Name = $n }
            }
            return $null
        } -ModuleName utils

        Mock Get-AzContext {
            param(
                [Parameter(ValueFromRemainingArguments = $true)] $Rest
            )
            return [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $SubscriptionId } }
        } -ModuleName utils

        Mock Set-AzContext {
            param(
                [string] $SubscriptionId,
                [Parameter(ValueFromRemainingArguments = $true)] $Rest
            )
            return $null
        } -ModuleName utils
    }
}

Describe 'Add-WAFResourceTopology - network path enrichment' {
    It 'Should enrich Load Balancer networking and backend relationships' {
        $subnetId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnetA/subnets/default'
        $vnetId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnetA'
        $pipId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip1'
        $nicId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic1'
        $vmId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        $lbId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Network/loadBalancers/lb1'
        $ipConfigId = "$nicId/ipConfigurations/ipconfig1"

        $inventory = @(
            [pscustomobject]@{ id = $lbId; type = 'microsoft.network/loadbalancers'; name = 'lb1'; resourceGroup = $rg; subscriptionId = $subId }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ($Query -match '(?i)microsoft\.network/virtualnetworks' -and $Query -match '(?i)mv-expand\s+sn') {
                return @(
                    [pscustomobject]@{ subnetId = $subnetId; vnetId = $vnetId }
                )
            }

            if ($Query -match '(?i)microsoft\.network/virtualnetworks/virtualnetworkpeerings') { return @() }

            if ($Query -match '(?i)microsoft\.network/networkinterfaces') {
                return @(
                    [pscustomobject]@{ id = $nicId; subnetIds = @($subnetId); publicIpIds = @(); privateIps = @('10.0.0.4'); vmId = $vmId }
                )
            }

            if ($Query -match '(?i)microsoft\.network/publicipaddresses') {
                return @(
                    [pscustomobject]@{ id = $pipId; ipAddress = '1.2.3.4'; fqdn = 'pip1.example.com' }
                )
            }

            if ($Query -match '(?i)microsoft\.network/loadbalancers') {
                return @(
                    [pscustomobject]@{
                        id = $lbId
                        frontendSubnetIds = @($subnetId)
                        frontendPublicIpIds = @($pipId)
                        frontendPrivateIps = @('10.0.0.5')
                        backendIpConfigIds = @($ipConfigId)
                    }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        $result[0].topology_subnetIds | Should -Match ([regex]::Escape($subnetId))
        $result[0].topology_vnetIds | Should -Match ([regex]::Escape($vnetId))
        $result[0].topology_publicIpIds | Should -Match ([regex]::Escape($pipId))
        $result[0].topology_nicIds | Should -Match ([regex]::Escape($nicId))
        $result[0].topology_connectedResourceIds | Should -Match ([regex]::Escape($vmId))
    }

    It 'Should enrich ExpressRoute circuit to VNet gateway relationships' {
        $vngId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Network/virtualNetworkGateways/vng1'
        $circuitId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Network/expressRouteCircuits/er1'

        $inventory = @(
            [pscustomobject]@{ id = $vngId; type = 'microsoft.network/virtualnetworkgateways'; name = 'vng1' },
            [pscustomobject]@{ id = $circuitId; type = 'microsoft.network/expressroutecircuits'; name = 'er1' }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ($Query -match '(?i)microsoft\.network/virtualnetworks' -and $Query -match '(?i)mv-expand\s+sn') { return @() }
            if ($Query -match '(?i)microsoft\.network/virtualnetworks/virtualnetworkpeerings') { return @() }
            if ($Query -match '(?i)microsoft\.network/networkinterfaces') { return @() }
            if ($Query -match '(?i)microsoft\.network/publicipaddresses') { return @() }
            if ($Query -match '(?i)microsoft\.network/privateendpoints') { return @() }
            if ($Query -match '(?i)microsoft\.web/sites') { return @() }

            if ($Query -match '(?i)microsoft\.network/virtualnetworkgateways') {
                return @(
                    [pscustomobject]@{ id = $vngId; gatewayType = 'ExpressRoute'; subnetIds = @(); publicIpIds = @(); privateIps = @() }
                )
            }

            if ($Query -match '(?i)microsoft\.network/expressroutecircuits') {
                return @(
                    [pscustomobject]@{ id = $circuitId; name = 'er1' }
                )
            }

            if ($Query -match '(?i)microsoft\.network/connections') {
                return @(
                    [pscustomobject]@{ vngId = $vngId; erCircuitId = $circuitId }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        $gw = $result | Where-Object { $_.id -eq $vngId } | Select-Object -First 1
        $er = $result | Where-Object { $_.id -eq $circuitId } | Select-Object -First 1

        $gw.topology_gatewayType | Should -BeExactly 'ExpressRoute'
        $gw.topology_expressRouteCircuitIds | Should -Match ([regex]::Escape($circuitId))
        $er.topology_expressRouteGatewayIds | Should -Match ([regex]::Escape($vngId))
    }

    It 'Should fallback to Az.Network for Load Balancer when ARG returns empty' {
        $subId = '11111111-1111-1111-1111-111111111111'
        $rg = 'rg'

        $subnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA/subnets/default"
        $vnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA"
        $pipId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/pip1"
        $nicId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/networkInterfaces/nic1"
        $vmId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/vm1"
        $lbId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/loadBalancers/lb1"
        $ipConfigId = "$nicId/ipConfigurations/ipconfig1"

        $inventory = @(
            [pscustomobject]@{ id = $lbId; type = 'microsoft.network/loadbalancers'; name = 'lb1'; resourceGroup = $rg; subscriptionId = $subId }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ($Query -match '(?i)microsoft\.network/virtualnetworks' -and $Query -match '(?i)mv-expand\s+sn') {
                return @(
                    [pscustomobject]@{ subnetId = $subnetId; vnetId = $vnetId }
                )
            }

            if ($Query -match '(?i)microsoft\.network/networkinterfaces') {
                return @(
                    [pscustomobject]@{ id = $nicId; subnetIds = @($subnetId); publicIpIds = @(); privateIps = @('10.0.0.4'); vmId = $vmId }
                )
            }

            if ($Query -match '(?i)microsoft\.network/publicipaddresses') {
                return @(
                    [pscustomobject]@{ id = $pipId; ipAddress = '1.2.3.4'; fqdn = 'pip1.example.com' }
                )
            }

            if ($Query -match '(?i)microsoft\.network/loadbalancers') { return @() }
            if ($Query -match '(?i)microsoft\.network/virtualnetworks/virtualnetworkpeerings') { return @() }

            return @()
        } -ModuleName utils

        . $AzFallbackPrereqs -SubscriptionId $subId -ExtraCommands @('Get-AzLoadBalancer')

        Mock Get-AzLoadBalancer {
            param(
                [string] $ResourceGroupName,
                [string] $Name
            )

            return [pscustomobject]@{
                Id = $lbId
                Name = 'lb1'
                Location = 'eastus'
                FrontendIpConfigurations = @(
                    [pscustomobject]@{
                        Subnet = [pscustomobject]@{ Id = $subnetId }
                        PublicIpAddress = [pscustomobject]@{ Id = $pipId }
                        PrivateIpAddress = '10.0.0.5'
                    }
                )
                BackendAddressPools = @(
                    [pscustomobject]@{
                        BackendIpConfigurations = @(
                            [pscustomobject]@{ Id = $ipConfigId }
                        )
                    }
                )
            }
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @($subId)

        $result[0].topology_subnetIds | Should -Match ([regex]::Escape($subnetId))
        $result[0].topology_vnetIds | Should -Match ([regex]::Escape($vnetId))
        $result[0].topology_publicIpIds | Should -Match ([regex]::Escape($pipId))
        $result[0].topology_nicIds | Should -Match ([regex]::Escape($nicId))
        $result[0].topology_connectedResourceIds | Should -Match ([regex]::Escape($vmId))

        Assert-MockCalled Get-AzLoadBalancer -ModuleName utils -Times 1
    }

    It 'Should fallback to Az.Network for NAT Gateway when ARG returns empty' {
        $subId = '11111111-1111-1111-1111-111111111111'
        $rg = 'rg'

        $subnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA/subnets/default"
        $vnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA"
        $pipId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/pip1"
        $pipPrefixId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/publicIPPrefixes/pfx1"
        $natId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/natGateways/nat1"

        $inventory = @(
            [pscustomobject]@{ id = $natId; type = 'microsoft.network/natgateways'; name = 'nat1'; resourceGroup = $rg; subscriptionId = $subId }
        )

        Mock Invoke-WAFQuery {
            param([string[]] $SubscriptionIds, [string] $Query)

            if ($Query -match '(?i)microsoft\.network/virtualnetworks' -and $Query -match '(?i)mv-expand\s+sn') {
                return @([pscustomobject]@{ subnetId = $subnetId; vnetId = $vnetId })
            }
            if ($Query -match '(?i)microsoft\.network/virtualnetworks/virtualnetworkpeerings') { return @() }
            if ($Query -match '(?i)microsoft\.network/networkinterfaces') { return @() }
            if ($Query -match '(?i)microsoft\.network/publicipaddresses') {
                return @([pscustomobject]@{ id = $pipId; ipAddress = '1.2.3.4'; fqdn = 'pip1.example.com' })
            }
            if ($Query -match '(?i)microsoft\.network/natgateways') { return @() }
            return @()
        } -ModuleName utils

        . $AzFallbackPrereqs -SubscriptionId $subId -ExtraCommands @('Get-AzNatGateway')

        Mock Get-AzNatGateway {
            param([string] $ResourceGroupName, [string] $Name)

            return [pscustomobject]@{
                Id = $natId
                Name = 'nat1'
                Location = 'eastus'
                Subnets = @(
                    [pscustomobject]@{ Id = $subnetId }
                )
                PublicIpAddresses = @(
                    [pscustomobject]@{ Id = $pipId }
                )
                PublicIpPrefixes = @(
                    [pscustomobject]@{ Id = $pipPrefixId }
                )
            }
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @($subId)

        $result[0].topology_subnetIds | Should -Match ([regex]::Escape($subnetId))
        $result[0].topology_vnetIds | Should -Match ([regex]::Escape($vnetId))
        $result[0].topology_publicIpIds | Should -Match ([regex]::Escape($pipId))
        $result[0].topology_publicIpPrefixIds | Should -Match ([regex]::Escape($pipPrefixId))
        Assert-MockCalled Get-AzNatGateway -ModuleName utils -Times 1
    }

    It 'Should fallback to Az.Network for Application Gateway when ARG returns empty' {
        $subId = '11111111-1111-1111-1111-111111111111'
        $rg = 'rg'

        $subnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA/subnets/appgw"
        $vnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA"
        $pipId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/pip1"
        $nicId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/networkInterfaces/nic1"
        $vmId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/vm1"
        $agId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/applicationGateways/ag1"
        $ipConfigId = "$nicId/ipConfigurations/ipconfig1"

        $inventory = @(
            [pscustomobject]@{ id = $agId; type = 'microsoft.network/applicationgateways'; name = 'ag1'; resourceGroup = $rg; subscriptionId = $subId }
        )

        Mock Invoke-WAFQuery {
            param([string[]] $SubscriptionIds, [string] $Query)

            if ($Query -match '(?i)microsoft\.network/virtualnetworks' -and $Query -match '(?i)mv-expand\s+sn') {
                return @([pscustomobject]@{ subnetId = $subnetId; vnetId = $vnetId })
            }
            if ($Query -match '(?i)microsoft\.network/virtualnetworks/virtualnetworkpeerings') { return @() }
            if ($Query -match '(?i)microsoft\.network/networkinterfaces') {
                return @([pscustomobject]@{ id = $nicId; subnetIds = @($subnetId); publicIpIds = @(); privateIps = @('10.0.1.4'); vmId = $vmId })
            }
            if ($Query -match '(?i)microsoft\.network/publicipaddresses') {
                return @([pscustomobject]@{ id = $pipId; ipAddress = '1.2.3.4'; fqdn = 'pip1.example.com' })
            }
            if ($Query -match '(?i)microsoft\.network/applicationgateways') { return @() }
            return @()
        } -ModuleName utils

        . $AzFallbackPrereqs -SubscriptionId $subId -ExtraCommands @('Get-AzApplicationGateway')

        Mock Get-AzApplicationGateway {
            param([string] $ResourceGroupName, [string] $Name)

            return [pscustomobject]@{
                Id = $agId
                Name = 'ag1'
                Location = 'eastus'
                GatewayIPConfigurations = @(
                    [pscustomobject]@{ Subnet = [pscustomobject]@{ Id = $subnetId } }
                )
                FrontendIpConfigurations = @(
                    [pscustomobject]@{ PublicIpAddress = [pscustomobject]@{ Id = $pipId }; PrivateIpAddress = '10.0.1.5' }
                )
                BackendAddressPools = @(
                    [pscustomobject]@{ BackendIpConfigurations = @([pscustomobject]@{ Id = $ipConfigId }) }
                )
            }
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @($subId)

        $result[0].topology_subnetIds | Should -Match ([regex]::Escape($subnetId))
        $result[0].topology_vnetIds | Should -Match ([regex]::Escape($vnetId))
        $result[0].topology_publicIpIds | Should -Match ([regex]::Escape($pipId))
        $result[0].topology_nicIds | Should -Match ([regex]::Escape($nicId))
        $result[0].topology_connectedResourceIds | Should -Match ([regex]::Escape($vmId))
        Assert-MockCalled Get-AzApplicationGateway -ModuleName utils -Times 1
    }

    It 'Should fallback to Az.Network for Azure Firewall when ARG returns empty' {
        $subId = '11111111-1111-1111-1111-111111111111'
        $rg = 'rg'

        $subnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA/subnets/AzureFirewallSubnet"
        $vnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA"
        $pipId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/pip1"
        $fwId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/azureFirewalls/fw1"

        $inventory = @(
            [pscustomobject]@{ id = $fwId; type = 'microsoft.network/azurefirewalls'; name = 'fw1'; resourceGroup = $rg; subscriptionId = $subId }
        )

        Mock Invoke-WAFQuery {
            param([string[]] $SubscriptionIds, [string] $Query)

            if ($Query -match '(?i)microsoft\.network/virtualnetworks' -and $Query -match '(?i)mv-expand\s+sn') {
                return @([pscustomobject]@{ subnetId = $subnetId; vnetId = $vnetId })
            }
            if ($Query -match '(?i)microsoft\.network/virtualnetworks/virtualnetworkpeerings') { return @() }
            if ($Query -match '(?i)microsoft\.network/networkinterfaces') { return @() }
            if ($Query -match '(?i)microsoft\.network/publicipaddresses') {
                return @([pscustomobject]@{ id = $pipId; ipAddress = '1.2.3.4'; fqdn = 'pip1.example.com' })
            }
            if ($Query -match '(?i)microsoft\.network/azurefirewalls') { return @() }
            return @()
        } -ModuleName utils

        . $AzFallbackPrereqs -SubscriptionId $subId -ExtraCommands @('Get-AzFirewall')

        Mock Get-AzFirewall {
            param([string] $ResourceGroupName, [string] $Name)

            return [pscustomobject]@{
                Id = $fwId
                Name = 'fw1'
                Location = 'eastus'
                IpConfigurations = @(
                    [pscustomobject]@{
                        Subnet = [pscustomobject]@{ Id = $subnetId }
                        PublicIpAddress = [pscustomobject]@{ Id = $pipId }
                        PrivateIpAddress = '10.0.2.4'
                    }
                )
            }
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @($subId)

        $result[0].topology_subnetIds | Should -Match ([regex]::Escape($subnetId))
        $result[0].topology_vnetIds | Should -Match ([regex]::Escape($vnetId))
        $result[0].topology_publicIpIds | Should -Match ([regex]::Escape($pipId))
        Assert-MockCalled Get-AzFirewall -ModuleName utils -Times 1
    }

    It 'Should fallback to Az.Network for Virtual Network Gateway when ARG returns empty' {
        $subId = '11111111-1111-1111-1111-111111111111'
        $rg = 'rg'

        $subnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA/subnets/GatewaySubnet"
        $vnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA"
        $pipId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/pip1"
        $vngId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworkGateways/vng1"

        $inventory = @(
            [pscustomobject]@{ id = $vngId; type = 'microsoft.network/virtualnetworkgateways'; name = 'vng1'; resourceGroup = $rg; subscriptionId = $subId }
        )

        Mock Invoke-WAFQuery {
            param([string[]] $SubscriptionIds, [string] $Query)

            if ($Query -match '(?i)microsoft\.network/virtualnetworks' -and $Query -match '(?i)mv-expand\s+sn') {
                return @([pscustomobject]@{ subnetId = $subnetId; vnetId = $vnetId })
            }
            if ($Query -match '(?i)microsoft\.network/virtualnetworks/virtualnetworkpeerings') { return @() }
            if ($Query -match '(?i)microsoft\.network/networkinterfaces') { return @() }
            if ($Query -match '(?i)microsoft\.network/publicipaddresses') {
                return @([pscustomobject]@{ id = $pipId; ipAddress = '1.2.3.4'; fqdn = 'pip1.example.com' })
            }
            if ($Query -match '(?i)microsoft\.network/virtualnetworkgateways') { return @() }
            if ($Query -match '(?i)microsoft\.network/connections') { return @() }
            return @()
        } -ModuleName utils

        . $AzFallbackPrereqs -SubscriptionId $subId -ExtraCommands @('Get-AzVirtualNetworkGateway')

        Mock Get-AzVirtualNetworkGateway {
            param([string] $ResourceGroupName, [string] $Name)

            return [pscustomobject]@{
                Id = $vngId
                Name = 'vng1'
                Location = 'eastus'
                GatewayType = 'ExpressRoute'
                IpConfigurations = @(
                    [pscustomobject]@{
                        Subnet = [pscustomobject]@{ Id = $subnetId }
                        PublicIpAddress = [pscustomobject]@{ Id = $pipId }
                        PrivateIpAddress = '10.0.3.4'
                    }
                )
            }
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @($subId)

        $gw = $result | Select-Object -First 1
        $gw.topology_gatewayType | Should -BeExactly 'ExpressRoute'
        $gw.topology_subnetIds | Should -Match ([regex]::Escape($subnetId))
        $gw.topology_vnetIds | Should -Match ([regex]::Escape($vnetId))
        $gw.topology_publicIpIds | Should -Match ([regex]::Escape($pipId))
        Assert-MockCalled Get-AzVirtualNetworkGateway -ModuleName utils -Times 1
    }

    It 'Should fallback to Az.Network for ExpressRoute connections when ARG returns empty' {
        $subId = '11111111-1111-1111-1111-111111111111'
        $rg = 'rg'

        $vngId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworkGateways/vng1"
        $circuitId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/expressRouteCircuits/er1"
        $connId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/connections/conn1"

        $inventory = @(
            [pscustomobject]@{ id = $vngId; type = 'microsoft.network/virtualnetworkgateways'; name = 'vng1'; resourceGroup = $rg; subscriptionId = $subId },
            [pscustomobject]@{ id = $circuitId; type = 'microsoft.network/expressroutecircuits'; name = 'er1'; resourceGroup = $rg; subscriptionId = $subId },
            [pscustomobject]@{ id = $connId; type = 'microsoft.network/connections'; name = 'conn1'; resourceGroup = $rg; subscriptionId = $subId }
        )

        Mock Invoke-WAFQuery {
            param([string[]] $SubscriptionIds, [string] $Query)

            if ($Query -match '(?i)microsoft\.network/virtualnetworks' -and $Query -match '(?i)mv-expand\s+sn') { return @() }
            if ($Query -match '(?i)microsoft\.network/virtualnetworks/virtualnetworkpeerings') { return @() }
            if ($Query -match '(?i)microsoft\.network/networkinterfaces') { return @() }
            if ($Query -match '(?i)microsoft\.network/publicipaddresses') { return @() }
            if ($Query -match '(?i)microsoft\.network/privateendpoints') { return @() }
            if ($Query -match '(?i)microsoft\.web/sites') { return @() }

            if ($Query -match '(?i)microsoft\.network/virtualnetworkgateways') {
                return @(
                    [pscustomobject]@{ id = $vngId; gatewayType = 'ExpressRoute'; subnetIds = @(); publicIpIds = @(); privateIps = @() }
                )
            }
            if ($Query -match '(?i)microsoft\.network/expressroutecircuits') { return @() }
            if ($Query -match '(?i)microsoft\.network/connections') { return @() }

            return @()
        } -ModuleName utils

        . $AzFallbackPrereqs -SubscriptionId $subId -ExtraCommands @('Get-AzVirtualNetworkGatewayConnection')

        Mock Get-AzVirtualNetworkGatewayConnection {
            param([string] $ResourceGroupName, [string] $Name)

            return [pscustomobject]@{
                Id = $connId
                Name = 'conn1'
                Location = 'eastus'
                ConnectionType = 'ExpressRoute'
                VirtualNetworkGateway1 = [pscustomobject]@{ Id = $vngId }
                ExpressRouteCircuit = [pscustomobject]@{ Id = $circuitId }
            }
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @($subId)

        Assert-MockCalled Get-AzVirtualNetworkGatewayConnection -ModuleName utils -Times 1

        $gw = $result | Where-Object { $_.id -eq $vngId } | Select-Object -First 1
        $er = $result | Where-Object { $_.id -eq $circuitId } | Select-Object -First 1

        $gw.topology_expressRouteCircuitIds | Should -Match ([regex]::Escape($circuitId))
        $er.topology_expressRouteGatewayIds | Should -Match ([regex]::Escape($vngId))
    }

    It 'Should fallback to Az.Network for ExpressRoute circuit list when ARG returns empty' {
        $subId = '11111111-1111-1111-1111-111111111111'
        $rg = 'rg'
        $circuitId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/expressRouteCircuits/er1"

        $inventory = @(
            [pscustomobject]@{ id = $circuitId; type = 'microsoft.network/expressroutecircuits'; name = 'er1'; resourceGroup = $rg; subscriptionId = $subId }
        )

        Mock Invoke-WAFQuery {
            param([string[]] $SubscriptionIds, [string] $Query)

            if ($Query -match '(?i)microsoft\.network/virtualnetworks' -and $Query -match '(?i)mv-expand\s+sn') { return @() }
            if ($Query -match '(?i)microsoft\.network/virtualnetworks/virtualnetworkpeerings') { return @() }
            if ($Query -match '(?i)microsoft\.network/networkinterfaces') { return @() }
            if ($Query -match '(?i)microsoft\.network/publicipaddresses') { return @() }
            if ($Query -match '(?i)microsoft\.network/privateendpoints') { return @() }
            if ($Query -match '(?i)microsoft\.web/sites') { return @() }

            if ($Query -match '(?i)microsoft\.network/virtualnetworkgateways') { return @() }
            if ($Query -match '(?i)microsoft\.network/expressroutecircuits') { return @() }
            if ($Query -match '(?i)microsoft\.network/connections') { return @() }

            return @()
        } -ModuleName utils

        . $AzFallbackPrereqs -SubscriptionId $subId -ExtraCommands @('Get-AzExpressRouteCircuit')

        Mock Get-AzExpressRouteCircuit {
            param([string] $ResourceGroupName, [string] $Name)

            return [pscustomobject]@{
                Id = $circuitId
                Name = 'er1'
                Location = 'eastus'
            }
        } -ModuleName utils

        Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @($subId) | Out-Null
        Assert-MockCalled Get-AzExpressRouteCircuit -ModuleName utils -Times 1
    }

    It 'Should enrich NAT Gateway networking relationships' {
        $subId = '11111111-1111-1111-1111-111111111111'
        $rg = 'rg'

        $subnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA/subnets/default"
        $vnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/vnetA"
        $pipId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/pip1"
        $pipPrefixId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/publicIPPrefixes/pfx1"
        $natId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/natGateways/nat1"

        $inventory = @(
            [pscustomobject]@{ id = $natId; type = 'microsoft.network/natgateways'; name = 'nat1' }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ($Query -match '(?i)microsoft\.network/virtualnetworks' -and $Query -match '(?i)mv-expand\s+sn') {
                return @(
                    [pscustomobject]@{ subnetId = $subnetId; vnetId = $vnetId }
                )
            }

            if ($Query -match '(?i)microsoft\.network/virtualnetworks/virtualnetworkpeerings') { return @() }
            if ($Query -match '(?i)microsoft\.network/networkinterfaces') { return @() }
            if ($Query -match '(?i)microsoft\.network/publicipaddresses') {
                return @(
                    [pscustomobject]@{ id = $pipId; ipAddress = '1.2.3.4'; fqdn = 'pip1.example.com' }
                )
            }

            if ($Query -match '(?i)microsoft\.network/natgateways') {
                return @(
                    [pscustomobject]@{
                        id = $natId
                        subnetIds = @($subnetId)
                        publicIpIds = @($pipId)
                        publicIpPrefixIds = @($pipPrefixId)
                    }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @($subId)

        $result[0].topology_subnetIds | Should -Match ([regex]::Escape($subnetId))
        $result[0].topology_vnetIds | Should -Match ([regex]::Escape($vnetId))
        $result[0].topology_publicIpIds | Should -Match ([regex]::Escape($pipId))
        $result[0].topology_publicIpPrefixIds | Should -Match ([regex]::Escape($pipPrefixId))
    }
}
