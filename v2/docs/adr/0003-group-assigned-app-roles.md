# ADR 0003: Group-assigned app roles

Status: Accepted. Date: 2026-10-11.

## Context

Portal access must not imply the right to invoke arbitrary Azure or Graph operations through a privileged backend.

## Decision

Define `Portal.Reader`, `Portal.Operator`, `Portal.Approver` and `Portal.Admin` as user/group app roles on the API registration. Customer administrators assign existing groups on its enterprise application. Require assignment and validate tenant, audience, signature, expiry, delegated API scope and roles on every API request.

Reader inspects authorised records; Operator discovers, previews and submits; Approver approves; Admin manages portal target policy. Roles are not implicitly hierarchical. Fine-grained target checks apply to all roles. Admin cannot grant itself Entra/Azure permissions or bypass approval. Require an independent approver for privilege-bearing changes; routine self-approval remains a customer policy decision.

## Consequences

Group-based application assignment requires Entra ID P1/P2. Nested membership is not a substitute for direct membership. No Graph membership query is needed to evaluate API roles. Role revocation has token propagation delay: revalidate approval eligibility before execution and define maximum token/session age.

## Alternatives rejected

SWA invitations, local role tables as the primary identity authority, trusting UI controls, and unrestricted proxy endpoints are excluded.

## Sources

[App roles in tokens](https://learn.microsoft.com/en-us/entra/identity-platform/howto-add-app-roles-in-apps) and [group assignment prerequisites](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/assign-user-or-group-access-portal).
