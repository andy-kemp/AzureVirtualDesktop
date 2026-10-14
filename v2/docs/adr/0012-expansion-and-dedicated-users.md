# ADR 0012: Expanding V2 deployments and assigning dedicated hosts to named users

Status: Accepted. Date: 2026-10-14.

## Context

After the first deployment, operators need to add capacity to shared pools, and to give a specific person their own dedicated session host. That person also needs to be in the AVD users group for desktop access and sign-in rights. ADR 0008 forbids automatic adoption of resources V2 did not create. ADR 0005 runs approved changes as scoped managed identities with no AVD Graph application permissions.

## Decision

**Scope.** Expansion applies only to estates deployed by V2, using their saved configuration file as the source of truth. Importing root-runner or manually built AVD is out of scope.

**Shared pools: `avd.ps1 -Mode Expand`.**

- `-AddHosts N` adds hosts. `-Users N` re-sizes from the recorded persona and peak concurrency.
- New hosts continue the stable zero-based names (for example `AVDHOST-3`). VM size and sessions per host never change, so existing VMs are not resized.
- A lower user count never reduces hosts. V2 still never drains or deletes.
- Direct-assignment dedicated pools are refused with a pointer to `AddUser`.

**Dedicated pools: `avd.ps1 -Mode AddUser -UserPrincipalName <upn>`.**

- Dedicated pools now default to **Direct** assignment, so each host belongs to a named user.
- The UPN is resolved to an object ID with a **delegated, read-only** Microsoft Graph lookup (`GET /v1.0/users/{upn}`, `User.ReadBasic.All`). The lookup uses the operator's existing `Connect-MgGraph` session and is rejected if that session is for a different tenant than the configuration. `-UserObjectId` skips the lookup.
- The user takes the lowest unassigned host. If every host is assigned, a new host is added.
- The result is recorded in `assignments` (`userPrincipalName`, `objectId`, `hostIndex`). Duplicate users, out-of-range hosts and assignments on shared or Automatic pools are rejected.

**Deploy stage (to implement with Preview/Deploy):** after the new host registers, two steps run.

1. Set the session host's `assignedUser` to the UPN. This is an Azure Resource Manager write using `Microsoft.DesktopVirtualization/hostPools/sessionHosts/write` with the AVD execution identity.
2. Add the user to `accessGroups.usersObjectId` with the **operator's delegated permission**: `POST /groups/{id}/members/$ref`, needing `GroupMember.ReadWrite.All` delegated scope plus the operator's own right to manage that group, such as group owner or a scoped Groups Administrator. Already-present members are treated as success.

The group write is a deliberate exception to ADR 0005's "approved jobs run as UAMIs". The worker gets **no** Graph application permission, because application `GroupMember.ReadWrite.All` would allow membership changes to almost any group in the tenant. In the portal (Phase 3) this step runs through API OBO with the approving operator's token, bound to the approved plan, and is reported separately from the infrastructure job. If delegated authorisation fails there is no fallback: the step is reported as a manual follow-up.

## Consequences

The CLI changes only the configuration file; nothing is written to Azure or Entra until the approved deploy. Group membership gives the user desktop access and Virtual Machine User Login on the workload resource group. Direct assignment limits which dedicated VM AVD connects them to. Operators need group-management rights for the AVD users group. Bootstrap or a customer admin must arrange this, for example by making the operators group an owner or using an administrative-unit-scoped role. Removing users and reclaiming hosts is not included and needs its own reviewed design.

## Alternatives rejected

A worker with application `GroupMember.ReadWrite.All` is too broad. Assigning Desktop Virtualization User directly to each user avoids Graph, but scatters RBAC assignments and does not meet the requirement to use the group. Discovering and adopting non-V2 estates automatically conflicts with ADR 0008.
