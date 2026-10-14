# Sandbox test runbook: V2 end to end

Status: ready for a first sandbox run. Date: 2026-10-14. Use a **dedicated sandbox subscription**. Deploy creates real, billable resources, including VMs, a NAT gateway and storage. For dedicated users it also changes Entra group membership.

## 1. Tools (once)

```powershell
winget install Microsoft.PowerShell
winget install Microsoft.Bicep
pwsh
Install-Module Az.Accounts, Az.Resources, Az.Network, Az.DesktopVirtualization, Az.KeyVault -Scope CurrentUser
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser   # dedicated users only
```

Restart the terminal after installing Bicep so `bicep` is on `PATH`.

## 2. What you need

- **Owner** on the sandbox subscription. The script registers resource providers, creates the resource group and makes role assignments.
- AVD users and admins groups. Either pick existing ones, or let `New` create them (you become owner and can add yourself to the users group). Creating groups needs your tenant to allow users to create security groups, or a Groups Administrator role.
- Autoscale needs *Desktop Virtualization Power On Off Contributor* for the Azure Virtual Desktop service principal at subscription scope; AVD refuses to create a scaling plan without it. Deploy grants it in the foundation stage, which is why you need Owner.
- For `-PostDeploy` (step 5), an Entra admin role that can consent to the Graph scopes it requests: Cloud Application Administrator for the storage app, plus Conditional Access Administrator (or Security Administrator) for the Conditional Access exclusion. Global Administrator covers both.
- The `Microsoft.Graph.Authentication` PowerShell module for the Graph steps.

Everything else is created for you ([ADR 0013](adr/0013-foundation-stage.md)):

- the resource group;
- a VNet with subnets, an NSG and a NAT gateway;
- a Key Vault with a generated admin password;
- the deployment managed identity;
- the AVD platform, FSLogix storage (shared pools) and session hosts.

## 3. Answer the questions

**In the browser (recommended):**

```powershell
cd C:\GitHub\AzureVirtualDesktop
.\v2\avd.ps1 -Mode Web
```

Your browser opens a local wizard (keep the PowerShell window open). Choose from dropdowns, search or create groups, and check the sizing; the page also checks that the VM size is available to your subscription in the region and offers alternatives if not. Select **Create configuration** to write `v2\sandbox\avd.json`, then **Run Preview** to run step 4 in the page. When Preview has no blockers the page shows the Deploy command to copy. Select **Close the wizard** when you're done.

**Or in the terminal:**

```powershell
.\v2\avd.ps1 -Mode New -OutputFile .\v2\sandbox\avd.json
```

You'll be asked to sign in, then:

1. Subscription.
2. Region.
3. Prefix (for example `AVD`).
4. Resource group (default `rg-<prefix>-avd`).
5. **New VNet** (recommended) or existing. A non-overlapping range is proposed.
6. Users and admins groups: pick existing groups by name, or create new ones.
7. Shared or dedicated, persona, user count and peak concurrency.
8. For shared pools, hybrid or cloud-only identities. Hybrid also asks for your AD domain name and GUID.
9. Business-hours scaling or always available.
10. The workspace and desktop names users see (defaults "<prefix> Workspace" and "<prefix> Virtual Desktop").
11. For shared pools, what happens if a profile can't load: a temporary profile (easier while piloting) or a blocked sign-in (recommended for production).

