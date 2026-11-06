#requires -Version 7.2
<#
.SYNOPSIS
Normalises the folder-based output produced by Export-IntuneDeviceConfigurations.ps1.

.DESCRIPTION
The input tree is expected to contain workload folders such as:
  SettingsCatalog
  DeviceConfigurations
  AdministrativeTemplates
  CustomConfigurations
  TrustedCertificates
  PropertiesCatalog
  SCEPCertificates
  WiFi
  Assignments (optional)

The output preserves exactly that workload-oriented folder structure. N01/N02/N03 are
internal normalisation strategies only; no N01/N02/N03 directories are created.

Raw source JSON is never modified.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Categories = [ordered]@{
    SettingsCatalog         = 'ConfigurationPolicy'
    DeviceConfigurations    = 'DeviceConfiguration'
    AdministrativeTemplates = 'AdministrativeTemplate'
    CustomConfigurations    = 'DeviceConfiguration'
    TrustedCertificates     = 'DeviceConfiguration'
    PropertiesCatalog       = 'ConfigurationPolicy'
    SCEPCertificates        = 'DeviceConfiguration'
    WiFi                    = 'DeviceConfiguration'
}

function Copy-JsonObject {
    param([Parameter(Mandatory)]$Object)
    $Object | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100
}

function Test-JsonProperty {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string]$Name)
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Remove-TopLevelProperties {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string[]]$Names)
    foreach ($name in $Names) {
        if (Test-JsonProperty $Object $name) { $Object.PSObject.Properties.Remove($name) }
    }
    return $Object
}

function ConvertTo-CanonicalObject {
    param([AllowNull()]$Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [string] -or $Object -is [ValueType]) { return $Object }

    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string] -and $Object -isnot [pscustomobject]) {
        # The leading comma prevents PowerShell from unrolling the array on return.
        # Without it, empty arrays become $null and single-item arrays become scalars.
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Object) { $list.Add((ConvertTo-CanonicalObject $item)) }
        return ,$list.ToArray()
    }

    if ($Object -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Object.Keys | Sort-Object)) {
            $ordered[$key] = ConvertTo-CanonicalObject $Object[$key]
        }
        return [pscustomobject]$ordered
    }

    $result = [ordered]@{}
    foreach ($p in @($Object.PSObject.Properties | Sort-Object Name)) {
        # OData context annotations are response metadata, not part of a create payload.
        if ($p.Name -match '@odata\.context$') { continue }
        $result[$p.Name] = ConvertTo-CanonicalObject $p.Value
    }
    return [pscustomobject]$result
}

function Normalize-DeviceConfiguration {
    param([Parameter(Mandatory)]$Object)
    $o = Copy-JsonObject $Object
    # Remove only service-managed properties at the resource root. Do not recursively
    # strip id fields because nested IDs can be semantically required.
    return Remove-TopLevelProperties $o @(
        'id','createdDateTime','lastModifiedDateTime','version','supportsScopeTags'
    )
}

function Normalize-ConfigurationPolicy {
    param([Parameter(Mandatory)]$Object)
    $o = Copy-JsonObject $Object
    $o = Remove-TopLevelProperties $o @(
        'id','createdDateTime','lastModifiedDateTime','version',
        'settingCount','isAssigned','creationSource'
    )

    # The exporter already expands settings. Keep every setting payload intact.
    # Sort only sibling settings to produce stable Git diffs.
    if (Test-JsonProperty $o 'settings') {
        $o.settings = @($o.settings | Sort-Object {
            if (Test-JsonProperty $_ 'settingInstance') {
                if (Test-JsonProperty $_.settingInstance 'settingDefinitionId') {
                    return [string]$_.settingInstance.settingDefinitionId
                }
            }
            return ($_ | ConvertTo-Json -Depth 100 -Compress)
        })
    }
    return $o
}

function Normalize-AdministrativeTemplate {
    param([Parameter(Mandatory)]$Object)

    # Export format: { configuration: ..., definitionValues: [...] }
    if (-not (Test-JsonProperty $Object 'configuration')) {
        throw 'Administrative Template export does not contain configuration.'
    }

    $configuration = Copy-JsonObject $Object.configuration
    $configuration = Remove-TopLevelProperties $configuration @(
        'id','createdDateTime','lastModifiedDateTime','version','supportsScopeTags'
    )

    $values = foreach ($sourceValue in @($Object.definitionValues)) {
        $v = Copy-JsonObject $sourceValue
        Remove-TopLevelProperties $v @('id','createdDateTime','lastModifiedDateTime')
    }

    return [pscustomobject][ordered]@{
        configuration    = $configuration
        definitionValues = @($values)
    }
}

