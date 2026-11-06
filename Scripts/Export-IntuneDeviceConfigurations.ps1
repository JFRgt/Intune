#requires -Version 7.2
<#
.SYNOPSIS
Exports Microsoft Intune device configuration artefacts to individual JSON files.

.DESCRIPTION
Exports:
- All legacy/device configuration profiles
- Settings Catalog and modern configuration policies
- Administrative Templates (including configured definition values)
- Custom configuration profiles
- Trusted certificate profiles
- SCEP certificate profiles
- Wi-Fi profiles
- Properties Catalog policies when identifiable from Graph metadata

The script preserves the raw Graph representation. It does not normalise objects for import.
It uses Microsoft Graph REST requests through Invoke-MgGraphRequest.

REQUIREMENTS
- PowerShell 7.2 or later
- Microsoft.Graph.Authentication module
- Delegated permission: DeviceManagementConfiguration.Read.All
- An active Intune licence

.EXAMPLE
.\Export-IntuneDeviceConfigurations.ps1 -OutputPath .\IntuneExport -Verbose

.EXAMPLE
.\Export-IntuneDeviceConfigurations.ps1 -OutputPath .\IntuneExport -IncludeAssignments
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $PWD ("IntuneConfigurationExport-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    [Parameter()]
    [switch]$IncludeAssignments,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$MaximumRetryCount = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GraphRoot = 'https://graph.microsoft.com/beta'
$RequiredScopes = @('DeviceManagementConfiguration.Read.All')

function Get-SafePropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$PropertyName
    )

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Invoke-GraphRequestWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('GET')] [string]$Method,
        [Parameter(Mandatory)] [string]$Uri
    )

    for ($attempt = 1; $attempt -le $MaximumRetryCount; $attempt++) {
        try {
            Write-Verbose "$Method $Uri"
            return Invoke-MgGraphRequest -Method $Method -Uri $Uri -OutputType PSObject
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            $retryable = $statusCode -in @(429, 500, 502, 503, 504)
            if (-not $retryable -or $attempt -eq $MaximumRetryCount) { throw }

            $delay = [Math]::Min(60, [Math]::Pow(2, $attempt))
            Write-Warning "Graph returned HTTP $statusCode. Retrying in $delay seconds (attempt $attempt of $MaximumRetryCount)."
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-GraphCollectionAll {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Uri)

    $items = [System.Collections.Generic.List[object]]::new()
    $nextLink = $Uri

    do {
        $response = Invoke-GraphRequestWithRetry -Method GET -Uri $nextLink
        $values = Get-SafePropertyValue -InputObject $response -PropertyName 'value'
        if ($null -ne $values) {
            foreach ($value in @($values)) { $items.Add($value) }
        }
        else {
            $items.Add($response)
        }
        $nextLink = Get-SafePropertyValue -InputObject $response -PropertyName '@odata.nextLink'
    } while ($nextLink)

    return $items.ToArray()
}

function ConvertTo-SafeFileName {
    [CmdletBinding()]
    param(
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string]$Name,
        [Parameter(Mandatory)] [string]$Fallback
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $Fallback }
    $invalid = [IO.Path]::GetInvalidFileNameChars() + [char[]]'/:*?"<>|'
    $escaped = [Regex]::Escape((-join $invalid))
    $safe = [Regex]::Replace($Name, "[$escaped]", '_').Trim().TrimEnd('.')
    if ($safe.Length -gt 150) { $safe = $safe.Substring(0, 150) }
    if ([string]::IsNullOrWhiteSpace($safe)) { return $Fallback }
    return $safe
}

function Save-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$Directory,
        [Parameter()] [AllowNull()] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$Id
    )

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $safeName = ConvertTo-SafeFileName -Name $DisplayName -Fallback $Id
    $path = Join-Path $Directory ("{0}__{1}.json" -f $safeName, $Id)
    $InputObject | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

