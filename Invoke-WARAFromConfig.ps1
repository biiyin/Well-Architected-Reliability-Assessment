<#
.SYNOPSIS
Installs/imports a custom WARA module package (zip), then runs Collector + Analyzer using a config file.

.DESCRIPTION
This script is intended for *custom* WARA deliveries where the customer should NOT install from PowerShell Gallery.
It:
  1) Expands ./dist/WARA-custom-*.zip
  2) Installs the module into CurrentUser PSModulePath (or imports directly)
  3) Runs Start-WARACollector using -ConfigFile (+ optional Azure environment)
  4) Saves the collector output JSON to disk
  5) Runs Start-WARAAnalyzer to generate the Expert Analysis Excel

.PARAMETER ConfigFile
Path to the WARA config file (same format as docs/wara/configfile.example).

.PARAMETER ModuleZip
Path to the custom WARA module zip (for example: ./dist/WARA-custom-1.0.6.2.zip).

.PARAMETER OutputDirectory
Directory where the JSON and Excel output should be written.

.PARAMETER AzureEnvironment
Azure environment name. Use AzureChinaCloud for China.

.PARAMETER SkipInstall
If set, the script will not copy the module into PSModulePath; it will import the module from the expanded zip folder.

.PARAMETER InstallDependencies
If set, installs missing dependencies Az.Accounts, Az.ResourceGraph, and Az.Network.

.EXAMPLE
pwsh -NoProfile -File .\Invoke-WARAFromConfig.ps1 -ConfigFile .\docs\wara\config.txt -ModuleZip .\dist\WARA-custom-1.0.6.2.zip

.EXAMPLE
pwsh -NoProfile -File .\Invoke-WARAFromConfig.ps1 -ConfigFile C:\WARA\config.txt -AzureEnvironment AzureChinaCloud
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $ConfigFile=".\\configfile",

    [Parameter(Mandatory = $false)]
    [string] $ModuleZip = ".\\dist\\WARA-custom-1.0.6.2.zip",

    [Parameter(Mandatory = $false)]
    [string] $OutputDirectory = ".\\output",

    [Parameter(Mandatory = $false)]
    [ValidateSet('AzureCloud', 'AzureChinaCloud', 'AzureUSGovernment', 'AzureGermanCloud')]
    [string] $AzureEnvironment = 'AzureChinaCloud',

    [Parameter(Mandatory = $false)]
    [switch] $SkipInstall,

    [Parameter(Mandatory = $false)]
    [Nullable[bool]] $InstallDependencies = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Default to installing dependencies unless explicitly disabled.
if ($null -eq $InstallDependencies) {
    $InstallDependencies = $true
}

function Write-Section([string] $Message) {
    Write-Host "\n=== $Message ===" -ForegroundColor Cyan
}

function Confirm-ModuleDependency([string] $Name, [string] $MinimumVersion) {
    $found = Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $found) {
        if (-not $InstallDependencies) {
            throw "Required module [$Name] not found. InstallDependencies is disabled."
        }
        Write-Host "Installing dependency module [$Name]..." -ForegroundColor Yellow
        Install-Module -Name $Name -Scope CurrentUser -Force -MinimumVersion $MinimumVersion
        return
    }

    if ($MinimumVersion) {
        try {
            $min = [version]$MinimumVersion
            if ($found.Version -lt $min) {
                if (-not $InstallDependencies) {
                    throw "Required module [$Name] version must be >= $MinimumVersion (found $($found.Version))."
                }
                Write-Host "Updating dependency module [$Name] to >= $MinimumVersion..." -ForegroundColor Yellow
                Install-Module -Name $Name -Scope CurrentUser -Force -MinimumVersion $MinimumVersion
            }
        }
        catch {
            # If MinimumVersion isn't parseable, just skip version compare.
        }
    }
}

