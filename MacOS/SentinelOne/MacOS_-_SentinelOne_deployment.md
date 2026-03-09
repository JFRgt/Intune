# MacOS - SentinelOne Deployment

The configuration is based on an initial document provided by SentinelOne regarding the deployment of the solution using Intune for MacOS devices.

But that one gave me some headaches, as it contains a concatenated version of the configuration file that was always failing. So, I had to make my AI friends rewrite the structure a bit and split it up into several parts.

I am not saying this is the ultimate SentinelOne deployment doc for MacOS on Intune, I'm just documenting what worked for me.

Two main processes occur simultaneously during automated deployment, eliminating the need for end-users to interact with or disable SentinelOne Agent Services throughout installation.

- **The first process** involves setting up essential runtime permissions and settings so the SentinelOne Agent can properly function and interface with macOS, enabling thorough monitoring and protection of each endpoint according to the agent's full capabilities.
- **The second process** covers deploying and installing the SentinelOne Agent across your macOS fleet, a high-level overview of this process is provided below.

> Keep in mind that Microsoft Intune serves only as the delivery mechanism for the SentinelOne Agent. After the agent is delivered to a macOS endpoint, any subsequent updates or configuration changes should be managed within the SentinelOne Console unless SentinelOne Support suggests otherwise.

---

## Configuring the Necessary Runtime Permissions and Settings

We need to configure several settings before starting to deploy the app. One of the configuration files contains the activation token for the product.

> ⚠️ **If you don't deploy this one, the deployment of the app will FAIL.** The token is provided by an authorized agent.

Configuration can be either `.xml` or `.mobileconfig` files. For the sake of consistency, let's consider `.mobileconfig` files only.

### Configuration Files (Links on GitHub)

| Description | Config | File |
|---|---|---|
| MacOS - SentinelOne - Agent registration Profile | Contains the activation key | `SentinelOne RegistrationToken.mobileconfig` |
| MacOS - SentinelOne - Full disk access - Bluetooth and Notifications | Allow disk access, BT login items and Notifications | `SentinelOne Agent FullDisk_BT_Notifications.mobileconfig` |
| MacOS - SentinelOne - Network Filter Validation | Activates and authorizes the SentinelOne Web Content Filter | `SentinelOne__Network-Filter_Validation-2.mobileconfig` |
| MacOS - SentinelOne - Network Monitoring Extension | Pre-approves the SentinelOne System Extension so it can load automatically | `SentinelOne_-_NetworkMonitoring_Extension_.mobileconfig` |
| MacOS - SentinelOne - NonRemovable from UI System Extension | Prevents users from turning off network monitoring for macOS Sequoia and above | `NonRemovableFromUISystemExtensions.mobileconfig` |
| MacOS - SentinelOne Removable System Extension | Enables clean, remote uninstallation of the security agent by an admin for macOS Sonoma and below | `SentinelOne Removable System Extension.mobileconfig` |
| MacOS - SentinelOne - Service Management | Prevents users from disabling or removing SentinelOne background services and login items | `SentinelOne Agent ServiceManagement.mobileconfig` |

---

## Upload to Intune

Now that we have the files, create the different configurations in Intune as follows:

Navigate to **Intune Admin Center** => **Devices** => **Manage Devices** => **Configuration** and click **Create => New Policy**, then select **macOS** => **Templates** => **Custom**.

For each configuration:

- Give it a **Profile name**
- Select **Device Channel**
- Upload the `.xml` or `.mobileconfig` file from the table above
- Assign it to the target group (e.g. `MacOS_SentinelOne_Users`)
- Check on the device — these configuration profiles should land quite rapidly on the target devices

---

## Deploying and Installing the SentinelOne Agent

The installation package (or Pkg) should be downloaded from the SentinelOne console from an authorized agent.

### Create the Installation Package in Intune

1. Navigate to **Intune Admin Center** => **Apps** => **Platforms** => **macOS** and click **Create**.
2. Select **macOS App (PKG)** and click **Select** — this takes you to the **Add App** wizard.
3. Select **Select App Package File** and select the SentinelOne Agent PKG file for upload.
4. Populate the **App Information** section.
5. Leave **Pre/Post Installation Scripts** empty — they are not needed.
6. Set **App Requirements** baseline to **macOS Sequoia 15.0**.

### Detection Rules

Under **Detection Rules**, ensure the following:

- **Ignore App Version** — Set to `Yes`
- **Included Apps:**
  - `com.sentinelone.sentinel-agent` [app_version]

> ⚠️ **Note:** If there are any other **Included Apps** added, remove them.

### Final Step

Assign the app to your target group (e.g. `MacOS_SentinelOne_Users`).

That's it.
