# Customer bootstrap and uninstall

Status: installation design only; the bootstrap script and Bicep do not yet exist. Date: 2026-10-11. Nothing in this session creates resources, registrations, assignments or consent.

## Customer responsibilities

Use a reviewed, pinned release of this repo on an administrator-controlled machine. Verify release/source integrity and dependency digests before signing in; do not pipe a remote branch script into an elevated shell. Choose the tenant/subscription/region, dedicated portal resource group, approved workload targets, existing network/group IDs, certificate lifecycle, budget and retention. Entra ID P1/P2 is required for group-based application assignment. The customer's admin retains all ownership; no vendor users, credentials, telemetry endpoint or standing access are installed.

Prepare existing AVD groups/VNet/subnets and hybrid Azure Files Kerberos prerequisites. The Microsoft-owned AVD service principal must exist. Bootstrap records its tenant-specific object ID, but does not grant blanket consent, change Conditional Access, administer Windows DNS or set share ACLs. Customer administrators complete those workload prerequisites separately. If AVD scaling will be used, a customer Azure access administrator assigns *Desktop Virtualization Power On Off Contributor* to that service principal at each workload **subscription** scope ([ADR 0009](adr/0009-native-avd-autoscale.md)). Bootstrap may offer this as an explicit, separately approved step. The runtime never makes this grant.

For **cloud-only FSLogix (preview)**, a customer Entra administrator completes the steps in [ADR 0011](adr/0011-user-profiles.md) after the storage account exists:

- Admin consent for the storage account's Entra app.
- The cloud group SID manifest tag.
- A Conditional Access MFA exclusion scoped to that app only.
- Share and folder permissions.

For **dedicated named users** ([ADR 0012](adr/0012-expansion-and-dedicated-users.md)), give the portal operators group the right to manage the AVD users group's membership, for example as group owners or through an administrative-unit-scoped Groups Administrator role. Consent the delegated `User.ReadBasic.All` and `GroupMember.ReadWrite.All` scopes for the API.

## Privileged steps

| Step | Customer authority | Boundary |
| --- | --- | --- |
| Azure RG/provider/resource creation | Azure resource creation rights at subscription for RG/provider registration; narrower portal RG/shared-resource rights otherwise | Contributor can provision but does not grant Azure RBAC. No Entra admin role is sufficient by itself. |
| Azure role assignments | RBAC Administrator, User Access Administrator, Owner or equivalent at each assignment scope | Role **definition** creation additionally needs `roleDefinitions/write`; RBAC Administrator alone does not include it. Prefer temporary/PIM elevation. |
| Customer SPA/API app creation and configuration | Application Administrator/Cloud Application Administrator, or supported owner/custom-role authority | Tenant registration policy applies; GA is not necessary solely to create a customer app. |
| Group-to-portal app role assignment | Supported app assignment administrator/owner | Existing groups, API app roles; no directory admin role assignment. |
| Delegated consent for API discovery/preview | Cloud Application Administrator/Application Administrator or sufficient consent role; PRA/GA also capable | Review exact selected scopes. Assignment-required apps need admin consent even for otherwise user-consentable scopes. |
| Microsoft Graph application permissions on enabled UAMIs | **Privileged Role Administrator (PRA) or Global Administrator (GA)** in this baseline | Application/Cloud Application Administrator cannot grant Graph application roles. No worker self-consent. |

Sources: [Azure privileged roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/privileged), [Entra consent authority](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent), [group assignment/licensing](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/assign-user-or-group-access-portal). Privilege should be activated for the relevant stage, not retained by the installed runtime. Entra/Azure roles and delegated OAuth scopes are separate prerequisites.

## What the single bootstrap will do