function Get-CurrentUserModuleRoot() {
    # Prefer Documents\PowerShell\Modules, fallback to first entry in PSModulePath
    $preferred = Join-Path -Path $HOME -ChildPath 'Documents\\PowerShell\\Modules'
    if (Test-Path $preferred) { return $preferred }

    $paths = ($env:PSModulePath -split [IO.Path]::PathSeparator) | Where-Object { $_ -and (Test-Path $_) }
    if ($paths.Count -gt 0) { return $paths[0] }

    # Create preferred if nothing exists
    New-Item -ItemType Directory -Force -Path $preferred | Out-Null
    return $preferred
}

function Ensure-AzureLogin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('AzureCloud', 'AzureChinaCloud', 'AzureUSGovernment', 'AzureGermanCloud')]
        [string] $AzureEnvironment,

        [Parameter(Mandatory = $false)]
        [string] $TenantId
    )

    $ctx = $null
    try {
        $ctx = Get-AzContext -ErrorAction Stop
    }
    catch {
        $ctx = $null
    }

    $needsLogin = $false
    if (-not $ctx) {
        $needsLogin = $true
    }
    elseif ($ctx.Environment -and $ctx.Environment.Name -and ($ctx.Environment.Name -ne $AzureEnvironment)) {
        $needsLogin = $true
    }
    elseif ($TenantId -and $ctx.Tenant -and $ctx.Tenant.Id -and ([string]$ctx.Tenant.Id -ne [string]$TenantId)) {
        $needsLogin = $true
    }

    if (-not $needsLogin) {
        Write-Host "Azure context OK: Tenant=$($ctx.Tenant.Id) Environment=$($ctx.Environment.Name)" -ForegroundColor DarkGray
        return
    }

    $connectParams = @{
        WarningAction = 'SilentlyContinue'
        ErrorAction   = 'Stop'
        Environment   = $AzureEnvironment
    }
    if ($TenantId) {
        $connectParams.Tenant = $TenantId
    }

    $tenantSuffix = if ($TenantId) { ", Tenant=$TenantId" } else { '' }
    Write-Host "Connecting to Azure (Environment=$AzureEnvironment$tenantSuffix)..." -ForegroundColor Yellow
    Connect-AzAccount @connectParams | Out-Null
}

Write-Section "Pre-flight"
if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    throw "PowerShell 7.4+ is required. Current: $($PSVersionTable.PSVersion)"
}
Write-Host "Azure environment: $AzureEnvironment" -ForegroundColor DarkGray

try {
    $ConfigFile = (Resolve-Path -LiteralPath $ConfigFile -ErrorAction Stop).Path
}
catch {
    throw "ConfigFile not found: $ConfigFile"
}

try {
    $ModuleZip = (Resolve-Path -LiteralPath $ModuleZip -ErrorAction Stop).Path
}
catch {
    throw "ModuleZip not found: $ModuleZip"
}

try {
    $zipHash = Get-FileHash -Algorithm SHA256 -LiteralPath $ModuleZip
    Write-Host "ModuleZip SHA256: $($zipHash.Hash)" -ForegroundColor DarkGray
}
catch {
    Write-Host "ModuleZip SHA256: <failed to compute>" -ForegroundColor Yellow
}

Confirm-ModuleDependency -Name 'Az.Accounts' -MinimumVersion '3.0.0'
Confirm-ModuleDependency -Name 'Az.ResourceGraph' -MinimumVersion '1.0.0'
# Used by topology enrichment fallback paths (e.g., Get-AzVirtualNetworkPeering).
Confirm-ModuleDependency -Name 'Az.Network' -MinimumVersion '7.0.0'

