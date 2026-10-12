# Delivery phases

Status: agreed sequence; Phase 1 local contract/build slice started. Azure preview/deploy and sandbox validation remain gated. Date: 2026-10-11.

All artifacts live under `v2/`. Customer installation is the product; the first personal installation exercises the same bootstrap without vendor-only shortcuts. No SaaS control plane or cross-tenant tests are required beyond rejecting a mismatched tenant.

## Phase 1: Contract, isolated AVD orchestration and CLI

Deliver a versioned non-secret configuration contract with explicit `tenantId`, subscription, target scopes, profile/artifact version and secret references. Isolate Bicep and staged PowerShell orchestration under V2; do not invoke mutable parent templates at runtime. Retain Validate, Preview and explicit Deploy modes. Use delegated discovery/preview and an explicit UAMI execution context for approved deploys; local CLI approval must bind the same plan/target contract.

Current increment: JSON Schema `1.0.0`, fictional sample configuration, `v2/avd.ps1` `Validate`/`Build` modes and resource-group-scoped copied V2 AVD templates. The chosen machine-contract defaults are JSON Schema, Key Vault secret URI references, HTTPS preparation artifact plus SHA-256 digest, and a **pre-existing** target resource group for this offline slice. The user-facing flow should derive defaults and hide low-level references; see [deployment experience](deployment-experience.md). The CLI intentionally has no Azure Preview/Deploy mode yet.

Preserve platform-before-host sequencing, incremental reruns, stable zero-based host names, four-hour registration token and success/failure revocation. Increasing hosts adds; reducing counts does not drain/delete. Fresh preflight remains core-only until host-pool prerequisites exist. Reject unapproved script artifacts, mismatched contexts and unexpected RBAC/resource adoption. Separate readiness warnings from automation result.

Exit: offline schema/parity tests pass; both Bicep entry points compile; no root edits; mocked orchestration failures prove cleanup/no rollback; no secrets in output/configuration; delegated permission failure never falls back to worker. Add delegated preview and explicit UAMI deploy only after plan/approval binding and target/RBAC scopes are reviewed. Approved customer sandbox then confirms deploy/rerun/registration and manual identity/DNS/ACL checks. Sandbox use needs separate approval.

## Phase 2: Self-hosted bootstrap and read-only portal

Deliver one reviewed bootstrap script plus portal Bicep, an installation manifest and resumable staged install/uninstall. Create customer single-tenant SPA/API registrations, group-assigned roles, UAMIs and feature-specific grants. Host frontend on SWA Standard and link the authenticated API. W365 stays disabled with no app grants.

Exit: a fresh customer-owned sandbox installs without vendor access; rerun does not duplicate identities/consents; PRA/GA hand-off and denied consent fail safely. Test API token audiences/roles, direct-origin/header spoofing, OBO, tenant-policy challenges and delegated what-if. Short asynchronous preview operations meet the 45-second SWA API limit and keep user-token caches separate from persisted jobs. Uninstall removes recorded portal identities/grants and preserves workloads/shared groups/networks.

## Phase 3: Approval-bound AVD jobs

Deliver fixed event-driven Container Apps Jobs, durable queue, authoritative plans/approvals and stage state, fenced per-pool execution, dispatch reconciliation, token cleanup recovery and sanitised audit/report UI. No browser-supplied commands or job template overrides.

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
3. The contract is JSON Schema `1.0.0`; no PSD1 importer is planned. Secret references use customer Key Vault URIs; the prep artifact is HTTPS plus SHA-256. Which customer-controlled artifact store/release digest policy should be supported?
4. What approval rules, expiry, maximum session age and concurrency/host limits apply, including the first person's installation when no second approver is available?

Region/SKUs/budget, retention/residency, implementation language versions, certificate lifecycle and UI ingress details must be set before portal installation, but do not block offline Phase 1 work. W365 licences/status capability can wait until Phase 4. Do not reopen locked hosting, identity or distribution decisions.