The file is written to `v2\sandbox\`, which `v2/.gitignore` keeps out of source control.

## 4. Preview (no changes)

```powershell
.\v2\avd.ps1 -Mode Preview -ConfigurationFile .\v2\sandbox\avd.json
```

Preview shows the what-if for the foundation and lists blockers and warnings, then writes a plan valid for 24 hours. On a brand-new estate the platform and hosts can't be previewed until the foundation exists; Deploy runs the stages in order.

Preview also checks compute capacity in the region. If the VM size isn't offered to your subscription, or the family or regional vCPU quota can't hold every host, that's a blocker and Preview shows the numbers (for example, 2 × Standard_D8s_v5 needs 16 standardDSv5Family vCPUs). To fix it, request a quota increase (portal → Quotas → Compute) or edit `vmSize` or `count` in the configuration. Check usage yourself with `Get-AzVMUsage -Location uksouth`.

## 5. Deploy

```powershell
.\v2\avd.ps1 -Mode Deploy -ConfigurationFile .\v2\sandbox\avd.json -AsSignedInUser -PostDeploy
```

Type the resource group name to approve. Deploy then runs these steps:

1. Register any missing resource providers.
2. **Foundation:** only what is missing among the resource group, network with NAT, Key Vault with a generated password (never shown, never rotated) and managed identity. Reruns skip it once everything exists, so changes you make to those resources are kept.
3. **Platform:** host pool, app group, workspace (with your workspace name), FSLogix storage with private endpoint and DNS, scaling plan, and role assignments. Then the desktop tile is renamed to your desktop name.
4. **Session host validation:** Azure validates the host deployment with a placeholder token before a real one exists. Failures show the nested Azure error codes (such as `QuotaExceeded` or `SkuNotAvailable`) rather than a generic preflight message.
5. **Registration token:** a 4-hour token, used by the session hosts, then always revoked.
6. **Session hosts:** deployed with the token, then registration is checked for up to 10 minutes. New shared-pool hosts are then restarted once so their Microsoft Entra Kerberos setting applies.
7. **Dedicated pools only:** assign hosts to named users and add them to the users group with your delegated Graph permission.
8. **Post-deployment configuration (`-PostDeploy`, [ADR 0015](adr/0015-post-deploy-configuration.md)):** signs in to Microsoft Graph and:
   - enables Microsoft Entra authentication for RDP for the tenant (needed for the hosts' single sign-on);
   - grants admin consent to the storage account's Entra app, adds the cloud-group tag (cloud-only) and the `privatelink` identifier URIs;
   - lists the Conditional Access policies that require MFA for all resources and, **after you type `yes`**, excludes only the storage app from them. Microsoft-managed policies can't be changed and are listed instead, as are policies with device or privileged-role conditions you should review;
   - sets FSLogix's recommended folder permissions on the profile share. The storage firewall is opened to **your public IP only** for a minute or two, with a temporary data role, then closed again and the role removed, even if something fails;
   - checks each host is Entra joined and Intune managed, and runs a new enough Windows build.
9. **Manual tasks:** whatever couldn't be done automatically, plus a sign-in test.

Without `-PostDeploy`, step 8 is listed as manual tasks. You can run it any time later, including on an estate deployed before this option existed:

```powershell
.\v2\avd.ps1 -Mode PostDeploy -ConfigurationFile .\v2\sandbox\avd.json
```

Use `-ConditionalAccess Report` to only list the Conditional Access changes, or `-OperatorPublicIp <ip>` if your public IP can't be detected (it's looked up with api.ipify.org).

Run Preview again before every Deploy, because each plan is bound to the configuration it was made from.

## 6. Try expansion

```powershell
.\v2\avd.ps1 -Mode Expand  -ConfigurationFile .\v2\sandbox\avd.json -AddHosts 1                     # shared pools
.\v2\avd.ps1 -Mode AddUser -ConfigurationFile .\v2\sandbox\avd.json -UserPrincipalName user@domain  # dedicated pools
.\v2\avd.ps1 -Mode Preview -ConfigurationFile .\v2\sandbox\avd.json
.\v2\avd.ps1 -Mode Deploy  -ConfigurationFile .\v2\sandbox\avd.json -AsSignedInUser
```

## 7. Verify and clean up

- Sign in as an **ordinary (non-admin) test user** from the AVD users group at <https://windows.cloud.microsoft> or with the Windows App. Admin accounts are often caught by privileged-access Conditional Access policies that block the storage sign-in from a session host. Check the desktop launches, the profile persists (shared pools) and scaling behaves as expected.
- In the session, `klist get cifs/<storage-account>.file.core.windows.net` should return a ticket and `\\<storage-account>.file.core.windows.net\profiles` should contain a `<user>_<SID>` folder with a VHDX. If the profile doesn't mount, open the storage app's entry in Entra ID sign-in logs and check its Conditional Access tab.
- To clean up, delete the resource group; V2 never deletes resources. The Key Vault stays soft-deleted for 7 days. Purge it (`Remove-AzKeyVault -VaultName <name> -Location <region> -InRemovedState`) before reusing the same prefix and resource group, or Preview will block. Remove test users from the AVD users group yourself.
- Deleting the resource group leaves the hosts' Entra and Intune device records, and the storage app's Conditional Access exclusions. Delete stale devices before redeploying with the same host names (PostDeploy reports duplicates).

## Without discovery

`-Offline` keeps the old behaviour: answers are applied to a base configuration that you edit by hand. Existing-network mode expects the VNet to have outbound internet access already.

## What to report back

Send the New, Preview and Deploy output (it never prints secrets or tokens), any failing step, and the manual tasks list. Known untested areas: the personal scaling plan type (ADR 0009), the PostDeploy folder-permission step against a live storage account (ADR 0015) and Key Vault role propagation timing on reruns (ADR 0013).