1. Run preflight, display target tenant/subscription and enabled features, compile pinned Bicep, show Azure/Graph changes and costs, and obtain explicit customer approval. Verify both Azure and Graph contexts against the target tenant. One script may pause for a different customer's consent administrator; one invocation is not a promise of one privilege set or one sign-in.
2. Create or resume a versioned installation manifest with installation ID, release digest, resource/object IDs, created/reused ownership, before/after grant differences and completed stages. Do not persist tokens/private keys in it. Name matching alone is not proof of ownership.
3. Deploy the portal Azure resources via Bicep: SWA **Standard**, App Service API/plan, Container Apps environment and fixed jobs, customer ACR, queues/state/artifact/report stores, Key Vault and monitoring. Separate the portal RG from workload RGs; apply access restrictions/TLS and data-plane grants.
4. Create two customer-owned **single-tenant** registrations: SPA public client and API confidential client, plus their enterprise applications. Expose the delegated API scope, define the four `Portal.*` roles on the API, require assignment and bind only customer-approved group IDs. Configure exact SWA URLs/tenant authority and certificate public key; keep API certificate private material in customer Key Vault. Grant the SPA its API scope and the API only selected downstream delegated permissions.
5. Create API operational, AVD execution and separate AVD observation UAMIs. Give the AVD observer only workload resource-read and required operational data rights, no Graph grants or token operations; do not attach the mutation identity to its container. Token recovery is a separate fixed job using AVD execution authority. Add a queue-scaler/read identity if necessary. The API operational UAMI reads only its OBO credential and required portal data, never workload secrets. Configure worker secrets by reference and fixed image digest; no human deployment credential is stored. Create W365 mutation/observer UAMIs only when that feature is enabled later.
6. Establish scoped Azure grants for approved AVD targets and named existing subnets/VNet. Prefer bootstrap-created target RGs to avoid broad runtime subscription privilege; support the current subscription-wrapper behaviour only with an explicit action-scoped grant and documented limits. Constrain RBAC assignment writes to approved role/principal IDs, or pre-provision them and isolate that stage. Do not quietly grant routine Owner or job-start rights to portal groups/API.
7. Review and apply only the consent rows for enabled features in the [matrix](permission-matrix.md). AVD-only has no AVD-worker Graph application grant. Enabling W365 later separately grants its mutation UAMI `CloudPC.ReadWrite.All` and observer UAMI `CloudPC.Read.All`; licence checks remain delegated. Installation does not assign or buy licences.
8. Link App Service as SWA's backend after static assets exist. Preserve the linked-origin restriction and add independent API Entra bearer authentication/role enforcement. Confirm unlinked direct-origin, forged headers, wrong audience, wrong tenant and unassigned users fail. SWA cannot link network-isolated backends or pull-request environments; never remove authentication to make a smoke test pass.
9. Verify allowed/denied roles, OBO delegated discovery/preview, storage isolation, fixed-job identity availability and no vendor access. Stop before any workload deployment unless separately approved. Print an installation report with exact IDs, grants, unresolved prerequisites and uninstall instructions; end local admin sessions and release temporary elevations.

Bicep owns Azure resources; Graph calls in the bootstrap own app registrations/consents. An ARM deployment cannot be assumed to create those directory objects. Detailed least-privilege custom roles and linked-backend/OBO compatibility remain verification gates, not claims already tested.

## Rerun, upgrade and failed install

Reconcile by manifest IDs plus current ownership/state. Review permission changes separately from resource changes; feature flags must not silently request all future permissions. Resume only incomplete stages, and do not overwrite customer-edited roles/consents. Track partial installation and retain an actionable cleanup report; do not roll back shared resources.

Customer-controlled upgrades verify pinned release/image/toolchain digests and show schema/grant differences. No automatic branch tracking, vendor callback or unattended consent elevation. A deployment credential for uploading SWA assets, if used, is transient/customer-owned and must be protected and rotated; it is not a vendor credential.

## Clean uninstall

Uninstall is an explicit customer-admin operation, not a portal-worker capability. Produce a manifest-based preview before deleting anything; missing/tampered ownership evidence requires manual review.

1. Disable submissions and queue triggers; drain/stop active work. Inspect outstanding provider operations and safely revoke this installation's AVD tokens before removing identities. Export sanitised reports/audit evidence to a customer-selected store.
2. Revoke only recorded delegated grants and Graph application role assignments introduced for this installation; remove group-to-portal assignments. Obtain the same relevant Entra consent authority. Remove runtime RBAC assignments, including those outside the portal RG, after jobs are quiescent.
3. Delete customer portal SPA/API enterprise applications and registrations by exact recorded IDs, using approved administrator authority. [Application deletion](https://learn.microsoft.com/en-us/graph/api/application-delete?view=graph-rest-1.0) and [SP deletion](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-delete?view=graph-rest-1.0) use D `Application.ReadWrite.All`; portal UAMIs never receive it. Do not delete shared Graph/AVD service principals or shared groups.
4. Delete dedicated portal Azure resources/UAMIs, remove customer pipeline/federation/upload credentials introduced by the install, and remove unused installer-created custom roles only after checking other assignments. Remove retained certificates/secrets according to policy. Key Vault soft-delete/purge protection and backups mean uninstall is not immediate irreversible erasure; document retained data and expiry rather than disabling protection.
5. Leave AVD workloads, profiles, VNet/subnets, central DNS, existing groups, W365 Cloud PCs/policies/assignments and licences intact. Workload decommissioning is separate, especially where removing a W365 policy/licence could affect live Cloud PCs.
6. Verify no recorded portal grants/endpoints/active jobs remain and report any failures/retained objects. A lost manifest is not permission to delete by prefix. Do not automatically revoke shared first-party Graph PowerShell client consents used by other admins; review any installer-introduced grant delta explicitly.
