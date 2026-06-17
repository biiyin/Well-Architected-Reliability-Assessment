BeforeAll {
    $modulePath = "$PSScriptRoot/../../modules/wara/utils/utils.psd1"
    Import-Module -Name $modulePath -Force
    Import-Module -Name 'Az.Accounts'
}

Describe 'Get-AzureRestMethodUriPath' {
    Context 'When to get an Azure REST API URI path' {
        It 'Should return the path that does contains resource group' {
            $commonCmdletParams = @{
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceGroupName    = 'test-rg'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                Name                 = 'resource1'
                ApiVersion           = '0000-00-00'
            }
            $result = Get-AzureRestMethodUriPath @commonCmdletParams

            $expected = '/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/test-rg/providers/Resource.Provider/resourceType/resource1?api-version=0000-00-00'

            $result | Should -BeExactly $expected
        }

        It 'Should return the path that does contains resource group with query string' {
            $commonCmdletParams = @{
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceGroupName    = 'test-rg'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                Name                 = 'resource1'
                ApiVersion           = '0000-00-00'
                QueryString          = 'test=test'
            }
            $result = Get-AzureRestMethodUriPath @commonCmdletParams

            $expected = '/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/test-rg/providers/Resource.Provider/resourceType/resource1?api-version=0000-00-00&test=test'

            $result | Should -BeExactly $expected
        }

        It 'Should return the path that does not contains resource group' {
            $commonCmdletParams = @{
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                ApiVersion           = '0000-00-00'
            }
            $result = Get-AzureRestMethodUriPath @commonCmdletParams

            $expected = '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Resource.Provider/resourceType?api-version=0000-00-00'

            $result | Should -BeExactly $expected
        }

        It 'Should return the path that does not contains resource group with query string' {
            $commonCmdletParams = @{
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                ApiVersion           = '0000-00-00'
                QueryString          = 'test=test'
            }
            $result = Get-AzureRestMethodUriPath @commonCmdletParams

            $expected = '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Resource.Provider/resourceType?api-version=0000-00-00&test=test'

            $result | Should -BeExactly $expected
        }
    }
}

