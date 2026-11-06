#requires -Version 7.2
<#
.SYNOPSIS
Imports one normalised Intune configuration JSON file at a time.

.DESCRIPTION
Designed for output produced by Normalize-IntuneDeviceConfigurations.ps1.
Resource type is inferred from the parent folder of -JsonPath.

Supported folders:
- SettingsCatalog
- PropertiesCatalog
- DeviceConfigurations
- CustomConfigurations
- TrustedCertificates
- SCEPCertificates
- WiFi

AdministrativeTemplates are deliberately blocked in this version because their
normalised export is a compound object (configuration + definitionValues) and should
not be replayed as a single POST.

Assignments are deliberately not imported by this script.

The script posts only one JSON file per invocation and uses Invoke-MgGraphRequest.
It performs no UPDATE/DELETE operation.
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory, Position=0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$JsonPath,

    [Parameter()]
    [ValidateSet('beta','v1.0')]
    [string]$ApiVersion = 'beta',

    [Parameter()]
    [switch]$SkipDuplicateNameCheck,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RequiredScope = 'DeviceManagementConfiguration.ReadWrite.All'
$GraphRoot = "https://graph.microsoft.com/$ApiVersion"

function Get-JsonProperty {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string]$Name)
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Assert-NoNormalizerMetadata {
    param([Parameter(Mandatory)]$Object)
    if ($Object.PSObject.Properties['_normalization']) {
        throw "The JSON contains _normalization metadata. Resolve/remove tenant-bound references before import."
    }
}

function Get-ResourceDefinition {
    param([Parameter(Mandatory)][string]$Folder)

    switch ($Folder.ToLowerInvariant()) {
        'settingscatalog'      { return @{ Kind='ConfigurationPolicy'; Collection='deviceManagement/configurationPolicies'; NameProperty='name' } }
        'propertiescatalog'    { return @{ Kind='ConfigurationPolicy'; Collection='deviceManagement/configurationPolicies'; NameProperty='name' } }
        'deviceconfigurations' { return @{ Kind='DeviceConfiguration'; Collection='deviceManagement/deviceConfigurations'; NameProperty='displayName' } }
        'customconfigurations' { return @{ Kind='DeviceConfiguration'; Collection='deviceManagement/deviceConfigurations'; NameProperty='displayName' } }
        'trustedcertificates'  { return @{ Kind='DeviceConfiguration'; Collection='deviceManagement/deviceConfigurations'; NameProperty='displayName' } }
        'scepcertificates'     { return @{ Kind='DeviceConfiguration'; Collection='deviceManagement/deviceConfigurations'; NameProperty='displayName' } }
        'wifi'                 { return @{ Kind='DeviceConfiguration'; Collection='deviceManagement/deviceConfigurations'; NameProperty='displayName' } }
        'administrativetemplates' {
            throw 'AdministrativeTemplates require a compound import workflow and are intentionally not supported by this single-POST importer.'
        }
        'assignments' {
            throw 'Assignments require target object mapping and are intentionally not supported by this configuration importer.'
        }
        default {
            throw "Unsupported parent folder '$Folder'. Use a JSON file from a folder produced by the normaliser."
        }
    }
}

function Invoke-GraphGetAll {
    param([Parameter(Mandatory)][string]$Uri)
    $result = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        if ($response.PSObject.Properties['value']) {
            foreach ($item in @($response.value)) { $result.Add($item) }
            $next = if ($response.PSObject.Properties['@odata.nextLink']) { $response.'@odata.nextLink' } else { $null }
        } else {
            $result.Add($response)
            $next = $null
        }
    } while ($next)
    return $result.ToArray()
}

# Validate Graph authentication module.
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Microsoft.Graph.Authentication is not installed. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
Import-Module Microsoft.Graph.Authentication

$context = Get-MgContext
if (-not $context -or -not $context.Account) {
    Connect-MgGraph -Scopes $RequiredScope -NoWelcome
    $context = Get-MgContext
}

# Ensure the current token has the required delegated scope when scope data is available.
if ($context.Scopes -and $RequiredScope -notin $context.Scopes) {
    throw "Current Graph context does not contain $RequiredScope. Reconnect with: Connect-MgGraph -Scopes '$RequiredScope'"
}

$resolvedPath = (Resolve-Path -LiteralPath $JsonPath).Path
$folder = Split-Path (Split-Path $resolvedPath -Parent) -Leaf
$resource = Get-ResourceDefinition -Folder $folder

$rawJson = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8
try {
    $bodyObject = $rawJson | ConvertFrom-Json -Depth 100
} catch {
    throw "Invalid JSON: $($_.Exception.Message)"
}

if ($bodyObject -is [array]) {
    throw 'The input must contain exactly one configuration object, not a JSON array.'
}
Assert-NoNormalizerMetadata -Object $bodyObject

# Extra defensive checks: source/service identifiers should already have been removed
# by the normaliser. Reject them rather than silently changing import semantics.
foreach ($forbidden in @('id','createdDateTime','lastModifiedDateTime')) {
    if ($bodyObject.PSObject.Properties[$forbidden]) {
        throw "Top-level property '$forbidden' is present. This does not appear to be a normalised import payload."
    }
}

$name = [string](Get-JsonProperty -Object $bodyObject -Name $resource.NameProperty)
if ([string]::IsNullOrWhiteSpace($name)) {
    throw "Required naming property '$($resource.NameProperty)' is missing or empty."
}

# DeviceConfiguration resources are polymorphic; @odata.type identifies the concrete type.
if ($resource.Kind -eq 'DeviceConfiguration') {
    $odataType = [string](Get-JsonProperty -Object $bodyObject -Name '@odata.type')
    if ([string]::IsNullOrWhiteSpace($odataType)) {
        throw 'DeviceConfiguration import requires @odata.type to identify the concrete configuration type.'
    }
}

$collectionUri = "$GraphRoot/$($resource.Collection)"

if (-not $SkipDuplicateNameCheck) {
    Write-Verbose "Checking target collection for an existing object named '$name'."
    $existing = Invoke-GraphGetAll -Uri $collectionUri
    $duplicates = @($existing | Where-Object {
        $candidate = [string](Get-JsonProperty -Object $_ -Name $resource.NameProperty)
        $candidate -eq $name
    })
    if ($duplicates.Count -gt 0) {
        throw "An object named '$name' already exists in the target collection. Import stopped to prevent an accidental duplicate. Use -SkipDuplicateNameCheck only if a duplicate is intentional."
    }
}

# Convert back from the parsed representation so only validated input is posted.
$body = $bodyObject | ConvertTo-Json -Depth 100

Write-Host "Input       : $resolvedPath"
Write-Host "Type        : $($resource.Kind)"
Write-Host "Name        : $name"
Write-Host "Destination : $collectionUri"
Write-Host "Tenant      : $($context.TenantId)"

if ($PSCmdlet.ShouldProcess("$name in tenant $($context.TenantId)", "POST $collectionUri")) {
    try {
        $created = Invoke-MgGraphRequest `
            -Method POST `
            -Uri $collectionUri `
            -Body $body `
            -ContentType 'application/json' `
            -OutputType PSObject

        $createdId = [string](Get-JsonProperty -Object $created -Name 'id')
        Write-Host "Created successfully. ID: $createdId" -ForegroundColor Green
        if ($PassThru) { return $created }
    }
    catch {
        Write-Error "Import failed for '$name': $($_.Exception.Message)"
        throw
    }
}
