<#
.SYNOPSIS
Creates a minimal Azure China test environment for validating WARA topology enrichment.

.DESCRIPTION
Creates (or previews with -WhatIf):
- Resource group
- VNet + delegated subnet (Microsoft.DBforMySQL/flexibleServers)
- Private DNS zone + VNet link
- MySQL Flexible Server using the delegated subnet (VNet integration)

This is intended to generate a workload that will surface in WARA Collector output with:
- topology_subnetIds / topology_vnetIds
- topology_subnetDetails (subnet name, CIDR, delegation)

IMPORTANT
- This creates billable resources.
- Use Remove-AzResourceGroup to clean up.

.PARAMETER TenantId
Optional tenant ID. If omitted, interactive login decides.

.PARAMETER SubscriptionId
Target subscription ID (GUID, without /subscriptions/ prefix).

.PARAMETER Location
Azure region for the resources (China regions such as chinaeast2, chinanorth3).

.PARAMETER AzureEnvironment
Azure environment name. For China use AzureChinaCloud.

.PARAMETER ResourceGroupName
Resource group name to create.

.PARAMETER PrivateDnsZoneName
Private DNS zone used by MySQL Flexible Server VNet integration.
For AzureChinaCloud, the common suffix is *.chinacloudapi.cn; if your org uses a different zone, override this.

.PARAMETER MySqlServerName
MySQL flexible server name (DNS prefix).

.EXAMPLE
pwsh -NoProfile -File .\tools\New-WARATestMySqlFlexVnetIntegration.ps1 \
  -TenantId <tenant-guid> -SubscriptionId <sub-guid> -Location chinaeast2

#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [string] $TenantId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string] $Location = 'chinanorth3',

    [Parameter(Mandatory = $false)]
    [ValidateSet('AzureCloud', 'AzureChinaCloud', 'AzureUSGovernment', 'AzureGermanCloud')]
    [string] $AzureEnvironment = 'AzureChinaCloud',

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName = $("wara-mysql-vnet-test-" + (Get-Date -Format 'yyyyMMdd-HHmmss')),

    [Parameter(Mandatory = $false)]
    [string] $VnetName = 'vnet-wara-mysql-test',

    [Parameter(Mandatory = $false)]
    [string] $VnetAddressPrefix = '10.50.0.0/16',

    [Parameter(Mandatory = $false)]
    [string] $SubnetName = 'snet-mysql',

    [Parameter(Mandatory = $false)]
    [string] $SubnetPrefix = '10.50.1.0/24',

    [Parameter(Mandatory = $false)]
    [string] $PrivateDnsZoneName = 'privatelink.mysql.database.chinacloudapi.cn',

    [Parameter(Mandatory = $false)]
    [string] $MySqlServerName = $(
        'waramysql' + (Get-Random -Minimum 100000 -Maximum 999999)
    ),

    [Parameter(Mandatory = $false)]
    [string] $AdministratorLogin = 'waraadmin',

    [Parameter(Mandatory = $false)]
    [SecureString] $AdministratorPassword,

    [Parameter(Mandatory = $false)]
    [switch] $SkipLogin,

    [Parameter(Mandatory = $false)]
    [string] $SkuName = 'Standard_D2ds_v4',

    [Parameter(Mandatory = $false)]
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $AdministratorPassword) {
    # Generate a strong random password so the script can run non-interactively.
    # The password is not printed to output.
    $passwordPlain = -join (
        @(
            'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+[]{}:,.?'
        )[0].ToCharArray() | Get-Random -Count 32
    )
    $AdministratorPassword = ConvertTo-SecureString -String $passwordPlain -AsPlainText -Force
}

$templateFile = Join-Path -Path $PSScriptRoot -ChildPath 'templates/mysql-flex-vnetintegration.json'
if (-not (Test-Path -LiteralPath $templateFile)) {
    throw "Template file not found: $templateFile"
}

$subscriptionResourceId = "/subscriptions/$SubscriptionId"
$resourceGroupId = "$subscriptionResourceId/resourceGroups/$ResourceGroupName"

$expected = [pscustomobject]@{
    AzureEnvironment      = $AzureEnvironment
    TenantId              = $TenantId
    SubscriptionId        = $SubscriptionId
    Location              = $Location
    ResourceGroupName     = $ResourceGroupName
    ResourceGroupId       = $resourceGroupId
    VnetName              = $VnetName
    SubnetName            = $SubnetName
    PrivateDnsZoneName    = $PrivateDnsZoneName
    MySqlServerName       = $MySqlServerName
    ConfigFileResourceGroupLine = $resourceGroupId
}

$connectTarget = "$AzureEnvironment/$SubscriptionId"
if (-not $SkipLogin) {
    if ($PSCmdlet.ShouldProcess($connectTarget, 'Connect-AzAccount/Set-AzContext')) {
        $connectParams = @{ Environment = $AzureEnvironment; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
        if ($TenantId) { $connectParams.Tenant = $TenantId }

        Connect-AzAccount @connectParams | Out-Null
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    }
}
else {
    if ($PSCmdlet.ShouldProcess($connectTarget, 'Set-AzContext')) {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'New-AzResourceGroup')) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop | Out-Null
}

$deploymentName = "wara-mysql-vnet-test-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
$templateParams = @{ 
    location = $Location
    vnetName = $VnetName
    vnetAddressPrefix = $VnetAddressPrefix
    subnetName = $SubnetName
    subnetPrefix = $SubnetPrefix
    privateDnsZoneName = $PrivateDnsZoneName
    mysqlServerName = $MySqlServerName
    administratorLogin = $AdministratorLogin
    administratorLoginPassword = $AdministratorPassword
    skuName = $SkuName
    publicNetworkAccess = 'Disabled'
}

if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Deploy ARM template ($deploymentName)")) {
    $deploymentParams = @{
        Name                    = $deploymentName
        ResourceGroupName       = $ResourceGroupName
        TemplateFile            = $templateFile
        TemplateParameterObject = $templateParams
        ErrorAction             = 'Stop'
    }

    $deployment = New-AzResourceGroupDeployment @deploymentParams

    $expected | Add-Member -NotePropertyName VnetId -NotePropertyValue $deployment.Outputs.vnetId.value -Force
    $expected | Add-Member -NotePropertyName SubnetId -NotePropertyValue $deployment.Outputs.subnetId.value -Force
    $expected | Add-Member -NotePropertyName MySqlServerId -NotePropertyValue $deployment.Outputs.mysqlServerId.value -Force
    $expected | Add-Member -NotePropertyName PrivateDnsZoneId -NotePropertyValue $deployment.Outputs.privateDnsZoneId.value -Force
}

Write-Host "\nCreated/Planned test environment:" -ForegroundColor Cyan
$expected | Format-List | Out-String | Write-Host

Write-Host "Next step (configfile): add this line under [resourcegroups]:" -ForegroundColor Yellow
Write-Host "  $($expected.ConfigFileResourceGroupLine)" -ForegroundColor Yellow

Write-Host "Cleanup (deletes everything):" -ForegroundColor Yellow
Write-Host "  Remove-AzResourceGroup -Name '$ResourceGroupName' -Force" -ForegroundColor Yellow

if ($PassThru) {
    return $expected
}
