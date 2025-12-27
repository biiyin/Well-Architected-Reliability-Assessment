BeforeAll {
    $modulePath = "$PSScriptRoot/../../modules/wara/utils/utils.psd1"
    Import-Module -Name $modulePath -Force
}

Describe 'Add-WAFResourceTopology - PostgreSQL Flexible Server publicNetworkAccess enrichment' {
    It 'Should backfill topology_publicNetworkAccess when ARG returns a value' {
        $pgId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg1'

        $inventory = @(
            [pscustomobject]@{
                id            = $pgId
                type          = 'microsoft.dbforpostgresql/flexibleservers'
                name          = 'pg1'
                resourceGroup = 'rg'
            }
        )

        $script:capturedQueries = New-Object System.Collections.Generic.List[string]

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            $script:capturedQueries.Add([string]$Query)

            if ($Query -match '(?i)microsoft\.dbforpostgresql/flexibleservers') {
                return @(
                    [pscustomobject]@{
                        id                = $pgId
                        name              = 'pg1'
                        subscriptionId    = '11111111-1111-1111-1111-111111111111'
                        resourceGroup     = 'rg'
                        location          = 'eastus'
                        publicNetworkAccess = 'Enabled'
                    }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        $result | Should -Not -BeNullOrEmpty
        $result[0].topology_publicNetworkAccess | Should -BeExactly 'Enabled'

        ($script:capturedQueries | Where-Object { $_ -match '(?i)microsoft\.dbforpostgresql/flexibleservers' }).Count | Should -BeGreaterThan 0
    }

    It 'Should not overwrite topology_publicNetworkAccess when it already has a value' {
        $pgId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg1'

        $inventory = @(
            [pscustomobject]@{
                id                        = $pgId
                type                      = 'microsoft.dbforpostgresql/flexibleservers'
                name                      = 'pg1'
                resourceGroup             = 'rg'
                topology_publicNetworkAccess = 'Disabled'
            }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ($Query -match '(?i)microsoft\.dbforpostgresql/flexibleservers') {
                return @(
                    [pscustomobject]@{
                        id                 = $pgId
                        publicNetworkAccess = 'Enabled'
                    }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        $result[0].topology_publicNetworkAccess | Should -BeExactly 'Disabled'
    }

    It 'Should keep topology_publicNetworkAccess empty when ARG returns no matching resource' {
        $pgId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg1'

        $inventory = @(
            [pscustomobject]@{
                id            = $pgId
                type          = 'microsoft.dbforpostgresql/flexibleservers'
                name          = 'pg1'
                resourceGroup = 'rg'
            }
        )

        Mock Invoke-WAFQuery { return @() } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        $result[0].PSObject.Properties.Name | Should -Contain 'topology_publicNetworkAccess'
        $result[0].topology_publicNetworkAccess | Should -BeNullOrEmpty
    }
}
