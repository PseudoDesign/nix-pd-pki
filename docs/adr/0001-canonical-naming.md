# ADR 0001: Canonical Naming

- Status: Accepted
- Date: 2026-04-08

## Context

Because this project supports PKI infrastructure, traceability matters across source code, runbooks, audits, incident records, and other operational evidence. Multiple namespaces make it harder to prove that references across those artifacts point to the same system.

## Decision

The canonical system name is `pseudo-design-pki`.

Use `pseudo-design-pki` consistently in engineering materials, architecture records, runbooks, incident documentation, control narratives, audit evidence, and similar records.

No abbreviations or alternate short names are allowed for the project namespace.

## Consequences

This removes the need to translate between namespaces and preserves a clear chain between formal documentation and engineering artifacts.

The tradeoff is extra verbosity in code and documentation, but that cost is small compared with the benefit to auditability and operational clarity.
