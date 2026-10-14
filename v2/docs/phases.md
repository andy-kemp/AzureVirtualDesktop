# Delivery phases

Status: agreed sequence; Phase 1 local contract/build slice started. Azure preview/deploy and sandbox validation remain gated. Date: 2026-10-11.

All artifacts live under `v2/`. Customer installation is the product; the first personal installation exercises the same bootstrap without vendor-only shortcuts. No SaaS control plane or cross-tenant tests are required beyond rejecting a mismatched tenant.

## Phase 1: Contract, isolated AVD orchestration and CLI

Deliver a versioned non-secret configuration contract with explicit `tenantId`, subscription, target scopes, profile/artifact version and secret references. Isolate Bicep and staged PowerShell orchestration under V2; do not invoke mutable parent templates at runtime. Retain Validate, Preview and explicit Deploy modes. Use delegated discovery/preview and an explicit UAMI execution context for approved deploys; local CLI approval must bind the same plan/target contract.

Current increment: JSON Schema `1.4.0` (accepting `1.0.0`–`1.3.0` files), fictional sample configuration, `v2/avd.ps1` `New`/`Expand`/`AddUser`/`Validate`/`Build`/`Preview`/`Deploy` modes, and resource-group-scoped V2 AVD templates plus a subscription-scope foundation template. `New` discovers the subscription, region, network and groups unless `-Offline` is used.

- **`New`** is the sizing questionnaire ([ADR 0010](adr/0010-persona-based-sizing.md)). It asks shared or dedicated, persona, user count and concurrency, identity type for FSLogix, then scaling preset. It writes `profile`, `workload`, `hostPool` (pooled or personal), `sessionHosts` and `scaling` from shared [sizing profiles](../contracts/sizing-profiles.json).
- **Profiles** ([ADR 0011](adr/0011-user-profiles.md)): shared pools use FSLogix on Azure Files (hybrid, or cloud-only preview). Dedicated pools keep local profiles and deploy no storage.
- **`Expand` and `AddUser`** ([ADR 0012](adr/0012-expansion-and-dedicated-users.md)) grow V2 estates from their saved configuration. `AddUser` assigns dedicated hosts to named users after a delegated, read-only Graph lookup. The host assignment and group membership are deploy-stage steps; group membership uses the operator's delegated rights only.
- **Scaling:** the optional `scaling` section deploys a native AVD scaling plan with pooled or personal schedules ([ADR 0009](adr/0009-native-avd-autoscale.md)). Validation covers time zone, phase order and overlapping days. The subscription-scope *Desktop Virtualization Power On Off Contributor* grant for the AVD service principal is a customer prerequisite, not a workload deployment action; Preview checks it and warns if it is missing. The chosen machine-contract defaults are JSON Schema, Key Vault secret URI references, and an HTTPS preparation artifact plus SHA-256 digest. The resource group, network, Key Vault and deployment identity are either created by the optional foundation stage ([ADR 0013](adr/0013-foundation-stage.md)) or must already exist. The user-facing flow should derive defaults and hide low-level references; see [deployment experience](deployment-experience.md).

- **Preview and Deploy** are implemented ([sandbox runbook](sandbox-test.md)). Preview is read-only and writes a 24-hour plan bound to configuration and template hashes.
- **Deploy** requires that plan, approval by resource group name, and either the managed identity or an explicit `-AsSignedInUser`.
- **Coverage:** mocked offline tests cover ordering, failure, token revocation and secret hygiene. The first real sandbox run is the remaining exit check for this phase.

Preserve platform-before-host sequencing, incremental reruns, stable zero-based host names, four-hour registration token and success/failure revocation. Increasing hosts adds; reducing counts does not drain/delete. Autoscale powers existing hosts on and off within the configured count and never deletes them. Fresh preflight remains core-only until host-pool prerequisites exist. Reject unapproved script artifacts, mismatched contexts and unexpected RBAC/resource adoption. Separate readiness warnings from automation result.

Exit: offline schema/parity tests pass; both Bicep entry points compile; no root edits; mocked orchestration failures prove cleanup/no rollback; no secrets in output/configuration; delegated permission failure never falls back to worker. Add delegated preview and explicit UAMI deploy only after plan/approval binding and target/RBAC scopes are reviewed. Approved customer sandbox then confirms deploy/rerun/registration and manual identity/DNS/ACL checks. Sandbox use needs separate approval.

