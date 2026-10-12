# ADR 0004: SWA Standard and isolated container jobs

Status: Accepted hosting; Container Apps Jobs recommended execution baseline. Date: 2026-10-11.

## Context

The frontend is Static Web Apps (SWA), the API is separate, and existing orchestration uses PowerShell and a standalone Bicep executable. Deployments must outlive HTTP requests.

## Decision

Use **SWA Standard**, linking a separately authenticated App Service API through `/api`. Use event-driven Azure Container Apps Jobs, Azure Storage Queue and persisted job/stage state in Table Storage. Store pinned worker images in customer ACR, credentials in Key Vault and reports in restricted Blob Storage. Separate control-plane and workload resource groups.

The API accepts or polls work within SWA's 45-second API limit. No job executes inside the API. KEDA triggers fixed jobs; workers fetch a job reference, validate its approval, renew visibility/target leases and checkpoint provider operation IDs. Use scheduled reconciliation for orphaned work/token cleanup. No user/API job template overrides or direct job-start grants.

## Consequences

SWA bring-your-own linking needs Standard, does not support pull-request environments or network-isolated backends, and is not itself end-user authorisation. Verify the linked-origin restriction plus independent API bearer-token checks. Queue delivery and job execution are at-least-once; Table state, dispatch reconciliation, poison-message handling and fencing need explicit tests. Long W365 observation is bounded polling across executions, not one indefinitely running container.

## Alternatives rejected

Durable Functions provides persisted checkpoints, timers and retries and **supports PowerShell**. It is not rejected for language support. It would require function/activity decomposition, replay-safe orchestration and packaging external Bicep tooling; for the initial CLI-preserving AVD slice, pinned containers are the simpler operational unit. Revisit if durable timers/workflow complexity outweigh container reuse. Inline HTTP jobs and SWA Free are unsuitable.

## Sources

[SWA API constraints/Standard](https://learn.microsoft.com/en-us/azure/static-web-apps/apis-overview), [App Service linking](https://learn.microsoft.com/en-us/azure/static-web-apps/apis-app-service), [Container Apps Jobs and override risks](https://learn.microsoft.com/en-us/azure/container-apps/jobs), [Durable Functions](https://learn.microsoft.com/en-us/azure/azure-functions/durable/durable-functions-overview).
