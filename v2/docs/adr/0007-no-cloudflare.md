# ADR 0007: No Cloudflare in the MVP

Status: Accepted. Date: 2026-10-11.

## Context

The customer installs all portal components in Azure and uses Entra identity. An additional edge provider adds a separate trust and support boundary.

## Decision

Cloudflare hosting, Access, Workers, proxying and installation dependencies are outside MVP scope. Azure hosts the frontend, API, job execution and data stores.

## Consequences

No Cloudflare account or third-party identity setup is required. Customer DNS and any future edge requirement receive a separate review; neither is necessary for the default Azure hostname installation.

## Alternatives rejected

Split Cloudflare/Azure hosting and edge authentication add complexity without meeting a current requirement.
