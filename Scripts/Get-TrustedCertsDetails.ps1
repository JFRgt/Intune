
<#
.SYNOPSIS
    From Intune, retrieve the details of the uploaded trusted certificates not visible in the console.
.DESCRIPTION
    This PowerShell script echeck for the Trusted certificates, then make them readable.
    You must ensure to use the dedicated App Registration (Client Id) and the Tenant Id to connect to Microsoft Graph.
.EXAMPLE
    PS> ./
.LINK
    N/A
.NOTES
    ScriptVersion: 1.0
    DateModified: 09 July 2026
    Author: Jean-Francois RIGOT
#>


[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ClientId
)


# Import MgGraph Modules
 
If (!(Get-module "Microsoft.Graph.Authentication")) {
    Import-Module Microsoft.Graph.Authentication
    Write-host -ForegroundColor White "Importing-Module Microsoft.Graph.Authentication"
}else {
    Write-Host -ForegroundColor Green "Module Microsoft.Graph.Authentication already imported"
}
 
If (!(Get-module "Microsoft.Graph.Beta.Devices.CorporateManagement")) {
    Import-Module Microsoft.Graph.Beta.Devices.CorporateManagement
    Write-host -ForegroundColor White "Importing-Module Microsoft.Graph.Beta.Devices.CorporateManagement"
}else {
    Write-Host -ForegroundColor Green "Module Microsoft.Graph.Beta.Devices.CorporateManagement already imported"
}
 
If (!(Get-module "Microsoft.Graph.Groups")) {
    Import-Module Microsoft.Graph.Groups
    Write-host -ForegroundColor White "Importing-Module Microsoft.Graph.Groups"
}else {
    Write-Host -ForegroundColor Green "Module Microsoft.Graph.Groups already imported"
}

##### Required Parameters

# Connect to Graph
Connect-MgGraph `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -Scopes @(
        "DeviceManagementConfiguration.Read.All"
    ) `
    -NoWelcome

$mgRequest = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/users/$($userId)"-OutputType HttpResponseMessage
 
$AccessToken = $mgRequest.RequestMessage.Headers.Authorization.Parameter
 
$Headers = @{
Authorization = "Bearer $AccessToken"
}
 
# Retrieve all device configuration profiles
$Uri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"
 
$Profiles = (Invoke-RestMethod `
-Method Get `
-Uri $Uri `
-Headers $Headers).value
 
# Filter for Trusted Root Certificate profiles
$TrustedCertProfiles = $Profiles | Where-Object {
$_.'@odata.type' -match 'trustedrootcertificate'
}
 
Add-Type -AssemblyName System.Security
 
$report = @()
 
foreach ($TrustedProfile in $TrustedCertProfiles) {
    $CertBase64 = $TrustedProfile.trustedRootCertificate
    $Bytes = [Convert]::FromBase64String($CertBase64)
    $Cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Bytes)
 
    $report += [PSCustomObject]@{
        ProfileName    = $TrustedProfile.displayName
        FileName       = $TrustedProfile.certFileName
        Subject        = $Cert.Subject
        Issuer         = $Cert.Issuer
        Thumbprint     = $Cert.Thumbprint
        SerialNumber   = $Cert.SerialNumber
        NotBefore      = $Cert.NotBefore
        NotAfter       = $Cert.NotAfter
        HasPrivateKey  = $Cert.HasPrivateKey
    }
}
 
$report | Select-Object ProfileName, Filename, NotBefore, NotAfter, Issuer | Format-Table -AutoSize
 
# Disconnecting
$answer = (Read-Host "Would you like to disconnect? (Y/N) [Default: N]").Trim().ToUpper()
$answer = if ($answer -in @("Y", "")) { "Y" } else { "N" }

# Actually execute the disconnection based on the answer
if ($answer -eq "Y") {
    Disconnect-MgGraph
    Write-Host -ForegroundColor Yellow "Disconnected from Microsoft Graph."
} else {
    Write-Host -ForegroundColor Green "Still connected to Microsoft Graph."
}
