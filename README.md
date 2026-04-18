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
application on NixOS. It now includes a live YubiKey bridge for Raspberry Pi
offline roles, but it does not yet implement destructive on-token root
provisioning or true hardware-backed intermediate signing.

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
- `packages.<linux-system>.install-rpi5-root-yubikey-provisioner-sdcard`
- `packages.aarch64-linux.rpi5-root-yubikey-provisioner-sd-image`
- `packages.aarch64-linux.rpi5-root-intermediate-signer-sd-image`
- `apps.<linux-system>.install-rpi5-root-yubikey-provisioner-sdcard`
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

Build and write the provisioner SD image to a whole-disk SD card device on
Linux:

```bash
nix run .#install-rpi5-root-yubikey-provisioner-sdcard -- --yes /dev/sdX
```

You can also reuse an existing `.img` or `.img.zst` instead of building:

```bash
nix run .#install-rpi5-root-yubikey-provisioner-sdcard -- \
  --image ./result --yes /dev/sdX
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

- replace the current bridge scripts with first-class hardware adapters in the
  upstream workflow app
- move beyond file-backed destructive root provisioning and deterministic
  signed-bundle rendering
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
- the Pi role configs enable `services.pd-pki-workflow.liveHardware.enable` to
  bridge a real inserted YubiKey into the expected `tokenDir` artifacts

Live hardware bridge commands:

- `pd-pki-live-hardware-smoke`
- `pd-pki-live-token-state-export`
- `pd-pki-live-root-identity-export`

The provisioner profile standardizes:

- `/var/lib/pd-pki/workspace/plan`
- `/var/lib/pd-pki/workspace/archive`
- `/var/lib/pd-pki/bundle/root-inventory`
- `pd-pki-root-provision <dry-run|apply>`
- `pd-pki-root-inventory-export`

Provisioner behavior on live hardware:

- `pd-pki-root-provision dry-run` refreshes `tokenDir` from the attached
  YubiKey before calling the upstream workflow
- the live provisioner profile also manages `profile.json` under the hood on
  Raspberry Pi kiosk systems by deriving the expected serial from the inserted
  YubiKey and refreshing both `token/` and `profile/` automatically
- `pd-pki-root-provision apply` is intentionally guarded and refuses to pretend
  it can destructively initialize live hardware unless
  `PD_PKI_ALLOW_FIXTURE_APPLY=1` is set for the existing rehearsal path
- the Raspberry Pi 5 provisioner image boots the local `/gui` into a Chromium
  kiosk on `tty1`, forces a dark presentation, and hides the browser cursor for
  touchscreen operation; additional virtual consoles stay at a normal login
  prompt instead of autologging in
- HDMI touch displays that expose touch over USB are intended to work on the
  provisioner image; connect Pi micro-HDMI to the display HDMI input, connect a
  Pi USB-A port to the display's `Type-C1` touch port, and power the display
  from its `Type-C2` 5V input

The signer profile standardizes:

- `/var/lib/pd-pki/bundle/request`
- `/var/lib/pd-pki/bundle/signed`
- `/var/lib/pd-pki/repository/inventory/root-ca`
- `/var/lib/pd-pki/repository/policy/intermediate-ca`
- `pd-pki-root-inventory-verify <root-name>`
- `pd-pki-root-sign-intermediate <root-name>`

Signer behavior on live hardware:

- verify and sign helpers refresh `tokenDir` from the attached YubiKey before
  calling the upstream workflow
- the inserted token verification is live, but the resulting signed bundle is
  still generated by the current upstream deterministic workflow rather than a
  private-key operation on the device