Describe 'Invoke-AzureRestApi' {
    BeforeAll {
        $expected = 'JsonText'

        Mock Invoke-AzRestMethod {
            return @{ Content = $expected }
        } -ModuleName 'utils' -Verifiable
    }

    Context 'When to invoke an Azure REST API with a path WITH resource group' {
        It 'Should call Get-AzureRestMethodUriPath and Invoke-AzRestMethod then return the response from the Azure REST API' {
            $commonCmdletParams = @{
                Method               = 'GET'
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceGroupName    = 'test-rg'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                Name                 = 'resource1'
                ApiVersion           = '0000-00-00'
            }
            $result = Invoke-AzureRestApi @commonCmdletParams

            Should -InvokeVerifiable
            $result.Content | Should -BeExactly $expected
        }

        It 'Should call Get-AzureRestMethodUriPath and Invoke-AzRestMethod then return the response from the Azure REST API with query string' {
            $commonCmdletParams = @{
                Method               = 'GET'
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceGroupName    = 'test-rg'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                Name                 = 'resource1'
                ApiVersion           = '0000-00-00'
                QueryString          = 'test=test'
            }
            $result = Invoke-AzureRestApi @commonCmdletParams

            Should -InvokeVerifiable
            $result.Content | Should -BeExactly $expected
        }

        It 'Should call Get-AzureRestMethodUriPath and Invoke-AzRestMethod then return the response from the Azure REST API with request body' {
            $commonCmdletParams = @{
                Method               = 'GET'
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceGroupName    = 'test-rg'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                Name                 = 'resource1'
                ApiVersion           = '0000-00-00'
                RequestBody          = 'test'
            }
            $result = Invoke-AzureRestApi @commonCmdletParams

            Should -InvokeVerifiable
            $result.Content | Should -BeExactly $expected
        }

        It 'Should call Get-AzureRestMethodUriPath and Invoke-AzRestMethod then return the response from the Azure REST API with query string and request body' {
            $commonCmdletParams = @{
                Method               = 'GET'
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceGroupName    = 'test-rg'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                Name                 = 'resource1'
                ApiVersion           = '0000-00-00'
                QueryString          = 'test=test'
                RequestBody          = 'test'
            }
            $result = Invoke-AzureRestApi @commonCmdletParams

            Should -InvokeVerifiable
            $result.Content | Should -BeExactly $expected
        }
    }

    Context 'When to invoke an Azure REST API with a path WITHOUT resource group' {
        It 'Should call Get-AzureRestMethodUriPath and Invoke-AzRestMethod then return the response from the Azure REST API' {
            $commonCmdletParams = @{
                Method               = 'GET'
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                ApiVersion           = '0000-00-00'
            }
            $result = Invoke-AzureRestApi @commonCmdletParams

            Should -InvokeVerifiable
            $result.Content | Should -BeExactly $expected
        }

        It 'Should call Get-AzureRestMethodUriPath and Invoke-AzRestMethod then return the response from the Azure REST API with query string' {
            $commonCmdletParams = @{
                Method               = 'GET'
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                ApiVersion           = '0000-00-00'
                QueryString          = 'test=test'
            }
            $result = Invoke-AzureRestApi @commonCmdletParams

            Should -InvokeVerifiable
            $result.Content | Should -BeExactly $expected
        }

        It 'Should call Get-AzureRestMethodUriPath and Invoke-AzRestMethod then return the response from the Azure REST API with request body' {
            $commonCmdletParams = @{
                Method               = 'GET'
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                ApiVersion           = '0000-00-00'
                RequestBody          = 'test'
            }
            $result = Invoke-AzureRestApi @commonCmdletParams

            Should -InvokeVerifiable
            $result.Content | Should -BeExactly $expected
        }

        It 'Should call Get-AzureRestMethodUriPath and Invoke-AzRestMethod then return the response from the Azure REST API with query string and request body' {
            $commonCmdletParams = @{
                Method               = 'GET'
                SubscriptionId       = '11111111-1111-1111-1111-111111111111'
                ResourceProviderName = 'Resource.Provider'
                ResourceType         = 'resourceType'
                ApiVersion           = '0000-00-00'
                QueryString          = 'test=test'
                RequestBody          = 'test'
            }
            $result = Invoke-AzureRestApi @commonCmdletParams

            Should -InvokeVerifiable
            $result.Content | Should -BeExactly $expected
        }
    }
}

Describe Import-WAFConfigFileData {
    Context 'Import a WAF config file with valid and invalid data' {
        It 'Should return the correct content of the WAF config file' {
            # Call the function with the test configuration file

            $testConfigFile1 = "$PSScriptRoot/../data/utils/testconfig1.txt"
            $result = Import-WAFConfigFileData $testConfigFile1

            $expectedTenantId = "12121212-1212-1212-1212-121212121212"
            $expectedSubscriptionIds = @(
                "/subscriptions/0000000-0000-0000-0000-000000000000"
            )
            $expectedResourceGroups = @(
                "/subscriptions/1111111-1111-1111-1111-111111111111/resourceGroups/RG-01",
                "/subscriptions/1111111-1111-1111-1111-111111111111/resourceGroups/RG-02",
                "/subscriptions/1111111-1111-1111-1111-111111111111/resourceGroups/RG-03",
                "/subscriptions/1111111-1111-1111-1111-111111111111/resourceGroups/RG-04",
                "/subscriptions/1111111-1111-1111-1111-111111111111/resourceGroups/RG-05",
                "/subscriptions/1111111-1111-1111-1111-111111111111/resourceGroups/RG-06",
                "/subscriptions/1111111-1111-1111-1111-111111111111/resourceGroups/RG-07",
                "/subscriptions/1111111-1111-1111-1111-111111111111/resourceGroups/RG-08"
            )
            $expectedTags = @(
                "env||environment=~preprod",
                "app||application!~app1||app2"
            )

            # Validate the results
            $result.tenantid | Should -BeExactly $expectedTenantId
            $result.bad1 | Should -BeNullOrEmpty
            $result.subscriptionIds | Should -BeExactly $expectedSubscriptionIds
            $result.resourcegroups | Should -Be $expectedResourceGroups
            $result.tags | Should -BeExactly $expectedTags
        }
    }
}

