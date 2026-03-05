BeforeAll {
    $modulePath = "$PSScriptRoot/../../modules/wara/utils/utils.psd1"
    Import-Module -Name $modulePath -Force
}

Describe 'Add-WAFResourceTopology - App Service SKU backfill' {
    It 'Should backfill sku for microsoft.web/sites when missing using the associated serverfarm sku' {
        $siteId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Web/sites/site1'
        $aspId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Web/serverfarms/asp1'

        $inventory = @(
            [pscustomobject]@{
                id            = $siteId
                type          = 'microsoft.web/sites'
                name          = 'site1'
                resourceGroup = 'rg'
                sku           = $null
            }
        )

        $script:capturedQueries = New-Object System.Collections.Generic.List[string]

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            $script:capturedQueries.Add([string]$Query)

            if ($Query -match '(?i)microsoft\.web/sites') {
                return @(
                    [pscustomobject]@{
                        id                 = $siteId
                        name               = 'site1'
                        subscriptionId     = '11111111-1111-1111-1111-111111111111'
                        resourceGroup      = 'rg'
                        location           = 'eastus'
                        vnetSubnetId       = $null
                        publicNetworkAccess = 'Enabled'
                        serverFarmId       = $aspId
                    }
                )
            }

            if ($Query -match '(?i)microsoft\.web/serverfarms') {
                return @(
                    [pscustomobject]@{
                        id  = $aspId
                        sku = "name=P1v3;`ntier=PremiumV3;`ncapacity=2;"
                    }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        $result | Should -Not -BeNullOrEmpty
        $result[0].sku | Should -Match '(?m)^name=P1v3;\s*$'
        $result[0].sku | Should -Match '(?m)^tier=PremiumV3;\s*$'
        $result[0].sku | Should -Match '(?m)^capacity=2;\s*$'

        ($script:capturedQueries | Where-Object { $_ -match '(?i)microsoft\.web/serverfarms' }).Count | Should -BeGreaterThan 0
    }

    It 'Should not overwrite sku for microsoft.web/sites when sku already has a value' {
        $siteId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Web/sites/site1'
        $aspId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Web/serverfarms/asp1'

        $inventory = @(
            [pscustomobject]@{
                id            = $siteId
                type          = 'microsoft.web/sites'
                name          = 'site1'
                resourceGroup = 'rg'
                sku           = "name=S1;`ntier=Standard;`n"
            }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ($Query -match '(?i)microsoft\.web/sites') {
                return @(
                    [pscustomobject]@{
                        id           = $siteId
                        serverFarmId = $aspId
                        publicNetworkAccess = 'Enabled'
                    }
                )
            }

            if ($Query -match '(?i)microsoft\.web/serverfarms') {
                return @(
                    [pscustomobject]@{
                        id  = $aspId
                        sku = "name=P1v3;`ntier=PremiumV3;`ncapacity=2;"
                    }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        $result[0].sku | Should -Match '(?m)^name=S1;\s*$'
        $result[0].sku | Should -Not -Match '(?m)^name=P1v3;\s*$'
    }

    It 'Should keep sku empty when serverFarmId is missing or serverfarm lookup fails' {
        $siteId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Web/sites/site1'

        $inventory = @(
            [pscustomobject]@{
                id            = $siteId
                type          = 'microsoft.web/sites'
                name          = 'site1'
                resourceGroup = 'rg'
                sku           = $null
            }
        )

        Mock Invoke-WAFQuery {
            param(
                [string[]] $SubscriptionIds,
                [string] $Query
            )

            if ($Query -match '(?i)microsoft\.web/sites') {
                return @(
                    [pscustomobject]@{
                        id = $siteId
                        serverFarmId = ''
                        publicNetworkAccess = 'Enabled'
                    }
                )
            }

            return @()
        } -ModuleName utils

        $result = Add-WAFResourceTopology -ResourceInventory $inventory -SubscriptionIds @('11111111-1111-1111-1111-111111111111')

        $result[0].sku | Should -BeNullOrEmpty
    }
}
