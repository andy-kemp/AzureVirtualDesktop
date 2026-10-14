# ADR 0015: Post-deployment Entra and profile-share configuration

Status: Accepted. Date: 2026-10-14.

## Context

The first live sandbox deployment worked, but users could not sign in until an administrator completed several steps by hand:

- Enable Microsoft Entra authentication for RDP (Windows Cloud Login). The hosts use Entra single sign-on (`enablerdsaadauth`), and nothing configured this.
- On the storage account's auto-created Entra app:
  - grant admin consent;
  - add the `kdc_enable_cloud_group_sids` tag (cloud-only identities);
  - add `privatelink` identifier URIs, because storage is reached through a private endpoint and Kerberos otherwise falls back to NTLM ("error 1326").
- Exclude that app from Conditional Access policies that require MFA (Entra Kerberos to Azure Files cannot do MFA).
- Replace the share's default ACLs (Authenticated Users: Modify, inherited), which let users open each other's profiles.

Testing also showed:

- Hosts were missing `LoadCredKeyFromProfile`.
- Nothing restarted the hosts after setting `CloudKerberosTicketRetrievalEnabled`.
- Every deployment showed the desktop as "SessionDesktop".

## Decision

**Display names (contract 1.5.0).** Optional `display.workspaceName` and `display.desktopName`, defaulting to "<prefix> Workspace" and "<prefix> Virtual Desktop":

- The workspace friendly name is set in Bicep.
- ARM templates cannot set the SessionDesktop friendly name, so Deploy sets it after the platform with `Update-AzWvdDesktop`. A failure becomes a manual task with the exact command.

**FSLogix behaviour.**
- Optional `fslogix.preventTempProfile` sets `PreventLoginWithFailure` and `PreventLoginWithTempProfile`.
- Host prep always sets `LoadCredKeyFromProfile` and no longer removes framework or shell packages.
- Deploy restarts the VMs it created, through ARM, after they register, and tags them `avdv2-kerberos-restart`. The restart can't run inside host prep because the host-pool DSC extension runs after it. Existing VMs without the tag (for example after a failed run) may have users signed in, so they get a manual "restart once" task instead.
- Preview and Deploy refuse `preventTempProfile` when the pinned prep script doesn't support it.

**PostDeploy.** Run as `-Mode PostDeploy`, or `-Mode Deploy -PostDeploy`, with the operator's delegated Graph and Azure rights. Every step is idempotent and reports "done" or "manual":

1. Enable Entra RDP authentication on Windows Cloud Login if it is not already on (tenant-wide; `Application-RemoteDesktopConfig.ReadWrite.All`).
2. Storage app:
   - Create or extend the `AllPrincipals` grant for `openid profile User.Read`.
   - Add the cloud-group tag (cloud-only only).
   - Mirror each `<account>.file.core.windows.net` identifier URI as `<account>.privatelink.file.core.windows.net`.
   - Make no other edits.
3. Conditional Access:
   - Candidates are policies that are not disabled, target all resources, require MFA or an authentication strength, and don't already exclude the app.
   - With `-ConditionalAccess Ask` (the default), the list is shown and the change needs the operator to type `yes`. `Exclude` applies without asking; `Report` only lists.
   - Each PATCH resends the policy's existing app conditions with the storage app added to `excludeApplications`.
   - Microsoft-managed policies cannot exclude apps, so they're reported, not changed.
   - Policies with block, device or privileged-role conditions are reported for review.
4. Folder permissions. Storage public network access is disabled, so:
   - Capture the storage account's `publicNetworkAccess` and `networkAcls`.
   - Grant the operator a temporary *Storage File Data Privileged Contributor* role.
   - Allow only the operator's public IPv4 (detected, or passed with `-OperatorPublicIp`), keeping default action Deny.
   - Set the share-root ACLs over the Files REST API (OAuth with `x-ms-file-request-intent: backup`), retrying on 403 while the rule and role propagate.
   - **Always** restore the network settings and remove the role in `finally`.
   - The ACLs follow FSLogix's user-based access:
     - users: Modify, this folder only;
     - CREATOR OWNER: Modify, subfolders and files only;
     - admins, SYSTEM and Administrators: Full Control;
     - redirections: read-only for users.
   - Cloud groups use their `S-1-12-1-…` SIDs. Hybrid groups use `onPremisesSecurityIdentifier`; if a group isn't synced, PostDeploy skips this step and leaves a manual task.
5. Device check: report each host's Entra join, Intune management and OS build (cloud-only needs 26100/26200.8116 or later), and flag stale duplicate device records.

## Consequences

- One run takes a new estate from deployed to ready for a test sign-in.
- For a few minutes the profile storage is reachable from the operator's IP. That access needs the temporary data role, and both are reverted even on failure (T19).
- Tenant-wide and Conditional Access changes are explicit, opt-in and listed (T20).
- Profile folders created before PostDeploy keep their previous ACLs.

The automated steps need an admin who can consent to the listed Graph scopes. Where the operator lacks a right, that step becomes a manual task rather than failing the run.

## Alternatives rejected

- **Run icacls or RestSetAcls on a session host with the storage key:** puts the most powerful storage credential on a multi-session host.
- **Give hosts a managed identity with the privileged data role:** any user on a multi-session host could request that token from the instance metadata service.
- **Leave the default ACLs:** profiles stay readable and writable by every user.
- **Exclude the storage app from Conditional Access without asking:** these are security controls, so the change must be confirmed.
