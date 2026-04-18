# nix-pd-pki

Minimal NixOS integration layer for
[`PseudoDesign/pd-pki-python`](https://github.com/PseudoDesign/pd-pki-python).

This repository follows the first implementation slice from the Python
repository's `docs/NIXOS_INTEGRATION_GUIDE.md` handoff:

- import the Python workflow app as a flake input
- expose a reusable `services.pd-pki-workflow` NixOS module
- ship one minimal host configuration
- verify the boundary with a VM smoke test

## Current scope

This repository packages and runs the existing file-backed FastAPI and GUI
application on NixOS. It does not yet add real YubiKey, PKCS#11, USB policy,
or hardware-specific ceremony automation.

Current outputs:

- `nixosModules.default`
- `nixosModules.pd-pki-workflow`
- `nixosConfigurations.hardware-lab`
- `checks.<system>.module-eval`
- `checks.<system>.vm-smoke`

The imported application package and console entrypoints are also passed
through as flake outputs:

- `packages.<system>.pd-pki`
- `apps.<system>.pd-pki-api`
- `apps.<system>.pd-pki-workflow`
- `apps.<system>.pd-pki-mock-api`

## Quick start

Evaluate and build the integration checks:

```bash
nix flake check
```

Build the generic lab configuration:

```bash
nix build .#nixosConfigurations.hardware-lab.config.system.build.toplevel
```

Build the VM smoke test directly:

```bash
nix build .#checks.x86_64-linux.vm-smoke
```

## Runtime layout

The module creates and grants the service access to:

```text
/var/lib/pd-pki/
├── profile/
├── token/
├── workspace/
├── bundle/
└── repository/
```

These paths match the current file-backed API and GUI model in
`pd-pki-python`.

## Next steps

The handoff guide's remaining phases are still ahead of this repo:

- add a real hardware-target configuration and image build
- move beyond fixture-backed token behavior
- add hardware-aware integration and offline workflow tests