Describe 'Connect-WAFAzure' {
    Context 'When TenantID is provided' {
        It 'Should call Connect-AzAccount if Get-AzContext returns no context (There is no existing context)' {
            Mock Get-AzContext { return $null } -Verifiable -ModuleName utils
            Mock Connect-AzAccount { @{ } } -Verifiable -ModuleName utils

            $tenantId = [Guid]::NewGuid()
            $azureEnvironment = 'AzureCloud'

            Connect-WAFAzure -TenantID $tenantId -AzureEnvironment $azureEnvironment

            # Verify that Connect-AzAccount was called
            Should -InvokeVerifiable
        }

        It 'Should call Connect-AzAccount if Get-AzContext returns a context of different tenant' {
            Mock Get-AzContext { return @{ Tenant = @{ Id = [Guid]::NewGuid() } } } -Verifiable -ModuleName utils
            Mock Connect-AzAccount { @{ } } -Verifiable -ModuleName utils

            $tenantId = [Guid]::NewGuid()
            $azureEnvironment = 'AzureCloud'

            Connect-WAFAzure -TenantID $tenantId -AzureEnvironment $azureEnvironment

            # Verify that Connect-AzAccount was called
            Should -InvokeVerifiable
        }

        It 'Should call Connect-AzAccount if Get-AzContext returns a context of different environment' {
            $tenantId = [Guid]::NewGuid()
            Mock Get-AzContext {
                return @{
                    Tenant = @{ Id = $tenantId }
                    Environment = @{Name = 'AzureCloud' }
                }
            } -ModuleName utils
            Mock Connect-AzAccount { @{ } } -Verifiable -ModuleName utils


            $azureEnvironment = 'AzureUSGovernment'

            Connect-WAFAzure -TenantID $tenantId -AzureEnvironment $azureEnvironment

            # Verify that Connect-AzAccount was called
            Should -InvokeVerifiable
        }

        It 'Should not call Connect-AzAccount if Get-AzContext returns a context of the same tenant and the same environment' {
            $tenantId = [Guid]::NewGuid()

            Mock Get-AzContext {
                return @{
                    Tenant = @{ Id = $tenantId }
                    Environment = @{Name = 'AzureCloud' }
                }
            } -ModuleName utils
            Mock Connect-AzAccount { @{ } } -Verifiable -ModuleName utils

            Connect-WAFAzure -TenantID $tenantId

            # Verify that Connect-AzAccount was not called
            Should -Not -InvokeVerifiable
        }
    }
}

