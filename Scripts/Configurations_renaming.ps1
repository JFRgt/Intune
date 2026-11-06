#requires -Version 7.2
 
<#
.SYNOPSIS
Renames Microsoft Intune configuration policies using Microsoft Graph.
 
.DESCRIPTION
The script reads a CSV containing CurrentName and NewName columns.
 
It searches the following Microsoft Intune Graph collections:
 
1. Settings Catalog and modern configuration policies
   /beta/deviceManagement/configurationPolicies
 
2. Traditional device configurations, certificates, Wi-Fi profiles,
   custom profiles and templates
   /beta/deviceManagement/deviceConfigurations
 
3. Endpoint Security policies (legacy intents)
   /beta/deviceManagement/intents
 
4. Administrative Templates
   /beta/deviceManagement/groupPolicyConfigurations
 
The script processes mappings in batches. The default batch size is five.
The script runs in preview mode unless -Execute is specified.
 
CSV FORMAT
 
CurrentName,NewName
Existing configuration name,New configuration name
 
EXAMPLES
 
Preview batch 1:
    .\Rename-IntuneConfigurations.ps1 -CsvPath .\IntuneRenameMapping.csv -BatchNumber 1
 
Execute batch 1:
    .\Rename-IntuneConfigurations.ps1 -CsvPath .\IntuneRenameMapping.csv -BatchNumber 1 -Execute
 
Execute batch 1 without a confirmation prompt per policy:
    .\Rename-IntuneConfigurations.ps1 -CsvPath .\IntuneRenameMapping.csv -BatchNumber 1 -Execute -Confirm:$false
 
Use a batch size of three:
    .\Rename-IntuneConfigurations.ps1 -CsvPath .\IntuneRenameMapping.csv -BatchNumber 1 -BatchSize 3
#>
 
