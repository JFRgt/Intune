<#
.SYNOPSIS
    Convert iOS device ownership from 'personal' to 'company' for supervised devices.
.DESCRIPTION
    The script finds all iPhones and iPads that an organization is fully controlling (supervised) 
    but are mistakenly labeled as belonging to the employee (personal), and then it fixes that error by changing the label to 
    'company' owner, then forces the device to sync the change.
.NOTES
    ScriptVersion: 1.0
    DateModified: 06/11/2025
    Author: Jean-Francois Rigot (modified by 'Le Chat' by Mistral)
#>
 
function ConnectMgGraphUsingMI {
    if($PSPrivateMetadata.JobId) {
        try {
            Connect-MgGraph -Identity -NoWelcome
        }
        catch {
            Write-Error -Message $_.Exception
            throw $_.Exception
        }
    }
}
 
$VerbosePreference = "silentlyContinue"
 
function Write-ToLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [String]$message,
        [Parameter(Mandatory=$false)]
        [Boolean]$warning,
        [Parameter(Mandatory=$false)]
        [Boolean]$errorFlag
    )
    if(!$PSBoundParameters.ContainsKey('error')) {
        $error = $False
    }
    $time = Get-Date -Format HH:mm:ss
    $date = Get-Date -Format dd-MM-yyyy
    $timestamp = "[" + $time + " " + $date + "]"
    [string]$logstring = $timestamp + " " + $message
 
    if($error) {
        Write-Error $logstring
    } elseif($warning) {
        Write-Warning $logstring
    } else {
        Write-Verbose $logstring -Verbose
    }
}
 
function ConvertIOSDeviceOwnership {
    begin {
        $body = @{ ownerType = "company" } | ConvertTo-Json
    }
    process {
        try {
            # Step 1: Get all iOS devices with personal ownership
            $filter = "managementAgent eq 'mdm' and operatingSystem eq 'ios' and ownerType eq 'personal'"
            $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=$filter`&`$select=id,serialNumber,ownerType,isSupervised"
            $managedDevices = Invoke-MgGraphRequest -Method Get -OutputType PSObject -Uri $uri
 
            if ($managedDevices.value) {
                # Step 2: Filter locally for supervised devices
                $supervisedPersonalDevices = $managedDevices.value | Where-Object { $_.isSupervised -eq $true }
 
                if ($supervisedPersonalDevices) {
                    foreach ($device in $supervisedPersonalDevices) {
                        Write-Output "Found supervised personal device: $($device.serialNumber) (ID: $($device.id))"
                        # Update ownership
                        Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($device.id)" -Body $body -ContentType "application/json"
                        Write-Output "Device ($($device.id)) ownership changed to Company..."
                        # Force sync
                        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($device.id)/microsoft.graph.syncDevice"
                    }
                } else {
                    Write-Output "No supervised personal iOS devices found."
                }
            } else {
                Write-Output "No personal iOS devices found."
            }
        }
        catch {
            Write-Error "Error: Failed to process devices. $_"
        }
    }
    end {
        Write-Output ""
        Write-Output "Closing MgGraph session..."
        Disconnect-MgGraph | Out-Null
    }
}
 
Write-ToLog -message "Connect to MgGraph"
ConnectMgGraphUsingMI
ConvertIOSDeviceOwnership