Describe 'Invoke-WAFQuery' {
    Context 'When Query is not provided' {
        It 'Should project managedBy/sku/plan/zones (and kind) by default' {
            Mock Get-AzContext {
                [pscustomobject]@{ Environment = [pscustomobject]@{ Name = 'AzureCloud' } }
            } -ModuleName utils

            Mock Search-AzGraph {
                param(
                    [string] $Query,
                    [string[]] $Subscription,
                    [string[]] $ManagementGroup,
                    [switch] $UseTenantScope,
                    [switch] $AllowPartialScope,
                    [int] $First,
                    [int] $Skip,
                    [string] $SkipToken,
                    $DefaultProfile,
                    $ErrorAction
                )
                [pscustomobject]@{ Data = @(); SkipToken = $null }
            } -ModuleName utils -RemoveParameterValidation @('Subscription', 'ManagementGroup', 'UseTenantScope', 'AllowPartialScope') -Verifiable

            utils\Invoke-WAFQuery -SubscriptionIds @('11111111-1111-1111-1111-111111111111') | Out-Null

            Assert-MockCalled Search-AzGraph -ModuleName utils -Times 1 -ParameterFilter {
                $Query -match '(?i)\bmanagedBy\b' -and
                $Query -match '(?i)\bsku\b' -and
                $Query -match '(?i)hardwareProfile\.vmSize' -and
                $Query -match '(?i)\bplan\b' -and
                $Query -match '(?i)\bzones\b' -and
                $Query -match '(?i)\bkind\b' -and
                $Query -match '(?i)\bversion\b' -and
                $Query -match '(?i)inventoryVersion'
            }
        }

        It 'Should normalize sku/plan/zones to readable strings' {
            $sku = utils\Format-WAFKeyValueObjectForDisplay -Value ([pscustomobject]@{ name = 'Standard_B1ls'; tier = 'Standard'; capacity = 2 }) -Multiline -TrailingSemicolon
            $plan = utils\Format-WAFKeyValueObjectForDisplay -Value ([pscustomobject]@{ name = 'myPlan'; product = 'myProduct' }) -Multiline -TrailingSemicolon
            $zones = utils\Format-WAFKeyValueObjectForDisplay -Value @('1', '2')

            $sku | Should -Not -Match '^\s*@\{'
            $sku | Should -Match "(?m)^name=Standard_B1ls;\s*$"
            $sku | Should -Match "(?m)^tier=Standard;\s*$"
            $sku | Should -Match "(?m)^capacity=2;\s*$"

            $plan | Should -Not -Match '^\s*@\{'
            $plan | Should -Match "(?m)^name=myPlan;\s*$"

            $zones | Should -BeExactly '1;2'
        }

        It 'Should not overflow call depth for self-referencing objects' {
            $h = @{
                name = 'root'
            }
            $h.self = $h

            { utils\Format-WAFKeyValueObjectForDisplay -Value $h -Multiline -TrailingSemicolon } | Should -Not -Throw

            $s = utils\Format-WAFKeyValueObjectForDisplay -Value $h -Multiline -TrailingSemicolon
            $s | Should -Match '(?m)^name=root;\s*$'
            $s | Should -Match '(?m)^self='
        }

        It 'Should cap depth for deeply nested objects' {
            $deep = [pscustomobject]@{
                a = [pscustomobject]@{
                    b = [pscustomobject]@{
                        c = [pscustomobject]@{
                            d = [pscustomobject]@{ e = 'f' }
                        }
                    }
                }
            }

            { utils\Format-WAFKeyValueObjectForDisplay -Value $deep } | Should -Not -Throw
            $out = utils\Format-WAFKeyValueObjectForDisplay -Value $deep
            $out | Should -Match '^a='
        }

        It 'Should dump a format issue summary when MaxDepth is hit and dump dir is set' {
            $dumpDir = Join-Path -Path $TestDrive -ChildPath 'formatdump'
            New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null
            $env:WARA_DIAGNOSTICS_QUERY_DUMP_DIR = $dumpDir

            $script:lastDumpPath = $null
            $script:lastDumpValue = $null
            Mock Set-Content {
                param(
                    [string] $LiteralPath,
                    [string] $Value,
                    [string] $Encoding
                )
                $script:lastDumpPath = $LiteralPath
                $script:lastDumpValue = $Value
            } -ModuleName utils -Verifiable

            $v = [pscustomobject]@{ a = 1 }
            utils\Format-WAFKeyValueObjectForDisplay -Value $v -MaxDepth 0 -ContextFieldName 'sku' -ContextResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.X/y/z' | Out-Null

            $script:lastDumpPath | Should -Match 'ARG-FormatIssue-\d{8}-\d{6}-\d{3}-sku\.json$'
            $script:lastDumpValue | Should -Match '"Reason"\s*:\s*"MaxDepth"'
            $script:lastDumpValue | Should -Match '"FieldName"\s*:\s*"sku"'
            Assert-MockCalled Set-Content -ModuleName utils -Times 1
        }

        It 'Should dump a format issue summary when a cycle is detected and dump dir is set' {
            $dumpDir = Join-Path -Path $TestDrive -ChildPath 'formatdump2'
            New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null
            $env:WARA_DIAGNOSTICS_QUERY_DUMP_DIR = $dumpDir

            $script:lastDumpPath = $null
            $script:lastDumpValue = $null
            Mock Set-Content {
                param(
                    [string] $LiteralPath,
                    [string] $Value,
                    [string] $Encoding
                )
                $script:lastDumpPath = $LiteralPath
                $script:lastDumpValue = $Value
            } -ModuleName utils -Verifiable

            $h = @{ name = 'root' }
            $h.self = $h

            utils\Format-WAFKeyValueObjectForDisplay -Value $h -ContextFieldName 'plan' -ContextResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.X/y/z' | Out-Null

            $script:lastDumpPath | Should -Match 'ARG-FormatIssue-\d{8}-\d{6}-\d{3}-plan\.json$'
            $script:lastDumpValue | Should -Match '"Reason"\s*:\s*"CycleDetected"'
            $script:lastDumpValue | Should -Match '"FieldName"\s*:\s*"plan"'
            Assert-MockCalled Set-Content -ModuleName utils -Times 1
        }
    }

    Context 'When AzureChinaCloud and query uses appserviceresources' {
        It 'Should rewrite appserviceresources to resources' {
            Mock Get-AzContext {
                [pscustomobject]@{ Environment = [pscustomobject]@{ Name = 'AzureChinaCloud' } }
            } -ModuleName utils

            Mock Search-AzGraph {
                param(
                    [string] $Query,
                    [string[]] $Subscription,
                    [string[]] $ManagementGroup,
                    [switch] $UseTenantScope,
                    [switch] $AllowPartialScope,
                    [int] $First,
                    [int] $Skip,
                    [string] $SkipToken,
                    $DefaultProfile,
                    $ErrorAction
                )
                [pscustomobject]@{ Data = @(); SkipToken = $null }
            } -ModuleName utils -RemoveParameterValidation @('Subscription', 'ManagementGroup', 'UseTenantScope', 'AllowPartialScope') -Verifiable

            utils\Invoke-WAFQuery -SubscriptionIds @('11111111-1111-1111-1111-111111111111') -Query 'appserviceresources | project id' | Out-Null

            Assert-MockCalled Search-AzGraph -ModuleName utils -Times 1 -ParameterFilter {
                $Query -match '(?i)^\s*resources\b' -and
                $Query -notmatch '(?i)\bappserviceresources\b'
            }
        }
    }

    Context 'When diagnostics query dump dir is set' {
        It 'Should dump the effective query to a .kql file' {
            $dumpDir = Join-Path -Path $TestDrive -ChildPath 'dump'
            New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null
            $env:WARA_DIAGNOSTICS_QUERY_DUMP_DIR = $dumpDir

            Mock Get-AzContext {
                [pscustomobject]@{ Environment = [pscustomobject]@{ Name = 'AzureChinaCloud' } }
            } -ModuleName utils

            $script:lastDumpPath = $null
            $script:lastDumpValue = $null
            Mock Set-Content {
                param(
                    [string] $LiteralPath,
                    [string] $Value,
                    [string] $Encoding,
                    [switch] $NoNewline
                )
                $script:lastDumpPath = $LiteralPath
                $script:lastDumpValue = $Value
            } -ModuleName utils -Verifiable

            Mock Search-AzGraph {
                [pscustomobject]@{ Data = @(); SkipToken = $null }
            } -ModuleName utils -RemoveParameterValidation @('Subscription', 'ManagementGroup', 'UseTenantScope', 'AllowPartialScope') -Verifiable

            utils\Invoke-WAFQuery -SubscriptionIds @('11111111-1111-1111-1111-111111111111') -Query 'appserviceresources | project id' | Out-Null

            $script:lastDumpPath | Should -Match 'ARG-Query-[0-9a-f]{64}\.kql$'
            $script:lastDumpValue | Should -Match '(?i)^\s*resources\b'
            $script:lastDumpValue | Should -Not -Match '(?i)\bappserviceresources\b'
            Assert-MockCalled Set-Content -ModuleName utils -Times 1
        }
    }
}

