BeforeAll {
    # Import the reports module (contains Start-WARAReport)
    Import-Module -Name "$PSScriptRoot/../../modules/wara/reports/reports.psd1" -Force
}

Describe 'Start-WARAReport - Chinese PPT template selection' {
    BeforeEach {
        # Ensure the version check does not block tests (no network).
        Mock Get-Module {
            [pscustomobject]@{ Version = [version]'99.0.0' }
        } -Module reports

        Mock Find-Module {
            [pscustomobject]@{ Version = [version]'1.0.0' }
        } -Module reports

        $script:capturedParams = $null
        Mock Invoke-WARAReportGenerator {
            param([hashtable] $BoundParameters)
            $script:capturedParams = $BoundParameters
        } -Module reports -Verifiable
    }

    It 'Uses the -zh template when -Chinese is set and -PPTTemplateFile is not provided' {
        Start-WARAReport -ExpertAnalysisFile 'C:\Temp\dummy.xlsx' -Chinese

        Should -InvokeVerifiable
        $script:capturedParams | Should -Not -BeNullOrEmpty
        $script:capturedParams.ContainsKey('Chinese') | Should -BeTrue
        $script:capturedParams.Chinese | Should -BeTrue
        $script:capturedParams.PPTTemplateFile | Should -Match 'Template-zh\.pptx$'
    }

    It 'Does not override -PPTTemplateFile when explicitly provided' {
        Start-WARAReport -ExpertAnalysisFile 'C:\Temp\dummy.xlsx' -Chinese -PPTTemplateFile 'C:\Templates\custom.pptx'

        Should -InvokeVerifiable
        $script:capturedParams.PPTTemplateFile | Should -Be 'C:\Templates\custom.pptx'
    }
}
