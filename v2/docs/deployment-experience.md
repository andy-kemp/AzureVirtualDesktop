# Deployment experience: pilot first

Status: Phase 1/portal UX requirement. No deployment code implemented here.

The operator should choose an outcome, not fill in a Bicep parameter sheet. The JSON contract remains explicit and versioned for automation, while the guided CLI/portal supplies reviewed defaults, performs discovery and exposes advanced overrides only when needed.

## First-run path

1. Select the already-authorised Azure subscription and target resource group. The app can preselect the current tenant/subscription; it must show both before proceeding.
2. Choose **AVD pilot** or **AVD production**. Pilot defaults to one session host and a modest, region-supported VM size. Production asks for expected concurrent users and a simple workload class, then recommends a host count/size that the operator confirms. Never infer a workload capacity guarantee.
3. Choose **Dedicated test network** or **Existing network**. The earlier test direction is a dedicated VNet in a dedicated resource group. For a no-peering, no-on-premises test, the app may propose an RFC1918 range after checking visible VNets/peerings, but must show the CIDR and require operator confirmation. If connectivity to other networks is required, ask the network owner for an approved range and subnet layout; do not auto-connect or guess.
4. Confirm the existing AVD user/admin groups and the hybrid identity profile's domain details. Discover group names from delegated access where permitted; avoid making operators copy object IDs. Explain that Azure Files Kerberos needs the documented domain prerequisites.
5. Review the plan, estimated cost, image/VM availability, quota, permissions, resources to be created and manual prerequisites. Approval is a clear **Deploy this plan** action.

After the first run, offer **Repeat this deployment** from a saved, non-secret profile; show changes and re-approval rather than asking the whole questionnaire again.

## Defaults instead of questions

| Current low-level input | Guided behaviour |
| --- | --- |
| Session-host count | Pilot default: 1. Production: recommend from concurrent-user estimate and workload preset; operator confirms. |
| VM size | Recommend from workload preset, image compatibility, regional SKU availability and quota; allow advanced override with validation. |
| Hostname prefix | Generate from the deployment name/prefix; preview final names and Windows 15-character limit. |
| Local administrator username | Generate a compliant per-install name; show it in the review. Do not ask for a preferred username unless policy requires it. |
| Administrator password / Key Vault secret URI | Do not ask the operator to supply either value in the normal flow. Generate a strong random secret server-side and store it in the customer Key Vault, or use an approved image/identity flow that avoids a standing local secret. Resolve the security owner/rotation/retrieval model before choosing the implementation. Never put the secret in a config file, CLI argument, job message or output. |
| Prep-script URL and SHA-256 | Pin the script in the signed/reviewed V2 release or worker image. Verify its digest as part of build/release and at execution. Operators see the artifact version, not a URL/hash field. |
| Storage name | Derive a globally unique compliant name from the deployment prefix; allow regenerate/edit if occupied. |
| DNS servers / private DNS toggle | Discover the selected VNet's DNS configuration and relevant private DNS links. Recommend the known-good option, explain custom DNS requirements and ask only when the choice changes connectivity. |

These are proposed interaction defaults, not permission to weaken controls. If the portal cannot safely derive/verify a value, show the reason and request that specific decision instead of silently inventing it.

## Secrets and artifacts

The current contract carries a Key Vault secret URI and a preparation-script URI/digest because it is an automation contract. That is suitable for a reviewed pipeline profile, but not the ordinary user questionnaire. Separate the UX from the contract: the portal resolves a customer-owned secret reference and a release-owned immutable artifact after approval. Only opaque secret references and artifact digests reach the worker; the secret value is retrieved just in time by the intended identity and never persisted in job state.

Before implementation, decide whether the generated local VM administrator secret is retained with an expiry/rotation policy, whether retrieval is disabled after provisioning, or whether the selected supported image/join workflow can avoid creating a reusable local credential. Do not generate a password and then silently leave it retrievable forever.

## This sandbox test

The intended subscription is the MVP subscription, and the selected test topology is dedicated networking plus a new resource group. The currently selected Azure extension context sees that subscription; the separate Azure CLI sign-in has previously failed CA checks, so a V2 Azure `Preview`/`Deploy` command must not proceed until the operator/deployment identity context is explicit and verified.

To make the next test low-friction, the app should present a **Dedicated AVD pilot** plan with one host, generated names/credentials, a recommended VM size, a reviewed V2 prep artifact, and a proposed network range. It should then ask the operator to confirm the visible CIDR, expected connectivity (isolated vs connected), and the actual AVD groups/domain prerequisites. Resource creation still waits for an explicit plan approval and separate sandbox go-ahead.
