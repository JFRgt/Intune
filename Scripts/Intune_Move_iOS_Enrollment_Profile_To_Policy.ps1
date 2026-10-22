<#
.SYNOPSIS
    Reassigns Apple ADE/DEP devices to a specified enrollment profile in Microsoft Intune.
.DESCRIPTION
    Executes a POST request to the Microsoft Graph API beta endpoint to update device profile 
    assignments for automated device enrollment token instances.
#>

# 1. Define configuration identifiers
$DepOnboardingSettingId = "<DEP_ONBOARDING_SETTING_GUID>"
$TargetProfileGuid      = "<TARGET_ENROLLMENT_PROFILE_GUID>"

# The Graph API enrollment profile segment requires the composite ID format: {depOnboardingSettingId}_{targetProfileGuid}
$FullEnrollmentProfileId = "${DepOnboardingSettingId}_${TargetProfileGuid}"

# 2. Define the array of target device serial numbers or device IDs
$DeviceIds = @(
    "<SERIAL_NUMBER_OR_DEVICE_ID>"
    # Add additional device identifiers as needed
)

# 3. Construct the API Request URI
$Uri = "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$DepOnboardingSettingId/enrollmentProfiles('$FullEnrollmentProfileId')/updateDeviceProfileAssignment"

# 4. Construct the payload body
$Params = @{
    "deviceIds" = $DeviceIds
}

# 5. Execute the Microsoft Graph request
Invoke-MgGraphRequest -Method POST -Uri $Uri -Body ($Params | ConvertTo-Json -Depth 10) -ContentType "application/json"
