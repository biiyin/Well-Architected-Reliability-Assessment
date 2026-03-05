Describe 'tools/Test-WARAResourceGraphQuery.ps1' {
    It 'Should call Search-AzGraph with Subscription scope when SubscriptionIds provided' {
        $toolPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\tools\Test-WARAResourceGraphQuery.ps1'
        $toolPath = (Resolve-Path -LiteralPath $toolPath).Path

        $queryPath = Join-Path -Path $TestDrive -ChildPath 'q.kql'
        Set-Content -LiteralPath $queryPath -Value "resources | project id" -Encoding utf8

        Mock Import-Module { } -Verifiable
        Mock Get-AzContext { [pscustomobject]@{} }
        Mock Connect-AzAccount { } -Verifiable

        Mock Search-AzGraph {
            [pscustomobject]@{ Data = @(); SkipToken = $null }
        } -Verifiable -RemoveParameterValidation @('Subscription', 'UseTenantScope')

        & $toolPath -AzureEnvironment AzureChinaCloud -TenantId ([guid]::NewGuid()) -SubscriptionIds @('11111111-1111-1111-1111-111111111111') -QueryPath $queryPath -First 5 | Out-Null

        Assert-MockCalled Search-AzGraph -Times 1 -ParameterFilter { $Subscription -and -not $UseTenantScope -and $First -eq 5 }
    }

    It 'Should call Search-AzGraph with tenant scope when SubscriptionIds omitted' {
        $toolPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\tools\Test-WARAResourceGraphQuery.ps1'
        $toolPath = (Resolve-Path -LiteralPath $toolPath).Path

        $queryPath = Join-Path -Path $TestDrive -ChildPath 'q.kql'
        Set-Content -LiteralPath $queryPath -Value "resources | project id" -Encoding utf8

        Mock Import-Module { }
        Mock Get-AzContext { [pscustomobject]@{} }
        Mock Connect-AzAccount { } -Verifiable

        Mock Search-AzGraph {
            [pscustomobject]@{ Data = @(); SkipToken = $null }
        } -Verifiable -RemoveParameterValidation @('Subscription', 'UseTenantScope')

        & $toolPath -AzureEnvironment AzureChinaCloud -TenantId ([guid]::NewGuid()) -QueryPath $queryPath -First 7 | Out-Null

        Assert-MockCalled Search-AzGraph -Times 1 -ParameterFilter { $UseTenantScope -and (-not $Subscription) -and $First -eq 7 }
    }
}
