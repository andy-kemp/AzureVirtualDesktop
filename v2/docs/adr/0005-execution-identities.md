# ADR 0005: Delegated planning and scoped workload execution

Status: Accepted. Date: 2026-10-11.

## Context

Operators' discovery/preview access must not borrow the worker's broader permissions, while approved deployments must survive human session expiry.

## Decision

Discovery and preview execute as the signed-in operator, directly in the CLI or via API OBO. No fallback to a mutation identity when delegated authorisation fails. Approved jobs execute as customer-owned user-assigned managed identities (UAMIs), with Azure RBAC scoped to approved resources and Graph application permissions granted only for enabled features.

Separate API operational, AVD mutation, AVD observation, W365 mutation and W365 observation identities; never attach a read identity and mutation identity to the same purported read-only execution container. AVD observation has resource-read rights and no Graph grants. Token recovery runs separately under the AVD mutation identity. Initially disable all W365 grants. Bootstrap authority is never retained by a worker.

Exception ([ADR 0012](0012-expansion-and-dedicated-users.md)): adding a named dedicated user to the AVD users group runs with the operator's delegated Graph permission, because the only application permission (`GroupMember.ReadWrite.All`) is tenant-wide.

## Consequences

Azure RBAC and Graph consent are independent. Default ARM what-if needs deployment rights even though it makes no resource changes; evaluate `ProviderNoRbac` for reduced-resource-permission preview, documenting residual deployment actions and limitations. App-only Graph privileges can be tenant-wide; server target/approval checks remain essential. Subscription resource-group creation and RBAC writes require separate, constrained grants, not routine Owner.

## Alternatives rejected

Stored human credentials, all operations under one administrator identity, worker-powered discovery and cross-tenant credentials violate the boundary. Delegated-only long jobs would depend on renewable human sessions.

## Sources

[What-if permissions and validation levels](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if), [Graph application permission consent](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent).
