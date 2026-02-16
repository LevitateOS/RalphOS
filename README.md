# RalphOS

## Deprecation Notice

This crate is **deprecated** as a primary distro entrypoint.

New conformance-driven work must move to:
- `distro-variants/ralph`

Reason:
- We need tighter Stage 00+ conformance enforcement in one place.
- Legacy per-OS crate drift can hide inconsistencies.
- Shared invariants should live in `distro-builder`; variant-specific declarations should live in `distro-variants/*`.

RalphOS legacy Stage 00 builder remains for transition/reference until the variant migration is complete.
