# ADR 0009: Native AVD autoscale for host-pool scaling

Status: Accepted. Date: 2026-10-14.

## Context

Customers need session-host capacity to follow demand, scaling up for heavy use and down when use is light, without paying for idle VMs. The V2 design otherwise excludes host-count reduction, draining and deletion by the deployment worker (ADR 0006). AVD provides a first-party [autoscale scaling plan](https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-create-assign-scaling-plan) that starts and stops existing session hosts by schedule and load.

## Decision

Use the native `Microsoft.DesktopVirtualization/scalingPlans` resource, deployed by the V2 platform Bicep from an optional `scaling` section of the configuration contract (schema `1.1.0` or later). The plan is created in the host pool's region and resource group and references only the V2 host pool.

- **Power management only.** Autoscale starts, drains and deallocates existing hosts. It does not create or delete hosts. The preview dynamic (create/delete) autoscale method is excluded.
- **Pooled and personal.** Pooled (shared) pools use ramp-up/peak/ramp-down/off-peak schedules with minimum host percentages and capacity thresholds. Personal (dedicated) pools ([ADR 0010](0010-persona-based-sizing.md)) use `personalSchedules` child resources: Start VM on Connect, an optional ramp-up auto-start, and deallocate-after-disconnect or after-logoff timers per phase. Published API types list only `Pooled` for the plan's `hostPoolType`, but the service and the Azure Verified Module use `Personal`. Sandbox deployment must confirm this. **Hibernate is excluded** because FSLogix profile containers do not support it.
- **The AVD service performs scaling**, not the V2 worker or portal. No runtime job, timer or custom scaler is added.
- **Prerequisite, not runtime grant.** Microsoft requires *Desktop Virtualization Power On Off Contributor* (`40c5ff49-9181-41f8-ae61-143b0e78555e`) for the Azure Virtual Desktop service principal or a host-pool managed identity **at subscription scope**. Lower scopes stop autoscale working properly. The resource-group-scoped workload deployment and AVD UAMI must not hold subscription RBAC-write. AVD **rejects creating a scaling plan** until the role exists (found in the first sandbox run), so it is a hard prerequisite. When the configuration has a `foundation` section, the operator-run foundation grants it (ADR 0013); otherwise Preview reports a blocker. Deploy retries the platform stage while a newly granted role propagates. The AVD UAMI never grants it.
- Safe defaults: `forceLogoffUsers` is `false`, an exclusion tag supports maintenance and `enabled: false` deploys a plan without activating it.
- Schedule changes are material configuration changes and need a new plan and approval, the same as any other change.

## Business-hours preset behaviour

The questionnaire's business-hours preset aims for the least user impact. It follows Microsoft's [autoscale glossary](https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-glossary), where required hosts are `ceil(sessions / (max session limit x capacity threshold%))` and minimum host percentages round up to whole hosts.

**Shared (pooled) pools:**

- **One host is always on.** The minimum hosts setting is at least 1% in every phase, which rounds up to one host. Users never wait for a cold start, and Start VM on Connect remains a fallback.
- **One empty host is kept ready during working hours.** The ramp-up/peak capacity threshold is set just under one session's share of a host, `max(1, ceil(100 / maxSessionLimit) - 1)`: 2% for 48 sessions, 3% for 32 and 6% for 16. That makes required hosts equal *sessions + 1*. With breadth-first load balancing, each new user lands on an empty running host and another host starts. Once every host in the pool is running, further users are spread breadth-first across all of them. Example with three hosts: the first user starts host 2, a user on host 2 starts host 3, and the fourth user joins whichever host has the fewest sessions.
- **Hosts with sessions are never shut down.** Ramp-down uses `forceLogoffUsers: false` and `stopHostsWhen: ZeroSessions`. Autoscale only drains a host, so it accepts no new sessions, and deallocates it once all active **and disconnected** sessions have ended. It shuts hosts down only when sessions can be consolidated below the 90% ramp-down threshold. Off-peak uses depth-first load balancing to fill remaining hosts before starting more.
- **Weekends** keep one host on and add hosts only at 90% of running capacity (depth-first), favouring cost when few users connect.
- **Limits:** autoscale evaluates periodically and a VM takes minutes to boot, so users arriving together may briefly share a host before the next one is ready. Disconnected sessions keep a host running, so customers should apply a disconnected-session time limit through Intune or Group Policy. The preset leaves the length to customer policy.

**Dedicated (personal) pools:** VMs start through Start VM on Connect. Business-hours defaults wait 120 minutes after a disconnect at peak before deallocating. A deallocated disconnected session loses unsaved work, so the review must state these timers.

## Consequences

Scaling works for script-only (Phase 1) installations with no portal. The portal later edits the same contract section (Phase 3) rather than inventing a second scaler. Autoscale cannot be combined with Azure Automation or Logic Apps scaling scripts on the same host pool. Operators must remove those before enabling this.

The subscription-scope role lets the AVD service principal start and deallocate VMs across that subscription and manage AVD user sessions there. This is accepted as a Microsoft-documented requirement and recorded as a residual risk in the [threat model](../threat-model.md). The host count in the contract is still the maximum. Autoscale works within it and never removes deployed hosts.

## Alternatives rejected

A custom scaler in Container Apps Jobs or Azure Automation duplicates a supported first-party feature and needs VM power rights for the worker. Assigning the power role at resource-group scope in Bicep is unsupported for autoscale. Granting it from the workload deployment would need subscription RBAC-write for the AVD UAMI. Dynamic create/delete autoscale conflicts with stable host names, registration-token handling and the no-deletion boundary.