## Phase 2: Self-hosted bootstrap and read-only portal

Deliver one reviewed bootstrap script plus portal Bicep, an installation manifest and resumable staged install/uninstall. Create customer single-tenant SPA/API registrations, group-assigned roles, UAMIs and feature-specific grants. Host frontend on SWA Standard and link the authenticated API. W365 stays disabled with no app grants.

Exit: a fresh customer-owned sandbox installs without vendor access; rerun does not duplicate identities/consents; PRA/GA hand-off and denied consent fail safely. Test API token audiences/roles, direct-origin/header spoofing, OBO, tenant-policy challenges and delegated what-if. Short asynchronous preview operations meet the 45-second SWA API limit and keep user-token caches separate from persisted jobs. Uninstall removes recorded portal identities/grants and preserves workloads/shared groups/networks.

## Phase 3: Approval-bound AVD jobs

Deliver fixed event-driven Container Apps Jobs, durable queue, authoritative plans/approvals and stage state, fenced per-pool execution, dispatch reconciliation, token cleanup recovery and sanitised audit/report UI. No browser-supplied commands or job template overrides. The portal presents the same sizing questionnaire as `avd.ps1 -Mode New`, using the shared sizing profiles: shared or dedicated, persona, users and concurrency. It shows the recommendation and any operator override in the plan review. It also offers guided scaling-schedule presets and editing that produce the same contract `scaling` section.

The portal also offers **Add capacity** for shared pools and **Add dedicated user** for personal pools, with the same rules as `Expand`/`AddUser`. A user picker uses delegated Graph, and the review shows display name, UPN and object ID. After approval, the host job sets `assignedUser`. The group membership step runs separately through OBO with the approving operator's delegated rights and is reported on its own; it never falls back to a worker identity. Schedule changes are material and go through plan/approval like any other change. The portal also shows the host pool's current scaling-plan state and reports a missing subscription power-role prerequisite.

Exit: independent approval for privileged actions enforced; changed/expired plans rejected; browser closure, duplicate delivery, enqueue failure, worker termination and lease loss tested. Recovery must inspect outstanding ARM operations before rerun/token revocation. API has no workload UAMI/job-start authority; observer cannot mutate. [Threat model](threat-model.md) tests pass, spending/concurrency bounds work, and a real user checks AVD readiness. Approver-revocation/session-age policy must be implemented before release.

## Phase 4: Windows 365 Enterprise

Deliver delegated policy/group/gallery discovery and licence checks; UAMI policy creation/update/assignment; separate read-only observation. Entra join/Microsoft-hosted network only. No licence buying/assignment or group membership mutation.

Exit: permission/consent matrix confirmed in a licensed customer sandbox; stale licence evidence blocks assignment; policy assignment preserves approved targets; conflicts/drift require reapproval. Test throttling, partial failure and repeated deliveries. Resolve [v1.0 observation gaps](permission-matrix.md) before promising provisioning readiness; any beta exception requires a recorded endpoint, permission, support risk and explicit approval. Otherwise report limited inventory observation and require administrator confirmation rather than false success.

## Phase 5: Optional expansion

Customer-requested additional identity/network profiles, Windows client/agent or lifecycle management receive separate requirements and threat review. A multi-tenant SaaS offering is a new distribution/security design, not an MVP switch. Cloudflare remains excluded from the MVP.

Exit: an accepted scope/ADR change and feature-specific permissions, tests, consent and rollback/uninstall boundaries exist before code or deployments.

## Remaining Phase 1 decisions and gates

1. Which named sandbox subscription/region and existing AVD VNet/subnets/groups represent the first installation, and who owns its hybrid identity/DNS/ACL prerequisites?
2. The first CLI requires the workload RG to pre-exist. Who creates it, and who approves constrained role-assignment conditions or pre-provisioned access?
3. The contract is JSON Schema `1.4.0`; no PSD1 importer is planned. Secret references use customer Key Vault URIs; the prep artifact is HTTPS plus SHA-256. Which customer-controlled artifact store/release digest policy should be supported?
4. What approval rules, expiry, maximum session age and concurrency/host limits apply, including the first person's installation when no second approver is available?

Region/SKUs/budget, retention/residency, implementation language versions, certificate lifecycle and UI ingress details must be set before portal installation, but do not block offline Phase 1 work. W365 licences/status capability can wait until Phase 4. Do not reopen locked hosting, identity or distribution decisions.
