# ADR 0006: AVD first, then Windows 365 Enterprise

Status: Accepted. Date: 2026-10-11.

## Context

The current runner deploys AVD infrastructure, then hosts, but does not complete tenant/domain readiness. Cloud PCs have a different provisioning model.

## Decision

Phase 1 preserves current AVD behaviour using versioned configuration, isolated V2 orchestration and a CLI. Follow with the portal and then Windows 365 Enterprise: Entra join, Microsoft-hosted network, supported gallery images, policies and group assignments. Verify licences only; do not assign or buy them in the MVP. Prefer Graph v1.0 and explicitly gate any required beta dependency.

## Consequences

Preserve incremental deployments, stable host names, token cleanup and no automatic rollback/draining by the worker. Day-to-day power scaling is delegated to the native AVD service ([ADR 0009](0009-native-avd-autoscale.md)). Existing groups/networks, Azure Files Microsoft Entra Kerberos (hybrid, or cloud-only preview, per [ADR 0011](0011-user-profiles.md)), consent, ACLs and DNS prerequisites remain explicit. Licence checking is not proof of user readiness. Verified v1.0 Cloud PC inventory does not yet establish complete provisioning-status observation; track that gap before the W365 phase.

## Alternatives rejected

Treating W365 as a VM SKU, enabling every edition/network mode, licence mutation and silently automating tenant-policy exceptions are excluded.

## Sources

[Windows 365 on Graph](https://learn.microsoft.com/en-us/graph/cloudpc-concept-overview) and [v1.0 Cloud PC schema](https://learn.microsoft.com/en-us/graph/api/resources/cloudpc?view=graph-rest-1.0).
