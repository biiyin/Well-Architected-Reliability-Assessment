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
}
