# ADR 0014: Local web wizard before the hosted portal

Status: Accepted. Date: 2026-10-14.

## Context

The terminal questionnaire works, but operators want dropdowns for subscriptions, regions, time zones and hours, and a searchable Entra group picker. The hosted portal (Phases 2–3) is the long-term answer. It needs customer app registrations, Static Web Apps, an API, workers and approval storage. An intermediate step should give the same experience now without that infrastructure.

## Decision

`avd.ps1 -Mode Web` runs a **local** wizard on the operator's machine:

- A PowerShell `HttpListener` bound to `http://localhost:<port>` (default 8770) serves one self-contained page, [web/index.html](../../web/index.html), with no external scripts, styles or CDNs.
- The page uses the operator's existing Az PowerShell sign-in, the same delegated identity as the CLI. It provides:
  - subscription, region, time zone and working-hours dropdowns;
  - new or existing network, with VNet and subnet dropdowns;
  - a searchable group picker, or create-new;
  - a live sizing recommendation, checked against the region: if the recommended VM size is restricted for the subscription or lacks vCPU quota, the page says so and offers a dropdown of same-vCPU sizes that are available with enough quota (passed to New as `-VmSize`).
- **Create configuration** maps the answers onto the same parameters as `-Mode New` and runs the same code without prompts, so the browser and terminal produce identical, validated contract `1.4.0` files. A missing answer fails the request rather than blocking the server on a hidden prompt.
- **Run Preview** runs the same `Invoke-AvdPreview` as `-Mode Preview` against the saved file. It writes the same plan and shows blockers, warnings and the previewed changes in the page; Preview never changes Azure. The what-if tables also print in the PowerShell window.
- Deploy stays in the CLI, where the operator types the resource group name to approve. The page shows the exact command once Preview has no blockers.

Local-server protections:

- It listens on `localhost` only.
- A random 192-bit session token is required to load the page and in an `X-AVD-Token` header on every API call; the token is removed from the address bar after load.
- `Host` must be `localhost:<port>` (or `127.0.0.1:<port>`) to defeat DNS rebinding, and any `Origin` must be the same local origin.
- A restrictive Content-Security-Policy allows no external sources.
- The page builds elements through DOM APIs rather than `innerHTML` with data.
- It serves JSON only, with `no-store` caching.
- It handles one request at a time and stops from the page or with Ctrl+C.

## Consequences

Operators get a graphical flow without hosting anything. It is a single-user tool for the machine where it runs; it is not multi-user, has no approvals and no persisted jobs. The hosted portal (ADR 0004) remains the target and can reuse the page layout and the API shapes.

## Alternatives rejected

Out-GridView pick lists are Windows-only and still terminal-driven. Building the hosted portal first delays a usable UI behind app registration and hosting decisions. Third-party PowerShell web frameworks add unpinned dependencies to a privileged tool.
