# pseudo-design-pki

Nix flake workspace for the `pseudo-design-pki` infrastructure.

## Naming

The canonical system name is `pseudo-design-pki`.

Use `pseudo-design-pki` consistently across engineering, operational, and audit-facing materials.

Do not introduce alternate project shorthands or abbreviations.

## Workspace Layout

- `flake.nix`: flake entrypoint and future output wiring
- `.github/workflows/`: CI and repository automation
- `docs/adr/`: architecture decision records
- `docs/runbooks/`: operational procedures
- `nix/checks/`: formatting, lint, and validation checks
- `nix/devshells/`: development shells
- `nix/lib/`: shared Nix helpers
- `packages/`: custom derivations and support tooling
- `modules/nixos/`: reusable NixOS modules
- `systems/`: deployment entrypoints and composed infrastructure
- `tests/nixos/`: NixOS and integration-style tests

## Next Step

Wire formatter, lint, and test checks into the flake and then connect them to CI.
