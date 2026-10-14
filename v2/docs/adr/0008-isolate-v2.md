# ADR 0008: Preserve the existing deployment

Status: Accepted. Date: 2026-10-11.

## Context

The root runner/templates/tests are an existing deployment path and may contain customer changes. V2 must not destabilise it.

## Decision

Everything new stays under `v2/`. Do not alter root-level scripts, templates, tests or metadata. Read them as the behavioural reference; create isolated versioned V2 modules rather than depending at runtime on mutable parent-folder files.

## Consequences

Phase 1 needs parity tests, independent artifacts and explicit migration boundaries. Any adoption of existing deployments requires a reviewed plan, not automatic RBAC/resource-name reconciliation. This documentation session neither implements nor deploys V2.

Exceptions approved by the repository owner are recorded here:

- 2026-10-14: root `modules/platform.bicep` Start VM on Connect assignment corrected to the built-in *Desktop Virtualization Power On Contributor* role ID (`489581de-a3bd-480d-9518-53dea7416b33`). The previous ID matched no built-in role, so the assignment could not succeed.

## Alternatives rejected

In-place legacy refactoring, moving root files, or changing existing tests would violate the compatibility boundary. A new repository is not required for the MVP distribution.
