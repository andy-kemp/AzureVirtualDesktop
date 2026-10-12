# Azure Virtual Desktop (AVD) – Automated Enterprise Deployment

This repository uses Bicep for Azure Virtual Desktop infrastructure and PowerShell for orchestration and Windows configuration. The recommended entry point is [Deploy-AvdSolution.ps1](Deploy-AvdSolution.ps1): one command deploys the platform and session hosts while retaining reusable Bicep modules internally. The numbered scripts remain available for the legacy step-by-step workflow.

## Single-Command Deployment

The new workflow automates resource-group creation, storage and shares, the storage private endpoint, host pool, application group, workspace, user access, VM login roles, start-on-connect permissions, optional Azure Private DNS, and session-host provisioning and registration. Session-host preparation runs through the existing VM extension.

### Prerequisites

- PowerShell 7.2 or later and the [standalone Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install#azure-powershell) on `PATH`. Azure CLI is not required for the new runner.
- `Install-Module Az.Accounts, Az.Resources, Az.DesktopVirtualization -Scope CurrentUser` with current versions that support Bicep deployments.
- An existing VNet and subnets in the selected subscription and deployment region, with outbound connectivity for AVD, Entra authentication, extension downloads and the preparation script. VNet creation, peering and egress configuration are not included.
- Existing synced AD/Entra user and admin security groups; supply their Entra object IDs. The Azure Virtual Desktop service principal must exist in the tenant.
- Resource creation permission at subscription scope and role-assignment permission in the AVD resource group. Network permissions must also cover the existing VNet when linking private DNS.
- A Windows 11 Trusted Launch-compatible VM size with available regional quota, AVD licensing, and the hybrid identity prerequisites for Azure Files Kerberos.

Create your local configuration from [avd.config.example.psd1](avd.config.example.psd1) and replace its placeholder GUIDs and environment values. Keep credentials out of the configuration. Pin `SessionHostPrepScriptUrl` to a reviewed commit or versioned artifact before production deployment; the example uses the legacy public branch URL, not your local working copy.

```powershell
Copy-Item ./avd.config.example.psd1 ./avd.config.psd1

./Deploy-AvdSolution.ps1 -ConfigurationFile ./avd.config.psd1 -Mode Validate
./Deploy-AvdSolution.ps1 -ConfigurationFile ./avd.config.psd1 -Mode Preview
./Deploy-AvdSolution.ps1 -ConfigurationFile ./avd.config.psd1 -Mode Deploy
```

`Preview` is the default and does not create resources or rotate registration tokens. `Validate` uses Azure deployment validation, so it requires authentication and is not an offline check. In a fresh environment these modes cover the platform only: Azure session-host validation/what-if needs the resource group and host pool to already exist. The runner warns when that stage is skipped. Neither mode can validate the runtime success of VM extensions.

`Deploy` is the explicit approval to create or update resources. It first deploys [main.bicep](main.bicep), then obtains a four-hour registration token and deploys [02-Deploy-SessionHosts.Bicep](02-Deploy-SessionHosts.Bicep). It revokes the token after the host deployment, including on failure. Passwords and tokens are passed in memory as secure parameters, not command-line arguments or configuration files. Revocation assumes no concurrent session-host onboarding to the same pool; serialize deployments per host pool. Pass `-AdminPassword $securePassword` for unattended execution with an existing Azure login, or enter it securely at the prompt.

Deployments use incremental mode. A failed host deployment leaves successfully created infrastructure in place for investigation and rerun; there is no automatic rollback or deletion. Hosts are named from zero to `NumberOfHosts - 1`. Increasing the count adds hosts; reducing it does not delete hosts or drain sessions. Keep the VM prefix stable on reruns. Adopt existing resources carefully: legacy RBAC assignment names may differ, so inspect what-if and reconcile existing assignments rather than blindly redeploying over a legacy environment.

### Identity And DNS Boundaries

This is a single-command **Azure infrastructure deployment**, not a claim that users can sign in immediately. It verifies that the expected session hosts registered and returns their availability statuses. These environment-specific steps still require your administrators:

- Azure Files Kerberos application admin consent and any explicitly approved Conditional Access exceptions. The new runner does not broadly exclude apps from tenant policies or grant tenant consent.
- NTFS permissions on the `profiles` and `redirections` shares from an authorized domain-connected Windows environment. Azure RBAC does not configure those ACLs. The legacy [05-MountAndSetSharePermissions.ps1](05-MountAndSetSharePermissions.ps1) is available for reference and must be reviewed for your groups and existing permissions.
- Private DNS resolution from every client/host network. `DeployPrivateDns = $true` creates `privatelink.file.<storage-suffix>`, a VNet link and a private-endpoint DNS zone group. For custom/on-premises DNS, configure forwarding through an Azure DNS Private Resolver or your established DNS infrastructure. A VNet link alone does not configure Windows DNS.
- If an equivalent private DNS zone is already centrally linked to the VNet, set `DeployPrivateDns = $false` and have the DNS owner associate the storage private endpoint with that zone. The runner does not discover or change central DNS.
- Intune enrollment prerequisites and policies, device-group membership, optional shutdown/scaling schedules, and a real user sign-in/profile persistence test. These are not automated by the new runner.

The next automation step is to make approved tenant changes and Windows ACL configuration explicit, parameterized operations for your environment, rather than running the broad interactive legacy scripts automatically.

### Local Tests

```powershell
pwsh -NoProfile -File ./tests/Deploy-AvdSolution.Tests.ps1
bicep build ./main.bicep --stdout
bicep build ./02-Deploy-SessionHosts.Bicep --stdout
```

The dependency-free tests use mocked Azure commands to verify deployment order, preview safety, input validation, secure parameter handling, failure propagation and token cleanup. They do not prove live Azure deployment success. Bicep source is authoritative for the new workflow; existing checked-in ARM JSON files are legacy snapshots and are not used by the runner.

---

## 📁 Repository Contents

| Step | File Name                                | Purpose                                                                             | Run Location                  |
|------|------------------------------------------|-------------------------------------------------------------------------------------|-------------------------------|
| 1    | `01-Deploy-CoreAVDInfra.bicep/json`      | Deploy core AVD infra: storage, networking, host pool, app group, workspace, RBAC    | Azure CLI/Portal              |
| 2    | `02-Deploy-SessionHosts.Bicep/json`      | Deploy and register session host VMs with all required extensions                    | Azure CLI/Portal              |
| 2a   | `02a-SessionHostPrep.ps1`                | Prepare session host OS for FSLogix, Kerberos, and cleanup (runs as VM extension)    | VM Extension (auto)           |
| 3    | `03-AVD-Ent-Config.ps1`                  | Configure AAD groups, RBAC, VM auto-shutdown, Conditional Access exclusions          | Azure Cloud Shell/PowerShell  |
| 4    | `04-Add-StorageDNSRecord.ps1.ps1`        | Add internal DNS A record for storage private endpoint                               | DNS/Admin Server              |
| 5    | `05-MountAndSetSharePermissions.ps1`     | Mount Azure Files shares, set NTFS permissions for FSLogix                           | Hybrid-joined Device          |

---

## 🚀 Legacy Step-By-Step Workflow

1. **Clone the repository**
   ```sh
   git clone https://github.com/andrew-kemp/AzureVirtualDesktop.git
   cd AzureVirtualDesktop
   ```

2. **Follow the deployment steps in order:**

   - **Step 1:** Deploy core infrastructure  
     `01-Deploy-CoreAVDInfra.bicep` or `01-Deploy-CoreAVDInfra.json`  
     _Deploy using Azure CLI, PowerShell, or the portal. You will need to provide details such as storage account name, Kerberos AD settings, vNet/subnet info, and AAD group object IDs._

   - **Step 2:** Deploy session hosts  
     `02-Deploy-SessionHosts.Bicep` or `02-Deploy-SessionHosts.json`  
     _Requires registration key output from the Host Pool in Step 1. Specify session host count, admin credentials, vNet/subnet, storage info, and optionally DNS servers._

   - **Step 2a:** Session host preparation  
     `02a-SessionHostPrep.ps1`  
     _Runs automatically as a VM custom script extension—do not run manually. Configures FSLogix, Cloud Kerberos, and removes unwanted apps._

   - **Step 3:** Configure AVD roles, groups, and policies  
     `03-AVD-Ent-Config.ps1`  
     _Run interactively in Azure Cloud Shell or PowerShell with required modules. Sets up or reuses AAD groups, applies RBAC, enables VM auto-shutdown, and assists with Conditional Access exclusions._

     **⚠️ IMPORTANT: After running this script, you MUST manually grant admin consent for the Storage Account App in the Entra Portal.**
     - The app will be listed as `[Storage Account] mystorage.file.core.windows.net` (replace with your storage account name).
     - Go to **Azure Portal > Entra ID > App registrations > [Storage Account]... > API permissions > Grant admin consent**.
     - **This step is mandatory – if you skip it, FSLogix shares and user profiles will not work!**

   - **Step 4:** Add DNS record for storage  
     `04-Add-StorageDNSRecord.ps1.ps1`  
     _Run on your DNS management server. Prompts for DNS server, zone, storage account, and private endpoint IP. Creates missing zones/records as needed._

   - **Step 5:** Mount shares and set permissions  
     `05-MountAndSetSharePermissions.ps1`  
     _Run on a hybrid-joined Windows device. Maps FSLogix profile and redirection shares, applies secure NTFS permissions for user/admin groups, then disconnects._

---

## 📝 Script & Template Details

- **01-Deploy-CoreAVDInfra (Bicep/JSON):**
  - Deploys storage (with Azure AD Kerberos/private endpoint), networking, FSLogix shares, host pool, app group, and workspace.
  - Sets up least-privilege RBAC for storage access using group Object IDs.
  - Outputs resource IDs for use in following steps.

- **02-Deploy-SessionHosts (Bicep/JSON):**
  - Provisions Windows 11 AVD session hosts, joins vNet, configures DNS, registers hosts to the pool.
  - Attaches extensions for Entra ID join, guest attestation, and session host prep.
  - Outputs post-deployment manual steps for AVD app registration, CA policy, folder permissions, and DNS.

- **02a-SessionHostPrep.ps1:**
  - Configures FSLogix registry, enables Cloud Kerberos, and removes preinstalled UWP/Store apps.
  - Runs automatically on each session host as a VM extension.

- **03-AVD-Ent-Config.ps1:**
  - Interactive PowerShell script for configuring AAD groups (user, admin, device), assigning permissions, and updating Conditional Access policies.
  - Ensures correct group memberships, role assignments, and auto-shutdown schedules.
  - Assists with CA exclusion for the Storage App and prompts for required admin consent.
  - **Manual Step Required:**  
    - After the script, go to the Entra Portal and grant admin consent to the Storage Account App (named `[Storage Account] mystorage.file.core.windows.net`).  
    - **Without this, FSLogix profile shares will NOT work.**

- **04-Add-StorageDNSRecord.ps1.ps1:**
  - Adds a DNS A record for your storage account’s private endpoint in the correct DNS zone.
  - Ensures the zone and record exist, creating as necessary.
  - Intended for Windows DNS servers with the DNSServer module.

- **05-MountAndSetSharePermissions.ps1:**
  - Maps `profiles` and `redirections` shares by UNC path, sets NTFS permissions for AVD user/admin groups.
  - Designed for hybrid-joined Windows clients.
  - Verifies share mapping and permission application, cleans up after execution.

---

## ⚠️ Prerequisites

- Azure subscription with resource deployment permissions
- Azure CLI, PowerShell, and/or Portal access
- Admin permissions on AD/DNS servers (for steps 4 & 5)
- [FSLogix licensing](https://docs.microsoft.com/en-us/fslogix/)
- Hybrid identity setup (Azure AD + Active Directory)
- PowerShell modules: `Az`, `Microsoft.Graph`, `DNSServer` as required

---

## 🔐 Security & Best Practices

- All storage and AVD resources use private endpoints and strict network ACLs
- Permissions are group-based for least-privilege access
- Manual steps (DNS, consent, CA) are clearly indicated in output/scripts
- Scripts and templates are idempotent and safely re-runnable

---

## 🤝 Contributions & Support

Maintained by [andrew-kemp](https://github.com/andrew-kemp).

Contributions and feedback are welcome!  
Please open [issues](https://github.com/andrew-kemp/AzureVirtualDesktop/issues) or submit pull requests for improvements and fixes.

---

## 📄 License

MIT License – see [LICENSE](LICENSE) for details.