[CmdletBinding(
    SupportsShouldProcess = $true,
    ConfirmImpact = 'High'
)]
param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path -Path $_ -PathType Leaf)) {
            throw "CSV file not found: $_"
        }
 
        return $true
    })]
    [string]$CsvPath,
 
    [ValidateRange(1, 1000)]
    [int]$BatchNumber = 1,
 
    [ValidateRange(1, 50)]
    [int]$BatchSize = 1,
 
    [switch]$Execute,
 
    [switch]$ContinueOnError,
 
    [string]$LogPath = (
        Join-Path `
            -Path $PWD\Logs `
            -ChildPath ("IntuneRename-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    )
)
 
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
 
 
#region Graph endpoint definitions
 
$Collections = @(
    [pscustomobject]@{
        Kind         = 'Settings catalog / modern configuration policy'
        Collection   = 'configurationPolicies'
        Uri          = '/beta/deviceManagement/configurationPolicies'
        NameProperty = 'name'
        Required     = $true
    }
 
    [pscustomobject]@{
        Kind         = 'Device configuration / certificate / Wi-Fi / template'
        Collection   = 'deviceConfigurations'
        Uri          = '/beta/deviceManagement/deviceConfigurations'
        NameProperty = 'displayName'
        Required     = $true
    }
 
    [pscustomobject]@{
        Kind         = 'Endpoint security intent'
        Collection   = 'intents'
        Uri          = '/beta/deviceManagement/intents'
        NameProperty = 'displayName'
        Required     = $true
    }
 
    [pscustomobject]@{
        Kind         = 'Administrative Templates'
        Collection   = 'groupPolicyConfigurations'
        Uri          = '/beta/deviceManagement/groupPolicyConfigurations'
        NameProperty = 'displayName'
        Required     = $false
    }
 
    [pscustomobject]@{
        Kind         = 'Windows PowerShell script'
        Collection   = 'deviceManagementScripts'
        Uri          = '/beta/deviceManagement/deviceManagementScripts'
        NameProperty = 'displayName'
        Required     = $false
    }
 
    [pscustomobject]@{
        Kind         = 'macOS shell script'
        Collection   = 'deviceShellScripts'
        Uri          = '/beta/deviceManagement/deviceShellScripts'
        NameProperty = 'displayName'
        Required     = $false
    }
 
    [pscustomobject]@{
        Kind         = 'Property Catalog'
        Collection   = 'inventoryPolicies'
        Uri          = '/beta/deviceManagement/inventoryPolicies'
        NameProperty = 'displayName'
        Required     = $false
    }
 
    [pscustomobject]@{
        Kind         = 'Device compliance policy'
        Collection   = 'deviceCompliancePolicies'
        Uri          = '/beta/deviceManagement/deviceCompliancePolicies'
        NameProperty = 'displayName'
        Required     = $true
    }
 
    #
    # App configuration policies for enrolled devices
    #
    [pscustomobject]@{
        Kind         = 'App configuration policy - Managed devices'
        Collection   = 'managedDeviceMobileAppConfigurations'
        Uri          = '/beta/deviceAppManagement/mobileAppConfigurations'
        NameProperty = 'displayName'
        Required     = $false
    }
    #
    # App configuration policies for managed apps
    #
    [pscustomobject]@{
        Kind         = 'App configuration policy - Managed apps'
        Collection   = 'targetedManagedAppConfigurations'
        Uri          = '/beta/deviceAppManagement/targetedManagedAppConfigurations'
        NameProperty = 'displayName'
        Required     = $false
    }
    #
    # Android App Protection policies
    #
    [pscustomobject]@{
        Kind         = 'App protection policy - Android'
        Collection   = 'androidManagedAppProtections'
        Uri          = '/beta/deviceAppManagement/androidManagedAppProtections'
        NameProperty = 'displayName'
        Required     = $false
    }
    #
    # iOS/iPadOS App Protection policies
    #
    [pscustomobject]@{
        Kind         = 'App protection policy - iOS/iPadOS'
        Collection   = 'iosManagedAppProtections'
        Uri          = '/beta/deviceAppManagement/iosManagedAppProtections'
        NameProperty = 'displayName'
        Required     = $false
    }
 
)
 
#endregion Graph endpoint definitions
 
 
#region Utility functions
 
function Get-SafePropertyValue {
 
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
 
        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )
 
    $Property = $InputObject.PSObject.Properties[$PropertyName]
 
    if ($null -eq $Property) {
        return $null
    }
 
    return $Property.Value
}
 
 
function Get-GraphErrorMessage {
 
    # Graph returns the useful error text in ErrorDetails, not Exception.Message.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
 
    $Message = $ErrorRecord.Exception.Message
 
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $Message = "{0} | {1}" -f $Message, $ErrorRecord.ErrorDetails.Message
    }
 
    return $Message
}
 
 
function Get-GraphCollectionAll {
 
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )
 
    $Items = [System.Collections.Generic.List[object]]::new()
    $NextLink = $Uri
 
    do {
        Write-Verbose "GET $NextLink"
 
        $Response = Invoke-MgGraphRequest `
            -Method GET `
            -Uri $NextLink `
            -OutputType PSObject
 
        $ResponseValues = Get-SafePropertyValue `
            -InputObject $Response `
            -PropertyName 'value'
 
        if ($null -ne $ResponseValues) {
            foreach ($Value in @($ResponseValues)) {
                $Items.Add($Value)
            }
        }
 
        $NextLink = Get-SafePropertyValue `
            -InputObject $Response `
            -PropertyName '@odata.nextLink'
 
    } while ($NextLink)
 
    return $Items.ToArray()
}
 
 
function Get-IntuneConfigurationIndex {
 
    [CmdletBinding()]
    param ()
 
    $Index = [System.Collections.Generic.List[object]]::new()
    $EndpointResults = @()
 
    foreach ($Collection in $Collections) {
 
        Write-Host ""
        Write-Host "Loading $($Collection.Kind)..." -ForegroundColor Cyan
        Write-Host "Endpoint: $($Collection.Uri)" -ForegroundColor DarkGray
 
        try {
            $Objects = @(
                Get-GraphCollectionAll -Uri $Collection.Uri
            )
 
            Write-Host "Objects found: $($Objects.Count)" -ForegroundColor Green
 
            $EndpointResults += [pscustomobject]@{
                Kind        = $Collection.Kind
                Uri         = $Collection.Uri
                Result      = 'Success'
                ObjectCount = $Objects.Count
                Error       = $null
            }
 
            foreach ($Object in $Objects) {
 
                $Name = Get-SafePropertyValue `
                    -InputObject $Object `
                    -PropertyName $Collection.NameProperty
 
                $Id = Get-SafePropertyValue `
                    -InputObject $Object `
                    -PropertyName 'id'
 
                $ODataType = Get-SafePropertyValue `
                    -InputObject $Object `
                    -PropertyName '@odata.type'
 
                if (-not $Name -or -not $Id) {
                    continue
                }
 
                $Index.Add(
                    [pscustomobject]@{
                        CurrentName   = [string]$Name
                        Id            = [string]$Id
                        Kind          = $Collection.Kind
                        Collection    = $Collection.Collection
                        CollectionUri = $Collection.Uri
                        NameProperty  = $Collection.NameProperty
                        ODataType     = [string]$ODataType
                    }
                )
            }
        }
        catch {
            $ErrorMessage = Get-GraphErrorMessage -ErrorRecord $_
 
            $EndpointResults += [pscustomobject]@{
                Kind        = $Collection.Kind
                Uri         = $Collection.Uri
                Result      = 'Failed'
                ObjectCount = 0
                Error       = $ErrorMessage
            }
 
            if ($Collection.Required) {
                throw "Could not enumerate '$($Collection.Kind)' using endpoint '$($Collection.Uri)'. Error: $ErrorMessage"
            }
 
            Write-Warning "Optional endpoint '$($Collection.Kind)' could not be enumerated. Error: $ErrorMessage"
        }
    }
 
    Write-Host ""
    Write-Host "Endpoint discovery results" -ForegroundColor Cyan
 
    # FIX: Out-Host keeps Format-Table output out of this function's return value.
    # Without it, the formatting objects were mixed into the inventory and broke
    # every later property lookup under Set-StrictMode.
    $EndpointResults |
        Format-Table Result, ObjectCount, Kind, Uri -AutoSize -Wrap |
        Out-Host
 
    return $Index.ToArray()
}
 
 
function Test-RenameMapping {
 
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Mappings
    )
 
    if ($Mappings.Count -eq 0) {
        throw 'The CSV contains no rename mappings.'
    }
 
    foreach ($Column in @('CurrentName', 'NewName')) {
        if ($Column -notin $Mappings[0].PSObject.Properties.Name) {
            throw "CSV is missing required column '$Column'. Required columns are CurrentName and NewName."
        }
    }
 
    $EmptyMappings = @(
        $Mappings | Where-Object {
            -not $_.CurrentName -or
            -not $_.CurrentName.Trim() -or
            -not $_.NewName -or
            -not $_.NewName.Trim()
        }
    )
 
    if ($EmptyMappings.Count -gt 0) {
        throw "The CSV contains $($EmptyMappings.Count) mapping or mappings with an empty CurrentName or NewName."
    }
 
    $DuplicateCurrentNames = @(
        $Mappings | Group-Object -Property CurrentName | Where-Object { $_.Count -gt 1 }
    )
 
    if ($DuplicateCurrentNames.Count -gt 0) {
        throw "Duplicate CurrentName values found in the CSV: $($DuplicateCurrentNames.Name -join '; ')"
    }
 
    $DuplicateNewNames = @(
        $Mappings | Group-Object -Property NewName | Where-Object { $_.Count -gt 1 }
    )
 
    if ($DuplicateNewNames.Count -gt 0) {
        throw "Duplicate NewName values found in the CSV: $($DuplicateNewNames.Name -join '; ')"
    }
}
 
 
function Connect-IntuneGraph {
 
    [CmdletBinding()]
    param ()
 
    $Module = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication
 
    if (-not $Module) {
        throw @'
The Microsoft.Graph.Authentication module is required.
 
Install it with:
 
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
'@
    }
 
    Import-Module Microsoft.Graph.Authentication
 
    $RequiredScope = 'DeviceManagementConfiguration.ReadWrite.All'
    $Context = Get-MgContext
 
    if (-not $Context) {
        Connect-MgGraph -Scopes $RequiredScope -NoWelcome
        return
    }
 
    if ($RequiredScope -notin @($Context.Scopes)) {
 
        Write-Host "The existing Graph session does not have the required permission." -ForegroundColor Yellow
        Write-Host "Reconnecting with $RequiredScope..." -ForegroundColor Yellow
 
        Disconnect-MgGraph | Out-Null
        Connect-MgGraph -Scopes $RequiredScope -NoWelcome
    }
}
 
 
function Get-TotalBatchCount {
 
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [int]$ItemCount,
 
        [Parameter(Mandatory = $true)]
        [int]$ItemsPerBatch
    )
 
    # FIX: PowerShell '/' returns a double for non-exact division (7/5 = 1.4),
    # so the original returned values such as 2.4. Use an explicit ceiling.
    return [int][math]::Ceiling($ItemCount / $ItemsPerBatch)
}
 
function ConvertTo-NormalizedPolicyName {
 
    [CmdletBinding()]
    param (
        [AllowNull()]
        [string]$Name
    )
 
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }
 
    $NormalizedName = $Name.Normalize(
        [System.Text.NormalizationForm]::FormKC
    )
 
    # Replace nonstandard hyphens and dashes with an ordinary hyphen.
    $NormalizedName = $NormalizedName -replace '[\u2010-\u2015\u2212]', '-'
 
    # Replace nonbreaking and repeated whitespace with a normal space.
    $NormalizedName = $NormalizedName -replace '\u00A0', ' '
    $NormalizedName = $NormalizedName -replace '\s+', ' '
 
    return $NormalizedName.Trim()
}
 
function New-RenamePlan {
 
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Mappings,
 
        [Parameter(Mandatory = $true)]
        [object[]]$Inventory,
 
        [Parameter(Mandatory = $true)]
        [int]$CurrentBatchNumber
    )
 
    $Plan = @()
 
    foreach ($Mapping in $Mappings) {
 
        $CurrentName = [string]$Mapping.CurrentName
        $NewName     = [string]$Mapping.NewName
 
       $NormalizedCurrentName = ConvertTo-NormalizedPolicyName -Name $CurrentName
 
        $ExactMatches = @(
            $Inventory | Where-Object {
                $_.CurrentName -ceq $CurrentName
            }
        )
 
        $CaseInsensitiveMatches = @(
            $Inventory | Where-Object {
                $_.CurrentName -ieq $CurrentName
            }
        )
 
        $NormalizedMatches = @(
            $Inventory | Where-Object {
                $InventoryNormalizedName = ConvertTo-NormalizedPolicyName `
                    -Name $_.CurrentName
 
                $InventoryNormalizedName -ieq $NormalizedCurrentName
            }
        )
 
        if ($ExactMatches.Count -gt 0) {
            $ResolvedMatches = $ExactMatches
        }
        elseif ($CaseInsensitiveMatches.Count -gt 0) {
            $ResolvedMatches = $CaseInsensitiveMatches
        }
        else {
            $ResolvedMatches = $NormalizedMatches
        }
 
        $ResolvedObject = $null
        $Status = $null
 
        if ($ResolvedMatches.Count -eq 0) {
            $Status = 'NotFound'
        }
        elseif ($ResolvedMatches.Count -gt 1) {
            $Status = 'Ambiguous'
        }
        else {
            $ResolvedObject = $ResolvedMatches[0]
 
            # Any OTHER object already using the target name blocks the rename.
            $NewNameCollisions = @(
                $Inventory | Where-Object {
                    $_.CurrentName -ieq $NewName -and
                    $_.Id -ne $ResolvedObject.Id
                }
            )
 
            if ($NewNameCollisions.Count -gt 0) {
                $Status = 'TargetNameAlreadyExists'
            }
            # FIX: compare case-sensitively against the real current name so a
            # case-only rename (for example 'win-baseline' to 'WIN-Baseline')
            # is no longer silently treated as NoChange.
            elseif ($ResolvedObject.CurrentName -ceq $NewName) {
                $Status = 'NoChange'
            }
            else {
                $Status = 'Ready'
            }
        }
 
        $Plan += [pscustomobject]@{
            BatchNumber         = $CurrentBatchNumber
            CurrentName         = $CurrentName
            NewName             = $NewName
            Status              = $Status
            ExactMatchCount     = $ExactMatches.Count
            RelaxedMatchCount   = $CaseInsensitiveMatches.Count
            ResolvedCurrentName = if ($ResolvedObject) { $ResolvedObject.CurrentName } else { $null }
            Kind                = if ($ResolvedObject) { $ResolvedObject.Kind } else { $null }
            Id                  = if ($ResolvedObject) { $ResolvedObject.Id } else { $null }
            Collection          = if ($ResolvedObject) { $ResolvedObject.Collection } else { $null }
            CollectionUri       = if ($ResolvedObject) { $ResolvedObject.CollectionUri } else { $null }
            NameProperty        = if ($ResolvedObject) { $ResolvedObject.NameProperty } else { $null }
            ODataType           = if ($ResolvedObject) { $ResolvedObject.ODataType } else { $null }
        }
    }
 
    return $Plan
}
 
 
function Invoke-ConfigurationRename {
 
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$PlanItem
    )
 
    $ResourceUri = "{0}/{1}" -f `
        $PlanItem.CollectionUri,
        $PlanItem.Id
 
    Write-Verbose "GET $ResourceUri"
 
    # Retrieve the current object before constructing the PATCH body.
    $CurrentObject = Invoke-MgGraphRequest `
        -Method GET `
        -Uri $ResourceUri `
        -OutputType PSObject
 
        $CollectionsRequiringODataType = @(
            'deviceCompliancePolicies'
            'deviceConfigurations'
        )
        $AppConfigurationCollections = @(
            'mobileAppConfigurations'
            'managedDeviceMobileAppConfigurations'
            'targetedManagedAppConfigurations'
        )
        $AppProtectionCollections = @(
            'androidManagedAppProtections'
            'iosManagedAppProtections'
            'windowsManagedAppProtections'
        )
 
    $RequestBodyObject = @{}
    #
    # Device configuration / compliance policies
    #
    if ($PlanItem.Collection -in ($CollectionsRequiringODataType + $AppConfigurationCollections)) {
        $ODataTypeProperty =
            $CurrentObject.PSObject.Properties['@odata.type']
        if ($null -eq $ODataTypeProperty) {
            throw "The GET response for '$($PlanItem.Collection)' does not contain @odata.type."
        }
        $ODataType = [string]$ODataTypeProperty.Value
        if ([string]::IsNullOrWhiteSpace($ODataType)) {
            throw "The @odata.type for '$($PlanItem.Collection)' is empty."
        }
        $RequestBodyObject['@odata.type'] = $ODataType
        $RequestBodyObject[$PlanItem.NameProperty] = $PlanItem.NewName
    }
    #
    # App Protection
    #
    elseif ($PlanItem.Collection -in $AppProtectionCollections) {
        $RequestBodyObject['displayName'] =
            $PlanItem.NewName
    }
    #
    # Everything else
    #
     else {
        $RequestBodyObject[$PlanItem.NameProperty] =
            $PlanItem.NewName
    }
 
 
    $RequestBody = $RequestBodyObject |
        ConvertTo-Json `
            -Depth 10 `
            -Compress
 
    Write-Verbose "PATCH $ResourceUri"
    Write-Verbose "PATCH body: $RequestBody"
 
    try {
        Invoke-MgGraphRequest `
            -Method PATCH `
            -Uri $ResourceUri `
            -Body $RequestBody `
            -ContentType 'application/json' |
                Out-Null
    }
    catch {
        $GraphError = $_.Exception.Message
 
        throw @"
Graph PATCH failed.
 
Resource URI:
$ResourceUri
 
Collection:
$($PlanItem.Collection)
 
Current name:
$($PlanItem.ResolvedCurrentName)
 
Proposed name:
$($PlanItem.NewName)
 
Request body:
$RequestBody
 
Graph error:
$GraphError
"@
    }
 
    Write-Verbose "Verification GET $ResourceUri"
 
    $UpdatedObject = Invoke-MgGraphRequest `
        -Method GET `
        -Uri $ResourceUri `
        -OutputType PSObject
 
    $UpdatedNameProperty = $UpdatedObject.PSObject.Properties[
        $PlanItem.NameProperty
    ]
 
    if ($null -eq $UpdatedNameProperty) {
        throw "The verification response does not contain property '$($PlanItem.NameProperty)'."
    }
 
    $UpdatedName = $UpdatedNameProperty.Value
    $Verified = $UpdatedName -ceq $PlanItem.NewName
 
    return [pscustomobject]@{
        VerifiedName = [string]$UpdatedName
        Verified     = $Verified
        ResourceUri  = $ResourceUri
    }
}
 
#endregion Utility functions
 
 
#region Import and validate the CSV
 
# FIX: trim stray whitespace so 'Name ' in the CSV still matches 'Name' in Intune.
$Mappings = @(
    Import-Csv -Path $CsvPath | ForEach-Object {
        if ($_.CurrentName) { $_.CurrentName = $_.CurrentName.Trim() }
        if ($_.NewName)     { $_.NewName     = $_.NewName.Trim() }
        $_
    }
)
 
Test-RenameMapping -Mappings $Mappings
 
$TotalMappings = $Mappings.Count
$TotalBatches  = Get-TotalBatchCount -ItemCount $TotalMappings -ItemsPerBatch $BatchSize
 
if ($BatchNumber -gt $TotalBatches) {
    throw "Batch $BatchNumber does not exist. There are $TotalMappings mappings and $TotalBatches batches with a batch size of $BatchSize."
}
 
$SkipCount = ($BatchNumber - 1) * $BatchSize
 
$Batch = @(
    $Mappings |
        Select-Object -Skip $SkipCount -First $BatchSize
)
 
if ($Batch.Count -eq 0) {
    throw "Batch $BatchNumber does not contain any mappings."
}
 
Write-Host "Rename batch information" -ForegroundColor Cyan
Write-Host "Total mappings: $TotalMappings"
Write-Host "Batch size:     $BatchSize"
Write-Host "Total batches:  $TotalBatches"
Write-Host "Current batch:  $BatchNumber"
Write-Host "Batch entries:  $($Batch.Count)"
Write-Host ""
 
#endregion Import and validate the CSV
 
 
#region Connect and load the Intune inventory
 
# FIX: the original never called Connect-IntuneGraph, so the first Graph
# request failed with an authentication error.
#Connect-IntuneGraph
 
Write-Host "Loading the Intune configuration inventory..." -ForegroundColor Cyan
 
$Inventory = @(
    Get-IntuneConfigurationIndex
)
 
if ($Inventory.Count -eq 0) {
    throw 'No Intune configuration objects were returned by the configured Graph endpoints.'
}
 
Write-Host ""
Write-Host "Total indexed configuration objects: $($Inventory.Count)" -ForegroundColor Green
Write-Host ""
 
#endregion Connect and load the Intune inventory
 
 
#region Build the rename plan
 
$Plan = @(
    New-RenamePlan `
        -Mappings $Batch `
        -Inventory $Inventory `
        -CurrentBatchNumber $BatchNumber
)
 