function Get-DeviceConfigurationCategory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$Configuration)

    $odataType = [string](Get-SafePropertyValue -InputObject $Configuration -PropertyName '@odata.type')

    if ($odataType -match '(?i)trusted.*certificate|trustedrootcertificate') { return 'TrustedCertificates' }
    if ($odataType -match '(?i)scep.*certificate')                    { return 'SCEPCertificates' }
    if ($odataType -match '(?i)wifi')                                 { return 'WiFi' }
    if ($odataType -match '(?i)customconfiguration|customdeviceconfiguration') { return 'CustomConfigurations' }
    return 'DeviceConfigurations'
}

function Get-ConfigurationPolicyCategory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$Policy)

    $templateReference = Get-SafePropertyValue -InputObject $Policy -PropertyName 'templateReference'
    $templateFamily = if ($templateReference) {
        [string](Get-SafePropertyValue -InputObject $templateReference -PropertyName 'templateFamily')
    } else { '' }

    $name = [string](Get-SafePropertyValue -InputObject $Policy -PropertyName 'name')
    if ($templateFamily -match '(?i)propert.*catalog' -or $name -match '(?i)propert.*catalog') {
        return 'PropertiesCatalog'
    }
    return 'SettingsCatalog'
}

function Export-Assignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$Directory,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Id
    )

    try {
        $assignments = Get-GraphCollectionAll -Uri $Uri
        Save-JsonFile -InputObject @($assignments) -Directory $Directory -DisplayName "$Name.assignments" -Id $Id | Out-Null
    }
    catch {
        Write-Warning "Could not export assignments for '$Name' ($Id): $($_.Exception.Message)"
    }
}

# Validate module and connect.
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw "Microsoft.Graph.Authentication is not installed. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
}

Import-Module Microsoft.Graph.Authentication
$context = Get-MgContext
if (-not $context -or -not $context.Account) {
    Connect-MgGraph -Scopes $RequiredScopes -NoWelcome
}

$resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Path $resolvedOutputPath -Force | Out-Null

$summary = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()

# 1. Legacy deviceConfiguration resource family.
$deviceConfigurations = Get-GraphCollectionAll -Uri "$GraphRoot/deviceManagement/deviceConfigurations"
foreach ($item in $deviceConfigurations) {
    $id = [string](Get-SafePropertyValue -InputObject $item -PropertyName 'id')
    $displayName = [string](Get-SafePropertyValue -InputObject $item -PropertyName 'displayName')
    $category = Get-DeviceConfigurationCategory -Configuration $item

    try {
        # Retrieve the individual object to preserve its full derived type representation.
        $detail = Invoke-GraphRequestWithRetry -Method GET -Uri "$GraphRoot/deviceManagement/deviceConfigurations/$id"
        $path = Save-JsonFile -InputObject $detail -Directory (Join-Path $resolvedOutputPath $category) -DisplayName $displayName -Id $id
        $summary.Add([pscustomobject]@{ Category=$category; Name=$displayName; Id=$id; File=$path; Status='Exported' })

        if ($IncludeAssignments) {
            Export-Assignments -Uri "$GraphRoot/deviceManagement/deviceConfigurations/$id/assignments" -Directory (Join-Path $resolvedOutputPath "Assignments/$category") -Name $displayName -Id $id
        }
    }
    catch {
        $errors.Add([pscustomobject]@{ Category=$category; Name=$displayName; Id=$id; Error=$_.Exception.Message })
    }
}

