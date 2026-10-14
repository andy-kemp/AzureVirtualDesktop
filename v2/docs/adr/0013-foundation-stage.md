# ADR 0013: Foundation stage - subscription selection and self-contained setup

Status: Accepted. Date: 2026-10-14. Supersedes the "pre-existing resource group" default in [phases](../phases.md).

## Context

The first sandbox run should not need hand-built prerequisites or copied IDs. Earlier slices required an existing resource group, VNet, subnets, Key Vault secret and managed identity, with every ID typed into the configuration.

## Decision

**Discovery (`avd.ps1 -Mode New`, unless `-Offline`).** The CLI signs in with Az PowerShell and asks for, or accepts as parameters:

- subscription;
- an AVD host pool region (from the `Microsoft.DesktopVirtualization` provider);
- a prefix and resource group;
- new or existing VNet;
- the AVD users and admins groups: an existing group searched by name, or a **new security group** created on explicit request with the operator as owner. When the users group is created, `New` offers to add the operator as a member for testing.

It also:

- looks up the Azure Virtual Desktop service principal;
- generates deterministic, availability-checked names for the Key Vault, storage account and deployment identity;
- fills in the release-pinned prep script from [artifacts.json](../../contracts/artifacts.json).

Lookups are read-only. Creating a group is the only directory write. It runs only when the operator chooses it, uses their own delegated Az PowerShell sign-in (subject to the tenant's "users can create security groups" setting or a Groups Administrator role), and is reused rather than duplicated if `New` is run again.

**Foundation (contract `1.4.0` `foundation` section, [foundation.bicep](../../infra/avd/foundation.bicep)).** Deploy runs it first, at subscription scope, after registering missing resource providers. Only providers this configuration needs are checked; they are registered only by an operator, never by the managed identity.

Deploy creates **only foundation pieces that are missing** (resource group, VNet, Key Vault, admin secret, identity). If nothing is missing, the stage is skipped. Existing resources are therefore never re-PUT, so later tags, subnets, NSG rules, route tables or Key Vault network restrictions are preserved. When run as the managed identity, missing foundation pieces or providers are a blocker rather than something it fixes with broader rights.

**Preview.** Foundation what-if runs at subscription scope, for missing pieces only. Platform and session-host what-if run once the resource group and network exist. Taken or soft-deleted Key Vault names and taken storage names are blockers, and misaligned address spaces are rejected. Unregistered providers are warnings for an operator and blockers for the managed identity.

| Member | Creates when missing |
| --- | --- |
| `createResourceGroup` | The workload resource group in the target region. |
| `network` | VNet (`/16`-`/24`), session-host `/25` and private-endpoint `/27` subnets, an NSG with no inbound rules, and a **NAT gateway** with a static public IP. Subnets set `defaultOutboundAccess: false`. New VNets have private subnets by default since 31 March 2026 ([Microsoft](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access)), and hosts need explicit outbound access to reach AVD, Entra and the prep script. |
| `keyVault` | Key Vault with Azure RBAC, soft delete (7 days) and public network access. If the admin password secret does not exist, the CLI generates a 24-character password in memory, stores it through a secure template parameter and uses it directly for this run. It is never shown, never written to disk, and **never rotated by reruns**. The operator and deployment identity get *Key Vault Secrets User* on the vault. |
| `deploymentIdentity` | The user-assigned managed identity named by `execution.deploymentIdentityResourceId`, with Key Vault read access only. |
| (when `scaling` is configured) | *Desktop Virtualization Power On Off Contributor* for the Azure Virtual Desktop service principal at subscription scope. AVD refuses to create a scaling plan without it ([ADR 0009](0009-native-avd-autoscale.md)). |


## Consequences

A first run needs only an account with Owner on the subscription (sandbox), plus either two existing Entra groups or the right to create security groups. Role assignments, provider registration and resource group creation need subscription-level rights. In production these remain bootstrap or customer-admin steps (ADR 0005), and the managed identity's broader rights are granted by bootstrap, not here.

The NAT gateway and public IP add a monthly cost. The Key Vault allows public network access so the operator's machine can read the secret on reruns. Restrict it with network rules or a private endpoint for production; because the foundation never re-PUTs an existing vault, those restrictions survive reruns. Existing-network mode keeps the old behaviour, and the operator must make sure that network has outbound access. Foundation resources are never deleted by V2; deleting the resource group removes them. A soft-deleted vault can block reuse of the same name for up to 7 days.

## Alternatives rejected

Generating the password inside Bicep (`newGuid()`) gives weaker, guessable-format secrets and rotates on rerun. Writing the secret through the Key Vault data plane needs a role assignment to propagate first. Relying on default outbound access would fail for new VNets. Creating Entra groups silently, or from a worker identity, would need standing directory write permissions that V2 avoids; group creation stays an explicit, delegated operator choice.