Write-Host "Batch rename plan" -ForegroundColor Cyan
 
$Plan |
    Format-Table Status, Kind, CurrentName, ResolvedCurrentName, NewName -AutoSize -Wrap |
    Out-Host
 
$BlockingItems = @(
    $Plan | Where-Object { $_.Status -notin @('Ready', 'NoChange') }
)
 
Write-Host $Plan -ForegroundColor Cyan
 
if ($BlockingItems.Count -gt 0) {
 
    $BlockingItems |
        Export-Csv -Path $LogPath -NoTypeInformation -Encoding utf8
 
    Write-Host ""
    Write-Host "Blocking items were found." -ForegroundColor Red
 
    $BlockingItems |
        Format-Table Status, ExactMatchCount, RelaxedMatchCount, CurrentName, NewName -AutoSize -Wrap |
        Out-Host
 
    throw "The batch contains $($BlockingItems.Count) blocking item or items. No changes were made. Review $LogPath."
}
 
#endregion Build the rename plan
 
 
#region Preview mode
 
if (-not $Execute) {
 
    $Plan |
        Export-Csv -Path $LogPath -NoTypeInformation -Encoding utf8
 
    Write-Host ""
    Write-Host "Preview completed." -ForegroundColor Yellow
    Write-Host "No Intune configurations were changed."
    Write-Host "Preview log: $LogPath"
    Write-Host ""
    Write-Host "Review the plan and then run the same command with -Execute."
 
    return
}
 