# 2. Settings Catalog, modern configuration policies and identifiable Properties Catalog policies.
$configurationPolicies = Get-GraphCollectionAll -Uri "$GraphRoot/deviceManagement/configurationPolicies"
foreach ($item in $configurationPolicies) {
    $id = [string](Get-SafePropertyValue -InputObject $item -PropertyName 'id')
    $name = [string](Get-SafePropertyValue -InputObject $item -PropertyName 'name')
    $category = Get-ConfigurationPolicyCategory -Policy $item

    try {
        # The settings relationship is requested explicitly because the collection response is not a complete backup payload.
        $detail = Invoke-GraphRequestWithRetry -Method GET -Uri "$GraphRoot/deviceManagement/configurationPolicies/$id`?`$expand=settings"
        $path = Save-JsonFile -InputObject $detail -Directory (Join-Path $resolvedOutputPath $category) -DisplayName $name -Id $id
        $summary.Add([pscustomobject]@{ Category=$category; Name=$name; Id=$id; File=$path; Status='Exported' })

        if ($IncludeAssignments) {
            Export-Assignments -Uri "$GraphRoot/deviceManagement/configurationPolicies/$id/assignments" -Directory (Join-Path $resolvedOutputPath "Assignments/$category") -Name $name -Id $id
        }
    }
    catch {
        $errors.Add([pscustomobject]@{ Category=$category; Name=$name; Id=$id; Error=$_.Exception.Message })
    }
}

# 3. Administrative Templates. Export each configuration plus its configured definition values.
$administrativeTemplates = Get-GraphCollectionAll -Uri "$GraphRoot/deviceManagement/groupPolicyConfigurations"
foreach ($item in $administrativeTemplates) {
    $id = [string](Get-SafePropertyValue -InputObject $item -PropertyName 'id')
    $displayName = [string](Get-SafePropertyValue -InputObject $item -PropertyName 'displayName')

    try {
        $detail = Invoke-GraphRequestWithRetry -Method GET -Uri "$GraphRoot/deviceManagement/groupPolicyConfigurations/$id"
        $definitionValues = Get-GraphCollectionAll -Uri "$GraphRoot/deviceManagement/groupPolicyConfigurations/$id/definitionValues`?`$expand=definition,presentationValues(`$expand=presentation)"

        $exportObject = [ordered]@{
            configuration    = $detail
            definitionValues = @($definitionValues)
        }

        $path = Save-JsonFile -InputObject $exportObject -Directory (Join-Path $resolvedOutputPath 'AdministrativeTemplates') -DisplayName $displayName -Id $id
        $summary.Add([pscustomobject]@{ Category='AdministrativeTemplates'; Name=$displayName; Id=$id; File=$path; Status='Exported' })

        if ($IncludeAssignments) {
            Export-Assignments -Uri "$GraphRoot/deviceManagement/groupPolicyConfigurations/$id/assignments" -Directory (Join-Path $resolvedOutputPath 'Assignments/AdministrativeTemplates') -Name $displayName -Id $id
        }
    }
    catch {
        $errors.Add([pscustomobject]@{ Category='AdministrativeTemplates'; Name=$displayName; Id=$id; Error=$_.Exception.Message })
    }
}

# Write manifests.
$manifest = [ordered]@{
    schemaVersion    = '1.0'
    exportedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
    graphProfile     = 'beta'
    tenantId         = (Get-MgContext).TenantId
    includeAssignments = [bool]$IncludeAssignments
    outputPath       = $resolvedOutputPath
    exportedCount    = $summary.Count
    errorCount       = $errors.Count
    categories       = @($summary | Group-Object Category | Sort-Object Name | ForEach-Object {
        [ordered]@{ name=$_.Name; count=$_.Count }
    })
}

$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $resolvedOutputPath 'manifest.json') -Encoding utf8NoBOM
$summary | Export-Csv -LiteralPath (Join-Path $resolvedOutputPath 'export-summary.csv') -NoTypeInformation -Encoding utf8BOM
$errors | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $resolvedOutputPath 'export-errors.json') -Encoding utf8NoBOM

Write-Host "Export completed: $resolvedOutputPath" -ForegroundColor Green
Write-Host "Exported objects: $($summary.Count)" -ForegroundColor Green
if ($errors.Count -gt 0) {
    Write-Warning "$($errors.Count) object(s) failed. Review export-errors.json."
}