Describe 'Test-FileExists' {
    Context 'When given an existing file' {
        It 'Should return true' {
            $filePath = "$PSScriptRoot/../data/utils/testconfig1.txt"
            $result = Test-FileExists $filePath

            $result | Should -Be $true
        }
    }
    Context 'When given a file that doesn''t exist' {
        It 'Should throw an error indicating so' {
            $filePath = "$PSScriptRoot/../data/utils/doesntexist.txt"
            $expError = "*not found*"

            { Test-FileExists $filePath } | Should -Throw -ExpectedMessage $expError
        }
    }
}

Describe 'Test-WAFTagPattern' {
    Context 'When given a valid tag pattern' {
        It 'Should return true' {
            $tagPattern = "env||environment=~preprod"
            $result = Test-WAFTagPattern $tagPattern
            $result | Should -Be $true
        }
    }

    Context 'When given an invalid tag pattern' {
        It 'Should throw the exception' {
            $tagPattern = "env||environment~preprod"
            { Test-WAFTagPattern $tagPattern } | Should -Throw
        }
    }
}

Describe 'Test-WAFResourceGroupId' {
    Context 'When given a valid resource group id' {
        It 'Should return true with a valid resource group id' {
            $resourceGroupId = "/subscriptions/$((new-guid).guid)/resourceGroups/RG-01"
            $result = Test-WAFResourceGroupId $resourceGroupId
            $result | Should -Be $true
        }

        It 'Should return true when the resource group id contains a trailing slash' {
            $resourceGroupId = "/subscriptions/$((new-guid).guid)/resourceGroups/RG-01/"
            $result = Test-WAFResourceGroupId $resourceGroupId
            $result | Should -Be $true
        }
    }

    Context 'When given an invalid resource group id' {
        It 'Should throw the exception with a bad GUID' {
            $resourceGroupId = "/subscriptions/$((new-guid).guid[1..-1])/resourceGroups/RG-01/"
            { Test-WAFResourceGroupId $resourceGroupId } | Should -Throw
        }

        It 'Should throw the exception with a bad resourceGroups typo - missing s' {
            $resourceGroupId = "/subscriptions/$((new-guid).guid)/resourceGroup/RG-01/"
            { Test-WAFResourceGroupId $resourceGroupId } | Should -Throw
        }

        It 'Should throw the exception with a bad subscription typo - missing s' {
            $resourceGroupId = "/subscription/$((new-guid).guid)/resourceGroups/RG-01/"
            { Test-WAFResourceGroupId $resourceGroupId } | Should -Throw
        }

        It 'Should throw the exception when missing the leading slash' {
            $resourceGroupId = "subscriptions/$((new-guid).guid)/resourceGroups/RG-01"
            { Test-WAFResourceGroupId $resourceGroupId } | Should -Throw
        }
    }
}

