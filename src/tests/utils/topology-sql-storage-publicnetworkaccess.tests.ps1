BeforeAll {
    $modulePath = "$PSScriptRoot/../../modules/wara/utils/utils.psd1"
    $script:utilsModuleName = (Import-Module -Name $modulePath -Force -PassThru).Name
}

Describe 'Add-WAFResourceTopology - Azure SQL publicNetworkAccess enrichment' {
    It 'Should backfill topology_publicNetworkAccess for Microsoft.Sql/servers when ARG returns a value' {
        $sqlId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Sql/servers/proxy'

        $inventory = @(
            [pscustomobject]@{
                id            = $sqlId
                type          = 'microsoft.sql/servers'
                name          = 'proxy'
                resourceGroup = 'rg'
            }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ([string]$Query -like '*microsoft.sql/servers*') {
                return @(
                    [pscustomobject]@{
                        id                 = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Sql/servers/proxy'
                        publicNetworkAccess = 'Enabled'
                    }
                )
            }

            return @()
        } -ModuleName $script:utilsModuleName

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        Assert-MockCalled Invoke-WAFQuery -ModuleName $script:utilsModuleName -Times 1 -ParameterFilter {
            $Query -match '(?i)microsoft\.sql/servers'
        }

        $result | Should -Not -BeNullOrEmpty
        $result[0].topology_publicNetworkAccess | Should -BeExactly 'Enabled'
    }

    It 'Should not overwrite topology_publicNetworkAccess when already set (SQL)' {
        $sqlId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Sql/servers/proxy'

        $inventory = @(
            [pscustomobject]@{
                id                        = $sqlId
                type                      = 'microsoft.sql/servers'
                name                      = 'proxy'
                resourceGroup             = 'rg'
                topology_publicNetworkAccess = 'Disabled'
            }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ([string]$Query -like '*microsoft.sql/servers*') {
                return @(
                    [pscustomobject]@{
                        id                 = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Sql/servers/proxy'
                        publicNetworkAccess = 'Enabled'
                    }
                )
            }

            return @()
        } -ModuleName $script:utilsModuleName

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')
        $result[0].topology_publicNetworkAccess | Should -BeExactly 'Disabled'
    }
}

Describe 'Add-WAFResourceTopology - Storage Account publicNetworkAccess enrichment' {
    It 'Should backfill topology_publicNetworkAccess for Microsoft.Storage/storageAccounts when ARG returns a value' {
        $saId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa1'

        $inventory = @(
            [pscustomobject]@{
                id            = $saId
                type          = 'microsoft.storage/storageaccounts'
                name          = 'sa1'
                resourceGroup = 'rg'
            }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ([string]$Query -like '*microsoft.storage/storageaccounts*') {
                return @(
                    [pscustomobject]@{
                        id                 = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa1'
                        publicNetworkAccess = 'Disabled'
                    }
                )
            }

            return @()
        } -ModuleName $script:utilsModuleName

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        Assert-MockCalled Invoke-WAFQuery -ModuleName $script:utilsModuleName -Times 1 -ParameterFilter {
            $Query -match '(?i)microsoft\.storage/storageaccounts'
        }

        $result | Should -Not -BeNullOrEmpty
        $result[0].topology_publicNetworkAccess | Should -BeExactly 'Disabled'
    }

    It 'Should keep topology_publicNetworkAccess empty for Storage when ARG returns empty value' {
        $saId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa1'

        $inventory = @(
            [pscustomobject]@{
                id            = $saId
                type          = 'microsoft.storage/storageaccounts'
                name          = 'sa1'
                resourceGroup = 'rg'
            }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ([string]$Query -like '*microsoft.storage/storageaccounts*') {
                return @(
                    [pscustomobject]@{
                        id                 = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa1'
                        publicNetworkAccess = ''
                    }
                )
            }

            return @()
        } -ModuleName $script:utilsModuleName

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')
        $result[0].topology_publicNetworkAccess | Should -BeNullOrEmpty
    }
}