Write-Section "Expand custom module zip"
$stagingRoot = Join-Path -Path $env:TEMP -ChildPath ("WARA-custom-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

Expand-Archive -Path $ModuleZip -DestinationPath $stagingRoot -Force

$manifest = Get-ChildItem -Path $stagingRoot -Recurse -File -Filter 'wara.psd1' | Select-Object -First 1
if (-not $manifest) {
    throw "Cannot find wara.psd1 inside expanded zip. Ensure the zip contains the WARA module folder."
}

$moduleData = Import-PowerShellDataFile -Path $manifest.FullName
$customVersion = $moduleData.ModuleVersion
if (-not $customVersion) {
    throw "Failed to read ModuleVersion from $($manifest.FullName)"
}

# Module folder is the directory containing wara.psd1
$moduleFolder = Split-Path -Path $manifest.FullName -Parent

Write-Host "Custom module manifest: $($manifest.FullName)" -ForegroundColor DarkGray
Write-Host "Custom module version : $customVersion" -ForegroundColor DarkGray

Write-Section "Install / Import custom module"
$importManifestPath = $manifest.FullName

if (-not $SkipInstall) {
    $moduleRoot = Get-CurrentUserModuleRoot
    $dest = Join-Path -Path $moduleRoot -ChildPath ("WARA\\$customVersion")

    if (Test-Path $dest) {
        Write-Host "Removing existing module folder: $dest" -ForegroundColor Yellow
        Remove-Item -Recurse -Force -Path $dest
    }

    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Recurse -Force -Path (Join-Path $moduleFolder '*') -Destination $dest

    $importManifestPath = Join-Path -Path $dest -ChildPath 'wara.psd1'
    Write-Host "Installed custom module to: $dest" -ForegroundColor Green
}
else {
    Write-Host "SkipInstall is set; importing directly from staging folder." -ForegroundColor Yellow
}

Import-Module $importManifestPath -Force

try {
    $invokeWafQuery = Get-Command Invoke-WAFQuery -ErrorAction Stop
    $invokeWafQueryFile = $invokeWafQuery.ScriptBlock.File
    if (-not $invokeWafQueryFile) { $invokeWafQueryFile = '<unknown>' }
    Write-Host "Invoke-WAFQuery loaded from: $invokeWafQueryFile" -ForegroundColor DarkGray
}
catch {
    # Ignore if not available yet
}

# Verify key commands exist
$requiredCommands = @('Start-WARACollector', 'Start-WARAAnalyzer')
foreach ($cmd in $requiredCommands) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Expected command [$cmd] not found after Import-Module."
    }
}

Write-Section "Azure Login"
# Ensure we authenticate against the requested Azure cloud. If the custom module zip ignores -AzureEnvironment
# internally, pre-auth here prevents defaulting to AzureCloud (Azure global).
$tenantIdFromConfig = $null
try {
    if (Get-Command Import-WAFConfigFileData -ErrorAction SilentlyContinue) {
        $cfg = Import-WAFConfigFileData $ConfigFile
        if ($cfg) {
            $tenantIdFromConfig = $cfg.tenantid
            if (-not $tenantIdFromConfig) { $tenantIdFromConfig = $cfg.TenantId }
        }
    }
}
catch {
    # Non-fatal; we'll connect without explicit tenant.
}

Ensure-AzureLogin -AzureEnvironment $AzureEnvironment -TenantId $tenantIdFromConfig

Write-Section "Run Collector (from config file)"
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -Path $OutputDirectory).Path

Push-Location $OutputDirectory
try {
    # Use -PassThru so we can control the output JSON path
    $collectorOutput = Start-WARACollector -ConfigFile $ConfigFile -AzureEnvironment $AzureEnvironment -PassThru

    $timestamp = Get-Date -Format 'yyyy-MM-dd-HH-mm'
    $jsonPath = Join-Path -Path $OutputDirectory -ChildPath ("WARA-File-$timestamp.json")
    $collectorOutput | ConvertTo-Json -Depth 15 | Out-File -FilePath $jsonPath -Encoding utf8

    Write-Host "Collector JSON saved: $jsonPath" -ForegroundColor Green

    Write-Section "Run Analyzer"
    $expertAnalysisPath = Start-WARAAnalyzer -JSONFile $jsonPath

    if ($expertAnalysisPath) {
        Write-Host "Analyzer Excel saved: $expertAnalysisPath" -ForegroundColor Green
    }
    else {
        Write-Host "Analyzer completed. (No output path captured; check the output directory for Expert-Analysis-v1-*.xlsx)" -ForegroundColor Yellow
    }
}
finally {
    Pop-Location
}

Write-Section "Done"
Write-Host "Output directory: $OutputDirectory" -ForegroundColor Cyan
