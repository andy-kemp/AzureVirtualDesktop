# ADR 0010: Persona-based host pool sizing

Status: Accepted. Date: 2026-10-14.

## Context

Operators should describe their users rather than fill in host counts, VM sizes and session limits. The earlier contract hard-coded a pooled host pool with 5 sessions per host and left the host count and VM size to the operator. Customers need both shared desktops for many users and dedicated desktops where each user needs their own VM.

## Decision

The CLI (`avd.ps1 -Mode New`), and later the portal, ask four questions:

1. **Shared or dedicated?** Shared uses a pooled host pool with Windows 11 Enterprise multi-session and FSLogix profiles. Dedicated uses a personal host pool with Windows 11 Enterprise single-session, local profiles and **Direct** assignment to named users ([ADR 0011](0011-user-profiles.md), [ADR 0012](0012-expansion-and-dedicated-users.md)).
2. **Which persona?** The options are Frontline (web/line-of-business app access), Standard (Microsoft 365 apps and Teams) and Heavy (heavy Outlook/PowerPoint, Teams meetings, developer tools).
3. **How many users?** Shared pools also ask for the peak concurrency percentage.
4. **How should hosts scale?** The options are business hours (with time zone and working day) or always available.

Sizing rules come from [Microsoft's session host sizing guidelines](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/session-host-virtual-machine-sizing-guidelines). They are versioned in [sizing-profiles.json](../../contracts/sizing-profiles.json) so the CLI and portal share one source:

| Persona | Microsoft workload | Users per vCPU (shared) | Shared host | Dedicated VM |
| --- | --- | --- | --- | --- |
| Frontline | Light | 6 | D8s_v5, 48 sessions | D2s_v5 |
| Standard | Medium | 4 | D8s_v5, 32 sessions | D4s_v5 |
| Heavy | Heavy | 2 | D8s_v5, 16 sessions | D8s_v5 |

- **Shared:** `hosts = ceil(users x peak% / sessions per host) + 1 spare`. `maxSessionLimit` is the sessions per host, and load balancing is breadth-first. 8-vCPU hosts follow Microsoft's minimum for multi-session and its preference for several smaller VMs over a few large ones.
- **Dedicated:** one VM per user. Concurrency does not reduce the count.
- More than 100 hosts per pool is rejected, which keeps the existing contract limit. Larger estates are split across pools.
- Contract `1.2.0` records the answers in `workload` and the result in `hostPool` and `sessionHosts`. Operators may override the result by editing the file. `Validate` reports any override against the recommendation, and the portal shows the same comparison in its review step.

## Consequences

Sizing figures are **starting estimates, not capacity guarantees**. Microsoft's example classes Outlook and PowerPoint as Heavy, so Standard (Medium) is the less conservative choice for typical office users. Pilot monitoring should confirm density before production sign-off.

The host pool type cannot be changed on an existing pool. Switching between shared and dedicated needs a new pool, or prefix, and a reviewed migration; it is not an in-place rerun. Power/GPU workloads and app groups other than Desktop are out of scope.

## Alternatives rejected

Asking for raw VM size, session limit and host count first exposes infrastructure detail the operator rarely knows. Inferring sizing from licence counts or Entra group size alone ignores concurrency and workload. A single "one size fits all" density hides the difference between frontline and office users.
