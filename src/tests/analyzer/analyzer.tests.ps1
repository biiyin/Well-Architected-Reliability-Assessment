Describe 'WARA Analyzer - offline artifact fallback' {
    BeforeAll {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..')).Path
        $script:analyzerScript = Join-Path -Path $repoRoot -ChildPath 'src\modules\wara\analyzer\2_wara_data_analyzer.ps1'
        $script:expertTemplate = Join-Path -Path $repoRoot -ChildPath 'src\modules\wara\analyzer\Expert-Analysis-v1.xlsx'

        if (-not (Test-Path -LiteralPath $script:analyzerScript -PathType Leaf)) {
            throw "Analyzer script not found: $script:analyzerScript"
        }
        if (-not (Test-Path -LiteralPath $script:expertTemplate -PathType Leaf)) {
            throw "Expert analysis template not found: $script:expertTemplate"
        }
    }

    It 'Uses local WARAinScopeResTypes.csv when remote fetch fails' {
        $jsonPath = Join-Path -Path $TestDrive -ChildPath 'input.json'

        $jsonObject = [pscustomobject]@{
            ScriptDetails     = [pscustomobject]@{ Version = 'test' }
            ImpactedResources = @()
            Outages           = @()
            SupportTickets    = @()
            resourceInventory = @(
                [pscustomobject]@{
                    id             = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttest'
                    type           = 'Microsoft.Storage/storageAccounts'
                    name           = 'sttest'
                    location       = 'eastus'
                    subscriptionId = '00000000-0000-0000-0000-000000000000'
                    resourceGroup  = 'rg-test'
                }
            )
        }

        $jsonObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding utf8

        $script:usedLocalTypes = $false

        # Prevent the script from trying to install ImportExcel during tests.
        Mock Get-Module { [pscustomobject]@{ Name = 'ImportExcel' } } -ParameterFilter { $Name -eq 'ImportExcel' -and $ListAvailable }
        Mock Install-Module { } -ParameterFilter { $Name -eq 'ImportExcel' }

        # Force the remote download to fail and verify we used local data.
        Mock Invoke-RestMethod { throw [System.Net.WebException]::new('offline') } -ParameterFilter { $Uri -eq 'https://azure.github.io/WARA-Build/objects/WARAinScopeResTypes.csv' }

        Mock Get-Content {
            $script:usedLocalTypes = $true

            # The analyzer expects CSV text when using -Raw.
            return "ResourceType,InAprlAndOrAdvisor`nMicrosoft.Storage/storageAccounts,yes`n"
        } -ParameterFilter {
            (($LiteralPath -and ($LiteralPath -match 'WARAinScopeResTypes\.csv$')) -or ($Path -and ($Path -match 'WARAinScopeResTypes\.csv$')))
        }

        # Stop after the fallback is exercised (we don't want to execute full Excel generation in unit tests).
        Mock Open-ExcelPackage { throw 'StopTest' }

        # Run in the current scope so mocks apply. The script may trap/throw; ignore the intentional StopTest.
        try {
            . $script:analyzerScript -JSONFile $jsonPath -ExpertAnalysisFile $script:expertTemplate | Out-Null
        }
        catch {
            if ($_.Exception.Message -ne 'StopTest') {
                throw
            }
        }

        Assert-MockCalled Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq 'https://azure.github.io/WARA-Build/objects/WARAinScopeResTypes.csv' }
        $script:usedLocalTypes | Should -BeTrue
    }
}
