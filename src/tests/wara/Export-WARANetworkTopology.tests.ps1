Describe 'Export-WARANetworkTopology Mermaid diagram' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '../../..')
        $scriptPath = Join-Path -Path $repoRoot -ChildPath 'tools/Export-WARANetworkTopology.ps1'

        # Dot-source with a dummy InputPath to satisfy the script's parameter binding.
        . $scriptPath -InputPath '.'
    }

    It 'Should not emit networkinterfaces nodes/edges in Mermaid' {
        $vnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet1'
        $subnetId = "$vnetId/subnets/default"

        $groupSummaries = @(
            [pscustomobject]@{
                groupId = 'g-vm'
                resourceType = 'microsoft.compute/virtualmachines'
                count = 1
                sampleName = 'vm1'
                sampleResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                vnetIds = @($vnetId)
                subnetIds = @($subnetId)
                subnetPrefixPairs = $null
                privateLinkTargetIds = @()
                publicIpIds = @()
                publicIps = @('1.2.3.4')
                publicFqdns = @()
                publicNetworkAccess = $null
                privateEndpointIds = @()
                privateEndpointSubnetIds = @()
                privateEndpointVnetIds = @()
                internetConnected = $true
            }
            [pscustomobject]@{
                groupId = 'g-nic'
                resourceType = 'microsoft.network/networkinterfaces'
                count = 1
                sampleName = 'nic1'
                sampleResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic1'
                vnetIds = @($vnetId)
                subnetIds = @($subnetId)
                subnetPrefixPairs = $null
                privateLinkTargetIds = @()
                publicIpIds = @()
                publicIps = @('1.2.3.4')
                publicFqdns = @()
                publicNetworkAccess = $null
                privateEndpointIds = @()
                privateEndpointSubnetIds = @()
                privateEndpointVnetIds = @()
                internetConnected = $true
            }
        )

        $dummyInventory = @(
            [pscustomobject]@{ type = ''; id = '' }
        )
        $lines = Get-HighLevelMermaidDiagramLines -InventorySubset $dummyInventory -GroupSummaries $groupSummaries -ResourceIdToGroupNodeId @{} -DiagramTitle 'Resource Group: rg'
        $text = ($lines -join "`n")

        $text | Should -Match 'vm1'
        $text | Should -Match 'microsoft\.compute/virtualmachines'
        $text | Should -Match '\|1\.2\.3\.4\|'
        $text | Should -Not -Match 'networkinterfaces'
        $text | Should -Not -Match 'nic1'
    }

    It 'Should still emit Mermaid when GroupSummaries is passed as a single List' {
        $vnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet1'
        $subnetId = "$vnetId/subnets/default"

        $list = [System.Collections.Generic.List[object]]::new()
        $list.Add([pscustomobject]@{
            groupId = 'g-vm'
            resourceType = 'microsoft.compute/virtualmachines'
            count = 1
            sampleName = 'vm1'
            sampleResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            vnetIds = @($vnetId)
            subnetIds = @($subnetId)
            subnetPrefixPairs = $null
            privateLinkTargetIds = @()
            publicIpIds = @()
            publicIps = @('1.2.3.4')
            publicFqdns = @()
            publicNetworkAccess = $null
            privateEndpointIds = @()
            privateEndpointSubnetIds = @()
            privateEndpointVnetIds = @()
            internetConnected = $true
        })

        $dummyInventory = @([pscustomobject]@{ type = ''; id = '' })

        # NOTE: The leading comma forces the list to be passed as a single element,
        # which previously resulted in an empty diagram.
        $lines = Get-HighLevelMermaidDiagramLines -InventorySubset $dummyInventory -GroupSummaries (, $list) -ResourceIdToGroupNodeId @{} -DiagramTitle ''

        ($lines -join "`n") | Should -Match '```mermaid'
        ($lines -join "`n") | Should -Match 'vm1'
    }

    It 'Should emit allowed network resources in Mermaid when they have VNet connectivity' {
        $vnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet1'
        $subnetId = "$vnetId/subnets/default"

        $allowedNetworkTypes = @(
            'microsoft.network/loadbalancers',
            'microsoft.network/applicationgateways',
            'microsoft.network/virtualnetworkgateways',
            'microsoft.network/natgateways',
            'microsoft.network/azurefirewalls'
        )

        foreach ($rt in $allowedNetworkTypes) {
            $groupSummaries = @(
                [pscustomobject]@{
                    groupId = "g-$rt"
                    resourceType = $rt
                    count = 1
                    sampleName = 'net1'
                    sampleResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/dummy/net1'
                    vnetIds = @($vnetId)
                    subnetIds = @($subnetId)
                    subnetPrefixPairs = $null
                    privateLinkTargetIds = @()
                    publicIpIds = @()
                    publicIps = @()
                    publicFqdns = @()
                    publicNetworkAccess = $null
                    privateEndpointIds = @()
                    privateEndpointSubnetIds = @()
                    privateEndpointVnetIds = @()
                    internetConnected = $false
                }
            )

            $dummyInventory = @([pscustomobject]@{ type = ''; id = '' })
            $lines = Get-HighLevelMermaidDiagramLines -InventorySubset $dummyInventory -GroupSummaries $groupSummaries -ResourceIdToGroupNodeId @{} -DiagramTitle ''
            $text = ($lines -join "`n")

            $text | Should -Match ([regex]::Escape($rt))
            $text | Should -Match 'vnet1'
        }
    }

    It 'Default should emit Mermaid diagrams by Resource Group' {
        $repoRoot = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '../../..')
        $scriptPath = Join-Path -Path $repoRoot -ChildPath 'tools/Export-WARANetworkTopology.ps1'
        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source

        $subId = '00000000-0000-0000-0000-000000000000'
        $vnet1 = "/subscriptions/$subId/resourceGroups/rg1/providers/Microsoft.Network/virtualNetworks/vnet1"
        $vnet2 = "/subscriptions/$subId/resourceGroups/rg2/providers/Microsoft.Network/virtualNetworks/vnet2"

        $jsonPath = Join-Path -Path $TestDrive -ChildPath 'input.json'
        $mdPath = Join-Path -Path $TestDrive -ChildPath 'out.md'

        $payload = [pscustomobject]@{
            resourceInventory = @(
                [pscustomobject]@{
                    id = "/subscriptions/$subId/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1"
                    name = 'vm1'
                    type = 'microsoft.compute/virtualmachines'
                    resourceGroup = 'rg1'
                    location = 'eastus'
                    topology_vnetIds = @($vnet1)
                    topology_subnetIds = @("$vnet1/subnets/default")
                }
                [pscustomobject]@{
                    id = "/subscriptions/$subId/resourceGroups/rg2/providers/Microsoft.Compute/virtualMachines/vm2"
                    name = 'vm2'
                    type = 'microsoft.compute/virtualmachines'
                    resourceGroup = 'rg2'
                    location = 'eastus'
                    topology_vnetIds = @($vnet2)
                    topology_subnetIds = @("$vnet2/subnets/default")
                }
            )
        }

        $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

        & $pwsh -NoProfile -File $scriptPath -InputPath $jsonPath -OutputMd $mdPath | Out-Null

        $md = Get-Content -LiteralPath $mdPath -Raw
        $md | Should -Match '## Mermaid Topology Diagram \(By Resource Group\)'
        $md | Should -Match '### Resource Group: rg1'
        $md | Should -Match '### Resource Group: rg2'
    }

    It 'MergeMermaidDiagrams should emit a single High-level Mermaid diagram' {
        $repoRoot = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '../../..')
        $scriptPath = Join-Path -Path $repoRoot -ChildPath 'tools/Export-WARANetworkTopology.ps1'
        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source

        $subId = '00000000-0000-0000-0000-000000000000'
        $vnet1 = "/subscriptions/$subId/resourceGroups/rg1/providers/Microsoft.Network/virtualNetworks/vnet1"

        $jsonPath = Join-Path -Path $TestDrive -ChildPath 'input2.json'
        $mdPath = Join-Path -Path $TestDrive -ChildPath 'out2.md'

        $payload = [pscustomobject]@{
            resourceInventory = @(
                [pscustomobject]@{
                    id = "/subscriptions/$subId/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1"
                    name = 'vm1'
                    type = 'microsoft.compute/virtualmachines'
                    resourceGroup = 'rg1'
                    location = 'eastus'
                    topology_vnetIds = @($vnet1)
                    topology_subnetIds = @("$vnet1/subnets/default")
                }
            )
        }

        $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

        & $pwsh -NoProfile -File $scriptPath -InputPath $jsonPath -OutputMd $mdPath -MergeMermaidDiagrams | Out-Null

        $md = Get-Content -LiteralPath $mdPath -Raw
        $md | Should -Match '## Mermaid Topology Diagram \(High-level\)'
        $md | Should -Not -Match '### Resource Group:'
    }

    It 'Should collapse peering-only VNets when peering count exceeds threshold' {
        $subId = '00000000-0000-0000-0000-000000000000'
        $hub = "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/hub"
        $spokes = 1..4 | ForEach-Object { "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke$_" }

        $inventory = @(
            [pscustomobject]@{
                type = 'microsoft.network/virtualnetworks'
                id   = $hub
                topology_vnetPeeringRemoteVnetIds = @($spokes)
            }
        )

        $dummyGroupSummaries = @(
            [pscustomobject]@{
                groupId = 'g-dummy'
                resourceType = 'dummy'
                count = 1
                sampleName = ''
                sampleResourceId = ''
                vnetIds = @()
                subnetIds = @()
                subnetPrefixPairs = $null
                privateLinkTargetIds = @()
                publicIpIds = @()
                publicIps = @()
                publicFqdns = @()
                publicNetworkAccess = $null
                privateEndpointIds = @()
                privateEndpointSubnetIds = @()
                privateEndpointVnetIds = @()
                internetConnected = $false
            }
        )

        $lines = Get-HighLevelMermaidDiagramLines -InventorySubset $inventory -GroupSummaries $dummyGroupSummaries -ResourceIdToGroupNodeId @{} -DiagramTitle ''
        $text = ($lines -join "`n")

        $text | Should -Match 'Peering VNets \(x4\)'
        foreach ($s in $spokes) {
            $text | Should -Not -Match ([regex]::Escape((Split-Path -Leaf $s)))
        }
    }

    It 'Should only collapse the peering-only subset when one peered VNet has non-peering connectivity' {
        $subId = '00000000-0000-0000-0000-000000000000'
        $hub = "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/hub"
        $spokes = 1..4 | ForEach-Object { "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke$_" }
        $subnetForSpoke1 = "$($spokes[0])/subnets/default"

        $inventory = @(
            [pscustomobject]@{
                type = 'microsoft.network/virtualnetworks'
                id   = $hub
                topology_vnetPeeringRemoteVnetIds = @($spokes)
            }
        )

        # Simulate a workload connected to spoke1 so it is not peering-only.
        $groupSummaries = @(
            [pscustomobject]@{
                groupId = 'g-vm'
                resourceType = 'microsoft.compute/virtualmachines'
                count = 1
                sampleName = 'vm-spoke1'
                sampleResourceId = "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-spoke1"
                vnetIds = @($spokes[0])
                subnetIds = @($subnetForSpoke1)
                subnetPrefixPairs = $null
                privateLinkTargetIds = @()
                publicIpIds = @()
                publicIps = @()
                publicFqdns = @()
                publicNetworkAccess = $null
                privateEndpointIds = @()
                privateEndpointSubnetIds = @()
                privateEndpointVnetIds = @()
                internetConnected = $false
            }
        )

        $lines = Get-HighLevelMermaidDiagramLines -InventorySubset $inventory -GroupSummaries $groupSummaries -ResourceIdToGroupNodeId @{} -DiagramTitle ''
        $text = ($lines -join "`n")

        # spoke1 is not peering-only (it has a VM group connected), so it must remain as a normal VNet.
        $text | Should -Match 'spoke1'

        # The remaining 3 spokes are peering-only and share the same neighbor set, so they should collapse.
        $text | Should -Match 'Peering VNets \(x3\)'
        $text | Should -Not -Match 'spoke2'
        $text | Should -Not -Match 'spoke3'
        $text | Should -Not -Match 'spoke4'
    }

    It 'Should collapse peering-only VNets even when they also peer to another VNet' {
        $subId = '00000000-0000-0000-0000-000000000000'
        $hub1 = "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/hub1"
        $hub2 = "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/hub2"
        $spokes = 1..4 | ForEach-Object { "/subscriptions/$subId/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke$_" }

        $inventory = @(
            [pscustomobject]@{
                type = 'microsoft.network/virtualnetworks'
                id   = $hub1
                topology_vnetPeeringRemoteVnetIds = @($spokes)
            },
            [pscustomobject]@{
                type = 'microsoft.network/virtualnetworks'
                id   = $hub2
                topology_vnetPeeringRemoteVnetIds = @($spokes)
            }
        )

        $dummyGroupSummaries = @(
            [pscustomobject]@{
                groupId = 'g-dummy'
                resourceType = 'dummy'
                count = 1
                sampleName = ''
                sampleResourceId = ''
                vnetIds = @()
                subnetIds = @()
                subnetPrefixPairs = $null
                privateLinkTargetIds = @()
                publicIpIds = @()
                publicIps = @()
                publicFqdns = @()
                publicNetworkAccess = $null
                privateEndpointIds = @()
                privateEndpointSubnetIds = @()
                privateEndpointVnetIds = @()
                internetConnected = $false
            }
        )

        $lines = Get-HighLevelMermaidDiagramLines -InventorySubset $inventory -GroupSummaries $dummyGroupSummaries -ResourceIdToGroupNodeId @{} -DiagramTitle ''
        $text = ($lines -join "`n")

        $text | Should -Match 'Peering VNets \(x4\)'
        $text | Should -Match 'hub1'
        $text | Should -Match 'hub2'
        foreach ($s in $spokes) {
            $text | Should -Not -Match ([regex]::Escape((Split-Path -Leaf $s)))
        }
    }
}
