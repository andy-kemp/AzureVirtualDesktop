# ADR 0002: Customer-owned Entra sign-in

Status: Accepted. Date: 2026-10-11.

## Context

The portal needs customer identity policies and delegated downstream access without collecting administrator passwords.

## Decision

Use Microsoft Entra ID only and customer-owned single-tenant app registrations created during bootstrap. Use a SPA registration plus a protected API registration, both `AzureADMyOrg`; single-tenant describes their account audience. MSAL uses authorisation code with PKCE for the SPA. API-audience access tokens carry API app roles; the API uses on-behalf-of (OBO) tokens for delegated discovery/preview.

Configure exact tenant issuer, redirect URIs and token audiences. Use a customer-controlled certificate for the API's confidential-client OBO credential. It is not a deployment identity. Do not use SWA's shared preconfigured identity registrations or invite-based roles as the API security boundary.

## Consequences

Bootstrap records both registration/object IDs and exposes an API delegated scope. Entra MFA/Conditional Access applies. No client secret or certificate goes into the SPA. Prove bearer forwarding through the SWA linked API and OBO in a later integration check; never fall back to trusting caller-supplied identity headers.

## Alternatives rejected

Clerk, third-party providers, local passwords, shared administrator logins and a multitenant app audience do not meet the locked identity boundary. SWA managed authentication alone does not establish the API's delegated token flow.

## Source

[Microsoft Learn: SPA calling a web API](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-spa-overview) and [OBO flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow).
