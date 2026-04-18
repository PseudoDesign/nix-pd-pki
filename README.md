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
- `nixosConfigurations.rpi5-root-yubikey-provisioner`
- `nixosConfigurations.rpi5-root-intermediate-signer`
- `checks.<system>.module-eval`
- `checks.<system>.vm-smoke`
- `checks.<system>.offline-systems-eval`
- `checks.<system>.offline-profiles-vm`

The imported application package and console entrypoints are also passed
through as flake outputs:

- `packages.<system>.pd-pki`
- `packages.aarch64-linux.rpi5-root-yubikey-provisioner-sd-image`
- `packages.aarch64-linux.rpi5-root-intermediate-signer-sd-image`
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

Build the Raspberry Pi 5 offline images:

```bash
nix build .#packages.aarch64-linux.rpi5-root-yubikey-provisioner-sd-image
nix build .#packages.aarch64-linux.rpi5-root-intermediate-signer-sd-image
```

Build the VM smoke test directly:

```bash
nix build .#checks.x86_64-linux.vm-smoke
nix build .#checks.x86_64-linux.offline-profiles-vm
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

- replace the current file-backed token contracts with real hardware adapters
- move beyond fixture-backed token behavior
- add hardware-aware integration and offline workflow tests

## Offline systems

The repository now defines a shared offline root-CA ceremony base plus two
separate role-specific systems:

- `rpi5-root-yubikey-provisioner`
- `rpi5-root-intermediate-signer`

They are intentionally separate images because they represent different custody
boundaries:

- the provisioner handles destructive root-token initialization and public
  inventory export
- the signer handles routine root-identity verification plus intermediate
  request signing

Both images currently sit on the same app boundary from `pd-pki-python`:

- `pd-pki-api` serves the local GUI at `/gui`
- `pd-pki-workflow` performs the actual root provision, inventory, and request
  signing steps
- the runtime is still file-backed under `/var/lib/pd-pki`

The provisioner profile standardizes:

- `/var/lib/pd-pki/workspace/plan`
- `/var/lib/pd-pki/workspace/archive`
- `/var/lib/pd-pki/bundle/root-inventory`
- `pd-pki-root-provision <dry-run|apply>`
- `pd-pki-root-inventory-export`

The signer profile standardizes:

- `/var/lib/pd-pki/bundle/request`
- `/var/lib/pd-pki/bundle/signed`
- `/var/lib/pd-pki/repository/inventory/root-ca`
- `/var/lib/pd-pki/repository/policy/intermediate-ca`
- `pd-pki-root-inventory-verify <root-name>`
- `pd-pki-root-sign-intermediate <root-name>`
