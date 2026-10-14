# ADR 0011: User profiles - FSLogix for shared pools, local profiles for dedicated hosts

Status: Accepted. Date: 2026-10-14.

## Context

Shared (pooled) hosts need roaming profiles so users get the same profile whichever host they land on. Dedicated (personal) hosts always serve the same user, like Windows 365 Cloud PCs. The original contract supported only FSLogix on Azure Files with hybrid identities. Microsoft Entra Kerberos for Azure Files now also supports cloud-only identities ([Azure Files docs](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable)), but [Microsoft Entra Kerberos](https://learn.microsoft.com/en-us/entra/identity/authentication/kerberos) still labels cloud-only identity support **Preview** (checked 2026-10-14).

## Decision

Contract `1.3.0` makes `profile` one of three values:

| Profile | Pool | What V2 deploys |
| --- | --- | --- |
| `AzureFilesHybridKerberos` | Shared | Storage account with Microsoft Entra Kerberos and AD domain details, profile and redirection shares, share RBAC for the AVD groups, private endpoint and DNS. Hosts enable Cloud Kerberos ticket retrieval and FSLogix. Generally available. |
| `AzureFilesEntraKerberosCloudOnly` | Shared | The same storage, but Microsoft Entra Kerberos is enabled **without** AD domain details. It needs `storage.acknowledgePreview: true` because Microsoft documents it as preview. |
| `LocalProfile` | Dedicated | No storage account, shares, private endpoint or file DNS. Hosts run the prep script with `-ProfileMode Local`, which leaves FSLogix disabled and keeps the profile on the VM. |

- Shared pools must use one of the Azure Files profiles. Dedicated pools must use `LocalProfile`. The schema and tests enforce both.
- The V2 [session host prep script](../../scripts/session-host-prep.ps1) matches the root script's FSLogix, Cloud Kerberos and app-removal behaviour and adds `-ProfileMode`. It must still be published as an immutable artifact with its SHA-256 digest.
- The questionnaire asks shared-pool operators whether users are **hybrid** or **cloud-only** and explains the preview prerequisites.

## Cloud-only prerequisites (customer administrator, not automated)

From Microsoft's documentation:

- Session hosts run Windows 11 24H2 or later with KB5079391 or later. The latest `win11-24h2-avd` gallery image is expected to include it; verify on the deployed hosts.
- Grant admin consent to the storage account's auto-created Entra application (`openid`, `profile`, `User.Read`).
- Add the cloud group SID tag to that application's manifest. Without it, cloud-only authentication fails.
- Exclude that application from Conditional Access policies that require MFA. Entra Kerberos to Azure Files does not support MFA.
- Allow symmetric keys on the Storage Resource Provider service principal if app management policies block them.
- Assign share-level permissions. The current templates give the AVD users and admins groups their FSLogix roles. Windows ACLs cannot be set from File Explorer for cloud-only identities.

Hybrid identities keep their existing prerequisites (synced users and groups, and ACLs set from a machine that can reach a domain controller).

Update (2026-10-14, [ADR 0015](0015-post-deploy-configuration.md)): `-Mode PostDeploy` (or `Deploy -PostDeploy`) automates the consent, the cloud-group tag, the `privatelink` identifier URIs that the private endpoint needs, the MFA Conditional Access exclusion (with confirmation) and the FSLogix folder ACLs over the Files REST API. Host prep also sets `LoadCredKeyFromProfile`, which Microsoft requires for Entra ID with roaming profiles, and Deploy restarts new hosts so the Kerberos setting applies.

## Consequences

A dedicated user's local profile is lost if their VM is rebuilt, unless their data is held elsewhere, for example with OneDrive Known Folder Move. V2 does not back up local profiles. A storage account cannot use Entra Kerberos and another identity source at the same time, so switching an existing pool between hybrid and cloud-only is a reviewed migration, not a rerun. While cloud-only is preview it must be presented as such in plans, approvals and reports. Remove `acknowledgePreview` and the warning once Microsoft announces general availability.

## Alternatives rejected

FSLogix on dedicated hosts adds storage cost and a dependency without benefit for single-user VMs. Microsoft Entra Domain Services or AD DS-joined storage would reintroduce domain infrastructure that Entra-joined hosts avoid. Silently using a preview feature without acknowledgement conflicts with the approval model.
