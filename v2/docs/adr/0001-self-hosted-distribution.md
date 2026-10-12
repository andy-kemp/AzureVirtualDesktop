# ADR 0001: Self-hosted distribution

Status: Accepted. Date: 2026-10-11.

## Context

Customers need control of privileged deployment access and their operational data. The author's installation is the first customer installation, not a central control plane.

## Decision

Distribute from this repository using Bicep and one future bootstrap script under `v2/`. Each customer installs into their own Azure subscription and Entra tenant. Keep tenant IDs explicit in contracts, but provide no central service, cross-tenant execution, vendor standing access or vendor telemetry collection.

## Consequences

Customers own consent, costs, upgrades, audit retention and uninstall. Releases and dependencies must be pinned and reviewable. Multi-tenant SaaS is a later, separately reviewed design; no tenancy router or delegated customer credential store is needed now.

## Alternatives rejected

Central SaaS, Azure Lighthouse-based customer access and vendor-managed service principals introduce cross-tenant trust outside the MVP.