function Normalize-AssignmentCollection {
    param([Parameter(Mandatory)]$Object)

    $items = if ($Object -is [array]) { @($Object) }
             elseif (Test-JsonProperty $Object 'value') { @($Object.value) }
             else { @($Object) }

    # Source assignment IDs are service generated. Tenant-bound target IDs are
    # deliberately retained for the later mapping/import stage.
    return ,@($items | ForEach-Object {
        $a = Copy-JsonObject $_
        Remove-TopLevelProperties $a @('id')
    })
}

function Save-NormalizedJson {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string]$Path)
    $parent = Split-Path $Path -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $canonical = ConvertTo-CanonicalObject $Object
    $canonical | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

$sourceRoot = [IO.Path]::GetFullPath($InputPath)
$targetRoot = [IO.Path]::GetFullPath($OutputPath)

if ($sourceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) -eq $targetRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)) {
    throw 'InputPath and OutputPath must be different.'
}
if (Test-Path -LiteralPath $targetRoot) {
    if (-not $Force) { throw "Output path exists. Use -Force to replace it: $targetRoot" }
    Remove-Item -LiteralPath $targetRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null

$summary = [System.Collections.Generic.List[object]]::new()
$errors  = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $Categories.GetEnumerator()) {
    $folder = $entry.Key
    $strategy = $entry.Value
    $sourceFolder = Join-Path $sourceRoot $folder
    if (-not (Test-Path -LiteralPath $sourceFolder -PathType Container)) {
        Write-Verbose "Skipping missing folder: $folder"
        continue
    }

    foreach ($file in Get-ChildItem -LiteralPath $sourceFolder -Filter '*.json' -File) {
        try {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
            $normal = switch ($strategy) {
                'ConfigurationPolicy'     { Normalize-ConfigurationPolicy $raw; break }
                'AdministrativeTemplate'  { Normalize-AdministrativeTemplate $raw; break }
                'DeviceConfiguration'     { Normalize-DeviceConfiguration $raw; break }
                default                   { throw "Unknown normalisation strategy: $strategy" }
            }

            $destination = Join-Path (Join-Path $targetRoot $folder) $file.Name
            Save-NormalizedJson $normal $destination
            $summary.Add([pscustomobject]@{Folder=$folder; File=$file.Name; Strategy=$strategy; Status='Normalised'})
        }
        catch {
            $errors.Add([pscustomobject]@{Folder=$folder; File=$file.Name; Error=$_.Exception.Message})
        }
    }
}

# Preserve the exporter's Assignments/<workload>/... hierarchy if present.
$assignmentRoot = Join-Path $sourceRoot 'Assignments'
if (Test-Path -LiteralPath $assignmentRoot -PathType Container) {
    foreach ($file in Get-ChildItem -LiteralPath $assignmentRoot -Filter '*.json' -File -Recurse) {
        try {
            $relative = [IO.Path]::GetRelativePath($assignmentRoot, $file.FullName)
            $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
            $normal = Normalize-AssignmentCollection $raw
            $destination = Join-Path (Join-Path $targetRoot 'Assignments') $relative
            Save-NormalizedJson $normal $destination
            $summary.Add([pscustomobject]@{Folder='Assignments'; File=$relative; Strategy='Assignment'; Status='Normalised'})
        }
        catch {
            $errors.Add([pscustomobject]@{Folder='Assignments'; File=$file.FullName; Error=$_.Exception.Message})
        }
    }
}

$manifest = [ordered]@{
    schemaVersion   = '1.1'
    inputPath       = $sourceRoot
    outputPath      = $targetRoot
    normalizedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    normalizedCount = $summary.Count
    errorCount      = $errors.Count
    folderModel     = 'PreserveExporterFolderStructure'
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $targetRoot 'normalization-manifest.json') -Encoding utf8NoBOM
$summary | Export-Csv -LiteralPath (Join-Path $targetRoot 'normalization-summary.csv') -NoTypeInformation -Encoding utf8BOM
@($errors) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $targetRoot 'normalization-errors.json') -Encoding utf8NoBOM

Write-Host "Normalisation complete: $targetRoot" -ForegroundColor Green
Write-Host "Normalised: $($summary.Count); Errors: $($errors.Count)" -ForegroundColor Green