Describe 'Test-WAFSubscriptionId' {
    Context 'When given a valid subscription id' {
        It 'Should return true with a valid subscription id' {
            $subscriptionId = "/subscriptions/$((new-guid).guid)"
            $result = Test-WAFSubscriptionId $subscriptionId
            $result | Should -Be $true
        }

        It 'Should return true when the subscription id contains a trailing slash' {
            $subscriptionId = "/subscriptions/$((new-guid).guid)/"
            $result = Test-WAFSubscriptionId $subscriptionId
            $result | Should -Be $true
        }
    }

    Context 'When given an invalid subscription id' {
        It 'Should throw the exception with a bad GUID' {
            $subscriptionId = "/subscriptions/$((new-guid).guid[1..-1])/"
            { Test-WAFSubscriptionId $subscriptionId } | Should -Throw
        }

        It 'Should throw the exception with a bad subscription typo - missing s' {
            $subscriptionId = "/subscription/$((new-guid).guid)/"
            { Test-WAFSubscriptionId $subscriptionId } | Should -Throw
        }

        It 'Should throw the exception when missing the leading slash' {
            $subscriptionId = "subscriptions/$((new-guid).guid)"
            { Test-WAFSubscriptionId $subscriptionId } | Should -Throw
        }
    }
}

Describe 'Test-WAFIsGuid' {
    Context 'When given a valid GUID' {
        It 'Should return true with a valid GUID' {
            $guid = [Guid]::NewGuid()
            $result = Test-WAFIsGuid $guid
            $result | Should -Be $true
        }
    }

    Context 'When given an invalid GUID' {
        It 'Should throw the exception with a bad GUID' {
            $guid = [Guid]::NewGuid().guid[1..-1]
            { Test-WAFIsGuid $guid } | Should -Throw
        }
    }
}

Describe 'Repair-WAFSubscriptionId' {
    Context 'When given a subscription id without /subscriptions/' {
        It 'Should return a subscription id with /subscriptions/' {
            $subscriptionId = "$((new-guid).guid)"
            $result = Repair-WAFSubscriptionId $subscriptionId
            $result | Should -Be "/subscriptions/$subscriptionId"
        }
    }

    Context 'When given two subscription ids, one with /subscriptions/ and one without' {
        It 'Should return both subscription ids with /subscriptions/' {
            $subscriptionId1 = "/subscriptions/$((new-guid).guid)"
            $subscriptionId2 = "$((new-guid).guid)"
            $result = Repair-WAFSubscriptionId @($subscriptionId1, $subscriptionId2)
            $result | Should -contain "/subscriptions/$subscriptionId2"
            $result | Should -contain $subscriptionId1
        }
    }
}

