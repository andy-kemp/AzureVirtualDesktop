# Deployment experience: pilot first

Status: Phase 1/portal UX requirement. No deployment code implemented here.

The operator should choose an outcome, not fill in a Bicep parameter sheet. The JSON contract remains explicit and versioned for automation, while the guided CLI/portal supplies reviewed defaults, performs discovery and exposes advanced overrides only when needed.

## First-run path

1. Select the already-authorised Azure subscription and target resource group. The app can preselect the current tenant/subscription; it must show both before proceeding.
2. Answer the sizing questions ([ADR 0010](adr/0010-persona-based-sizing.md)). Is this a **shared platform** (pooled multi-session) or **dedicated session hosts** (one personal VM per user)? Which **persona** fits: Frontline (web/line-of-business apps), Standard (Microsoft 365 and Teams) or Heavy? How many **users**, and for shared pools, what **peak concurrency**? The app recommends host count, VM size and sessions per host from Microsoft's sizing guidance, and the operator confirms or overrides. A pilot can simply answer with a small user count. Never imply a workload capacity guarantee.
3. Choose **Dedicated test network** or **Existing network**. The earlier test direction is a dedicated VNet in a dedicated resource group. For a no-peering, no-on-premises test, the app may propose an RFC1918 range after checking visible VNets/peerings, but must show the CIDR and require operator confirmation. If connectivity to other networks is required, ask the network owner for an approved range and subnet layout; do not auto-connect or guess.
4. Confirm the existing AVD user/admin groups and the identity type. Shared pools ask whether users are **hybrid** (synced from AD; needs the documented domain prerequisites) or **cloud-only** (Microsoft preview; needs the storage-app consent, manifest tag and MFA exclusion in [ADR 0011](adr/0011-user-profiles.md)). Dedicated pools keep profiles on the VM and skip this. Discover group names from delegated access where permitted; avoid making operators copy object IDs.
5. Review the plan, estimated cost, image/VM availability, quota, permissions, resources to be created and manual prerequisites. Approval is a clear **Deploy this plan** action.

After the first run, offer **Repeat this deployment** from a saved, non-secret profile; show changes and re-approval rather than asking the whole questionnaire again. For an existing V2 estate, offer:

- **Add capacity** (shared): a number of hosts, or a new user count.
- **Add dedicated user** (personal): search for the user by UPN or name and confirm the match. The app assigns the next free host or adds one.

Both show a short review: new host names, the user's display name, UPN and object ID, and the AVD users group membership change.

## Defaults instead of questions

| Current low-level input | Guided behaviour |
| --- | --- |
| Session-host count | Derived from the sizing questions. Shared: `ceil(users x peak% / sessions per host) + 1 spare`. Dedicated: one per user. Operator confirms; overrides are shown in review. |
| VM size | Derived from persona: shared uses D8s_v5; dedicated uses D2s_v5, D4s_v5 or D8s_v5 by persona. Check regional SKU availability and quota, and allow an advanced override with validation. |
| Host pool type / sessions per host | Derived from shared vs dedicated and persona (48, 32 or 16 sessions on 8 vCPU). Not asked directly. |
| Hostname prefix | Generate from the deployment name/prefix; preview final names and Windows 15-character limit. |
| Local administrator username | Generate a compliant per-install name; show it in the review. Do not ask for a preferred username unless policy requires it. |
| Administrator password / Key Vault secret URI | Do not ask the operator to supply either value in the normal flow. Generate a strong random secret server-side and store it in the customer Key Vault, or use an approved image/identity flow that avoids a standing local secret. Resolve the security owner/rotation/retrieval model before choosing the implementation. Never put the secret in a config file, CLI argument, job message or output. |
| Prep-script URL and SHA-256 | Pin the script in the signed/reviewed V2 release or worker image. Verify its digest as part of build/release and at execution. Operators see the artifact version, not a URL/hash field. |
| Storage name | Derive a globally unique compliant name from the deployment prefix; allow regenerate/edit if occupied. |
| DNS servers / private DNS toggle | Discover the selected VNet's DNS configuration and relevant private DNS links. Recommend the known-good option, explain custom DNS requirements and ask only when the choice changes connectivity. |
| Scaling schedule | Offer presets instead of raw phase fields: **Business hours** (weekday ramp-up/peak/ramp-down/off-peak, with weekends at minimum), **Always available** (no plan), and **Custom**. Default the time zone from the selected region and let the operator confirm it. Shared pools always keep one host on and, during working hours, keep one empty host ready, so each new user lands on an unused host until every host is running. Users are then spread breadth-first, and hosts with active or disconnected sessions are never shut down ([ADR 0009](adr/0009-native-avd-autoscale.md#business-hours-preset-behaviour)). Recommend a disconnected-session time limit policy so forgotten sessions do not keep hosts running. Dedicated pools use Start VM on Connect and deallocate after disconnect or logoff timers; state that a deallocated disconnected session loses unsaved work. Production asks for working hours and an acceptable morning start-up delay. Keep forced logoff off unless explicitly chosen, and show the minimum hosts per phase and an estimated running-hours saving in the review. Check the subscription power-role prerequisite and show a clear blocker or admin hand-off if it is missing. |

These are proposed interaction defaults, not permission to weaken controls. If the portal cannot safely derive/verify a value, show the reason and request that specific decision instead of silently inventing it.

## Secrets and artifacts

The current contract carries a Key Vault secret URI and a preparation-script URI/digest because it is an automation contract. That is suitable for a reviewed pipeline profile, but not the ordinary user questionnaire. Separate the UX from the contract: the portal resolves a customer-owned secret reference and a release-owned immutable artifact after approval. Only opaque secret references and artifact digests reach the worker; the secret value is retrieved just in time by the intended identity and never persisted in job state.

Before implementation, decide whether the generated local VM administrator secret is retained with an expiry/rotation policy, whether retrieval is disabled after provisioning, or whether the selected supported image/join workflow can avoid creating a reusable local credential. Do not generate a password and then silently leave it retrievable forever.

## This sandbox test

The intended subscription is the MVP subscription, and the selected test topology is dedicated networking plus a new resource group. The currently selected Azure extension context sees that subscription; the separate Azure CLI sign-in has previously failed CA checks, so a V2 Azure `Preview`/`Deploy` command must not proceed until the operator/deployment identity context is explicit and verified.

To make the next test low-friction, the app should present a **dedicated-network AVD pilot** plan with one host, generated names/credentials, a recommended VM size, a reviewed V2 prep artifact, and a proposed network range. It should then ask the operator to confirm the visible CIDR, expected connectivity (isolated vs connected), and the actual AVD groups/domain prerequisites. Resource creation still waits for an explicit plan approval and separate sandbox go-ahead.
