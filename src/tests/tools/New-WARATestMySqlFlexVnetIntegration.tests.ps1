BeforeAll {
    Set-StrictMode -Version Latest

    # Provide placeholder commands so Pester can Mock even if Az modules are not loaded.
    function Connect-AzAccount { }
    function Set-AzContext { }
    function New-AzResourceGroup { }
    function New-AzResourceGroupDeployment { }

    $script:toolScriptPath = Join-Path $PSScriptRoot '..\..\..\tools\New-WARATestMySqlFlexVnetIntegration.ps1'
}

Describe 'tools/New-WARATestMySqlFlexVnetIntegration.ps1' {
    It 'Should compute a configfile resource group line in -WhatIf mode (no Azure calls)' {
        Mock Connect-AzAccount { throw 'Should not be called under -WhatIf' }
        Mock Set-AzContext { throw 'Should not be called under -WhatIf' }
        Mock New-AzResourceGroup { throw 'Should not be called under -WhatIf' }
        Mock New-AzResourceGroupDeployment { throw 'Should not be called under -WhatIf' }

        $pw = ConvertTo-SecureString 'P@ssw0rd-For-Test-Only!' -AsPlainText -Force

        $result = & $script:toolScriptPath -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -AdministratorPassword $pw -WhatIf -PassThru

        $result.AzureEnvironment | Should -Be 'AzureChinaCloud'
        $result.ConfigFileResourceGroupLine | Should -Match '^/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/wara-mysql-vnet-test-'

        Assert-MockCalled Connect-AzAccount -Times 0
        Assert-MockCalled Set-AzContext -Times 0
        Assert-MockCalled New-AzResourceGroup -Times 0
        Assert-MockCalled New-AzResourceGroupDeployment -Times 0
    }
}
