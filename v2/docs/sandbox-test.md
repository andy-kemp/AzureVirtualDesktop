# Sandbox test runbook: V2 Preview and Deploy

Status: ready for a first sandbox run. Date: 2026-10-14. Use a **dedicated sandbox subscription**. Deploy creates real, billable resources and changes Entra group membership for dedicated users.

## 1. Tools (once)

```powershell
winget install Microsoft.PowerShell
winget install Microsoft.Bicep
pwsh
Install-Module Az.Accounts, Az.Resources, Az.Network, Az.DesktopVirtualization, Az.KeyVault -Scope CurrentUser
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser   # dedicated users only
```

Restart the terminal after installing Bicep so `bicep` is on `PATH`.

## 2. Sandbox prerequisites

| Item | Notes |
| --- | --- |
| Resource group | Create it in the target region first. V2 does not create resource groups. |
| VNet and two subnets | One for session hosts, one for the storage private endpoint (shared pools). Hosts need outbound internet to reach AVD and the prep script. |
| Entra groups | An AVD users group and an AVD admins group (different groups). |
| AVD service principal object ID | `(Get-AzADServicePrincipal -ApplicationId 9cdead84-a844-4324-93f2-b2e6bb768d07).Id` |
| Key Vault secret | A strong local admin password, e.g. `https://<vault>.vault.azure.net/secrets/avd-admin`. Your account needs *Key Vault Secrets User* on it. |
| Your Azure rights | Owner on the workload resource group (it creates role assignments), and rights to join the subnets (e.g. Network Contributor on the VNet resource group). |
| Autoscale (optional) | Assign *Desktop Virtualization Power On Off Contributor* to the AVD service principal at **subscription** scope. Preview warns if missing. |
| Dedicated users (optional) | You must be able to manage the AVD users group's membership (e.g. group owner). |

## 3. Publish the session host prep script

Session hosts download the prep script over HTTPS and V2 checks its SHA-256. Commit and push `v2/scripts/session-host-prep.ps1`, then use a URL pinned to that **commit SHA** (not `main`):

```powershell
$uri = 'https://raw.githubusercontent.com/andy-kemp/AzureVirtualDesktop/<commit-sha>/v2/scripts/session-host-prep.ps1'
Invoke-WebRequest $uri -OutFile $env:TEMP\prep.ps1
(Get-FileHash $env:TEMP\prep.ps1 -Algorithm SHA256).Hash.ToLower()
```

Hash the **downloaded** file. Git line-ending conversion can make the local copy differ.

## 4. Create your configuration

```powershell
cd C:\GitHub\AzureVirtualDesktop
.\v2\avd.ps1 -Mode New -OutputFile .\v2\sandbox\avd.json
```

Answer the questions, then edit `v2\sandbox\avd.json` and replace every example value with your sandbox details:

- `tenantId`, `subscriptionId`
- `target` (resource group, region, prefix)
- `network`
- `identity.avdServicePrincipalObjectId`
- `accessGroups`
- `storage.accountName` (globally unique)
- `sessionHosts.adminPasswordSecretUri`
- `artifacts` (URI and SHA-256 from step 3)

`execution` must name a user-assigned managed identity in the same subscription. It's recorded for the managed-identity deployment path, but a local `-AsSignedInUser` run doesn't use it.

```powershell
.\v2\avd.ps1 -Mode Validate -ConfigurationFile .\v2\sandbox\avd.json
```

`v2/.gitignore` keeps `v2\sandbox\` and plan files out of source control because they contain real IDs.

## 5. Preview (read-only)

```powershell
.\v2\avd.ps1 -Mode Preview -ConfigurationFile .\v2\sandbox\avd.json
```

Preview signs in to the configured tenant and subscription if needed, checks the resource group, VNet, subnets, prep script digest and autoscale role, and runs Azure what-if. It writes `v2\sandbox\avd.plan.json`, valid for 24 hours. On a first run only the platform can be previewed, because the host pool doesn't exist yet. Fix any **BLOCKED** items and preview again.

## 6. Deploy

```powershell
.\v2\avd.ps1 -Mode Deploy -ConfigurationFile .\v2\sandbox\avd.json -AsSignedInUser
```

Type the resource group name to approve. Deploy refuses the plan if it has blockers, is older than 24 hours, or the configuration or templates changed since Preview.

The order matches the root runner:

1. Read the admin password from Key Vault.
2. Deploy the platform.
3. Create a 4-hour registration token.
4. Deploy the session hosts.
5. **Always** revoke the token.
6. Wait up to 10 minutes for host registration.

For dedicated pools it then sets each host's assigned user and adds the users to the AVD users group with your delegated Graph permission. It signs you in to Graph if needed.

Deploy finishes with a list of manual tasks, such as Azure Files consent, the MFA exclusion for the storage app, ACLs, the autoscale role, and a test sign-in.

## 7. Try expansion

```powershell
.\v2\avd.ps1 -Mode Expand  -ConfigurationFile .\v2\sandbox\avd.json -AddHosts 1                     # shared pools
.\v2\avd.ps1 -Mode AddUser -ConfigurationFile .\v2\sandbox\avd.json -UserPrincipalName user@domain  # dedicated pools
.\v2\avd.ps1 -Mode Preview -ConfigurationFile .\v2\sandbox\avd.json
.\v2\avd.ps1 -Mode Deploy  -ConfigurationFile .\v2\sandbox\avd.json -AsSignedInUser
```

## 8. Verify and clean up

- Sign in as a test user at <https://windows.cloud.microsoft> or with the Windows App. Check the desktop launches, the profile persists (shared pools) and scaling behaves as expected.
- Clean up by deleting the sandbox resource group. V2 never deletes resources. Remove test users from the AVD users group yourself.

## What to report back

The Preview and Deploy output (it never prints secrets or tokens), any failing step, and the manual tasks list. Known untested areas are flagged in ADR 0009 (personal scaling plan type) and ADR 0011 (cloud-only preview ACLs).