#endregion Preview mode
 
 
#region Execute the batch
 
$Results = @()
 
foreach ($Item in $Plan) {
 
    if ($Item.Status -eq 'NoChange') {
 
        $Results += [pscustomobject]@{
            Timestamp           = Get-Date
            BatchNumber         = $BatchNumber
            CurrentName         = $Item.CurrentName
            ResolvedCurrentName = $Item.ResolvedCurrentName
            NewName             = $Item.NewName
            Kind                = $Item.Kind
            Collection          = $Item.Collection
            Id                  = $Item.Id
            Result              = 'Skipped-NoChange'
            Verified            = $true
            VerifiedName        = $Item.ResolvedCurrentName
            Error               = $null
        }
 
        continue
    }
 
    $TargetDescription = "{0}: {1}" -f $Item.Kind, $Item.ResolvedCurrentName
    $ActionDescription = "Rename to '$($Item.NewName)'"
 
    try {
        if ($PSCmdlet.ShouldProcess($TargetDescription, $ActionDescription)) {
 
            Write-Host ""
            Write-Host "Current name: $($Item.ResolvedCurrentName)" -ForegroundColor Cyan
            Write-Host "New name:     $($Item.NewName)" -ForegroundColor Cyan
            Write-Host "Policy type:  $($Item.Kind)" -ForegroundColor DarkGray
 
            $Verification = Invoke-ConfigurationRename -PlanItem $Item
 
            if (-not $Verification.Verified) {
                throw "The PATCH request completed, but verification returned '$($Verification.VerifiedName)' instead of '$($Item.NewName)'."
            }
 
            $Results += [pscustomobject]@{
                Timestamp           = Get-Date
                BatchNumber         = $BatchNumber
                CurrentName         = $Item.CurrentName
                ResolvedCurrentName = $Item.ResolvedCurrentName
                NewName             = $Item.NewName
                Kind                = $Item.Kind
                Collection          = $Item.Collection
                Id                  = $Item.Id
                Result              = 'Renamed'
                Verified            = $Verification.Verified
                VerifiedName        = $Verification.VerifiedName
                Error               = $null
            }
 
            Write-Host "Rename verified successfully." -ForegroundColor Green
        }
        else {
            # FIX: declined confirmations and -WhatIf were previously not logged.
            $Results += [pscustomobject]@{
                Timestamp           = Get-Date
                BatchNumber         = $BatchNumber
                CurrentName         = $Item.CurrentName
                ResolvedCurrentName = $Item.ResolvedCurrentName
                NewName             = $Item.NewName
                Kind                = $Item.Kind
                Collection          = $Item.Collection
                Id                  = $Item.Id
                Result              = 'Skipped-Declined'
                Verified            = $false
                VerifiedName        = $null
                Error               = $null
            }
        }
    }
    catch {
        $ErrorMessage = Get-GraphErrorMessage -ErrorRecord $_
 
        $Results += [pscustomobject]@{
            Timestamp           = Get-Date
            BatchNumber         = $BatchNumber
            CurrentName         = $Item.CurrentName
            ResolvedCurrentName = $Item.ResolvedCurrentName
            NewName             = $Item.NewName
            Kind                = $Item.Kind
            Collection          = $Item.Collection
            Id                  = $Item.Id
            Result              = 'Failed'
            Verified            = $false
            VerifiedName        = $null
            Error               = $ErrorMessage
        }
 
        Write-Host "Rename failed: $($Item.ResolvedCurrentName)" -ForegroundColor Red
        Write-Host $ErrorMessage -ForegroundColor Red
 
        if (-not $ContinueOnError) {
            Write-Host "Stopping the batch after the first failure." -ForegroundColor Yellow
            break
        }
    }
}
 
#endregion Execute the batch
 
 
#region Export execution results
 
$Results |
    Export-Csv -Path $LogPath -NoTypeInformation -Encoding utf8
 
Write-Host ""
Write-Host "Batch execution results" -ForegroundColor Cyan
 
$Results |
    Format-Table Result, Verified, Kind, ResolvedCurrentName, NewName -AutoSize -Wrap |
    Out-Host
 
$RenamedResults = @($Results | Where-Object { $_.Result -eq 'Renamed' })
$FailedResults  = @($Results | Where-Object { $_.Result -eq 'Failed' })
$SkippedResults = @($Results | Where-Object { $_.Result -in @('Skipped-NoChange', 'Skipped-Declined') })
 
Write-Host ""
Write-Host "Renamed: $($RenamedResults.Count)"
Write-Host "Skipped: $($SkippedResults.Count)"
Write-Host "Failed:  $($FailedResults.Count)"
Write-Host "Log:     $LogPath"
Write-Host ""
 
if ($FailedResults.Count -gt 0) {
    throw "$($FailedResults.Count) rename operation or operations failed. Review $LogPath."
}
 
Write-Host "Batch $BatchNumber completed successfully." -ForegroundColor Green
 
#endregion Export execution results