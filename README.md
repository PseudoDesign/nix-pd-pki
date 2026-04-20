# pd-pki

Nix-based PKI workflow toolkit for Pseudo Design.

`pd-pki` publishes deterministic, machine-readable PKI workflow contracts for
four certificate roles, provides NixOS modules for managing mutable runtime
artifacts, and ships tooling for external signing, import, revocation, CRL
generation, and air-gapped operator handoff.

## Root PKI Image Quick Start

### Build the root PKI image

```bash
nix build .#packages.aarch64-linux.rpi5-root-yubikey-provisioner-sd-image
```

This produces the compressed SD-card image at:

```text
result/sd-image/pd-pki-rpi5-root-yubikey-provisioner.img.zst
```

If you build from a non-`aarch64-linux` host, you will usually need either
binfmt emulation or an `aarch64-linux` builder available to Nix.

### Program the SD card

Identify the SD-card device, then write the image to the whole device, not an
individual partition:

```bash
lsblk -p
sudo umount /dev/sdX1 /dev/sdX2
sudo zstd -d --stdout result/sd-image/pd-pki-rpi5-root-yubikey-provisioner.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

Replace `/dev/sdX` with the actual SD-card device such as `/dev/sdb` or
`/dev/mmcblk0`.

### Boot and run the root provisioner

Insert the card into the Raspberry Pi 5 and boot the appliance. The root
provisioner image:

- auto-logs the `pdpki` account into the local graphical session
- launches the YubiKey provisioning wizard automatically
- runs a touch-friendly kiosk session with a hidden cursor and 15-minute
  inactivity screen blanking
- exports `/etc/pd-pki/root-yubikey-init-profile.json` for the root YubiKey
  ceremony
- allows YubiKeys, USB mass storage, and kiosk-input HID devices such as
  generic USB touchscreens through `usbguard`

For the detailed root ceremony and signer procedures, see:

- [docs/SIGNER_WORKFLOWS.md](docs/SIGNER_WORKFLOWS.md)
- [docs/sops/ROOT_CA_YUBIKEY_INITIALIZATION_SOP.md](docs/sops/ROOT_CA_YUBIKEY_INITIALIZATION_SOP.md)
- [docs/sops/ROOT_CA_INTERMEDIATE_SIGNING_SOP.md](docs/sops/ROOT_CA_INTERMEDIATE_SIGNING_SOP.md)

### Normalize the exported root artifacts into this repository

After the wizard writes the public root-inventory bundle to removable media,
move that flash drive to the development machine and mount it at `./mnt`.

Run the helper from the repository root:

```bash
nix run .#pd-pki-normalize-root-inventory-from-mount -- ./mnt
```

The helper finds the newest bundle under
`<mountpoint>/pd-pki-transfer/root-inventory/`, normalizes it into
`inventory/root-ca/<root-id>/`, stages that directory with `git add`, and
prints a short root certificate metadata summary.

For the copied file list and git status too, use:

```bash
nix run .#pd-pki-normalize-root-inventory-from-mount -- -v ./mnt
```

## Repository Usage

### Build exported contracts and tooling

```bash
nix build .#pd-pki
nix build .#pd-pki-signing-tools
nix build .#pd-pki-operator
nix build .#pd-pki-normalize-root-inventory-from-mount
```

### Build role and step packages

```bash
nix build .#root-certificate-authority
nix build .#intermediate-signing-authority
nix build .#openvpn-server-leaf
nix build .#openvpn-client-leaf

nix build .#root-certificate-authority-create-root-ca
nix build .#openvpn-server-leaf-package-openvpn-server-deployment-bundle
```

### Inspect the machine-readable contract

```bash
nix eval --json .#lib.definitions | jq .
nix eval --json .#lib.checkNames | jq .
```

### Validate and generate a report

```bash
nix flake check -L --keep-going
nix run .#test-report
nix run .#test-report -- --verbose
```

`test-report` writes output to `reports/test-report-<timestamp>/` and produces
`report.md`, `report.json`, `index.html`, `style.css`, and per-check logs.

### Run the operator wizard

```bash
nix run .#pd-pki-operator
nix run .#pd-pki-operator -- --help
```

## Overview

- 4 roles are implemented: root CA, intermediate signing authority, OpenVPN
  server leaf, and OpenVPN client leaf
- 19 workflow steps are modeled and exported as buildable flake packages
- role packages emit public PEM and JSON artifacts plus per-step metadata and
  status files
- NixOS modules expose each role under `services.pd-pki.roles.*` and manage
  mutable runtime artifacts under `/var/lib/pd-pki`
- `pd-pki-signing-tools` exports request bundles, signs them with an external
  issuer, imports signed results, manages signer-side issuance state, records
  revocations, and generates CRLs
- `pd-pki-operator` provides an interactive removable-media workflow around the
  signer tooling
- `test-report` runs exported checks and writes Markdown, JSON, and HTML output

Operational boundaries:

- runtime roles expect keys, CSRs, certificates, chains, and CRLs to come from
  external provisioners or signing workflows
- hardware-backed root and intermediate custody are external to this repository
- derivation outputs are deterministic reference artifacts, not live CA state

## Repository Model

`pd-pki` models PKI workflows as deterministic Nix derivations built with
`openssl` and `jq`.

Each role package produces:

- `role.json` with role metadata
- `steps.json` with the ordered workflow definition
- `steps/<step-id>/define.json` with the step contract
- `steps/<step-id>/checks.json` with declared validations
- `steps/<step-id>/status.json` with the implementation summary
- `steps/<step-id>/artifacts/...` with representative public PEM and JSON
  outputs

The aggregate `pd-pki` package is a link farm that exposes the four role
packages together.

When a role module is enabled, deployment nodes keep mutable runtime artifacts
under `/var/lib/pd-pki/...`, emit signer-facing request metadata, and expect
certificates and chains to be staged from an external signing workflow.

## Implemented Roles

- `root-certificate-authority`: 5 steps covering deterministic root creation,
  rotation, representative intermediate issuance and revocation, and trust
  publication
- `intermediate-signing-authority`: 6 steps covering intermediate creation,
  rotation, representative leaf issuance and revocation, and trust publication
- `openvpn-server-leaf`: 4 steps covering CSR generation, deployment bundle
  packaging, certificate rotation, and trust consumption
- `openvpn-client-leaf`: 4 steps covering CSR generation, credential bundle
  packaging, certificate rotation, and trust consumption

## Raspberry Pi 5 Images

The flake exports dedicated Raspberry Pi 5 appliance configurations at:

- `nixosConfigurations.rpi5-root-yubikey-provisioner`
- `nixosConfigurations.rpi5-root-intermediate-signer`

plus convenience SD image packages at:

- `packages.aarch64-linux.rpi5-root-yubikey-provisioner-sd-image`
- `packages.aarch64-linux.rpi5-root-intermediate-signer-sd-image`

For compatibility, `nixosConfigurations.rpi5-root-ca` and
`packages.aarch64-linux.rpi5-root-ca-sd-image` currently alias the provisioning
image.

The images combine the `pd-pki` root CA module with
[`nixos-raspberrypi`](https://github.com/nvmd/nixos-raspberrypi) for Raspberry
Pi 5 bootloader, firmware, kernel, and SD image support.

Build the appliance images with:

```bash
nix build .#packages.aarch64-linux.rpi5-root-yubikey-provisioner-sd-image
nix build .#packages.aarch64-linux.rpi5-root-intermediate-signer-sd-image
```

Operational defaults for the provisioner appliance:

- boots into an offline root CA workstation profile
- exports `/etc/pd-pki/root-yubikey-init-profile.json` for the root YubiKey
  ceremony
- disables NetworkManager, onboard Wi-Fi, and onboard Bluetooth
- runs a touch-friendly kiosk session with a hidden cursor and 15-minute
  inactivity screen blanking
- uses `usbguard` to allow YubiKeys, USB mass storage, and kiosk-input HID
  devices such as generic USB touchscreens
- auto-launches the graphical provisioning wizard for YubiKey setup and media
  export

Operational defaults for the intermediate signer appliance:

- boots into the same offline root CA workstation profile
- runs the same touch-friendly kiosk session with a hidden cursor and 15-minute
  inactivity screen blanking
- auto-launches a graphical intermediate-signing wizard
- copies the request bundle from removable media into a local ceremony work
  directory
- walks the operator through CSR review and committed root-inventory selection
- verifies the inserted root CA YubiKey before signing
- reformats a fresh export drive for the signed bundle handoff

If you build from a non-`aarch64-linux` host, you will usually need either
binfmt emulation or an `aarch64-linux` builder available to Nix.

Detailed ceremony and signer workflow guidance lives in
[docs/SIGNER_WORKFLOWS.md](docs/SIGNER_WORKFLOWS.md) and the SOPs under
[`docs/sops/`](docs/sops).

## NixOS Modules

Each role has a NixOS module built from
[`modules/mk-role-module.nix`](modules/mk-role-module.nix).
Available option paths are:

- `services.pd-pki.roles.rootCertificateAuthority`
- `services.pd-pki.roles.intermediateSigningAuthority`
- `services.pd-pki.roles.openvpnServerLeaf`
- `services.pd-pki.roles.openvpnClientLeaf`

A typical configuration imports the flake module and points each role at
externally provisioned request or import material:

```nix
{
  imports = [ inputs.pd-pki.nixosModules.default ];

  services.pd-pki.roles.openvpnServerLeaf = {
    enable = true;
    request = {
      basename = "vpn-server";
      commonName = "vpn.example.test";
      extraSubjectAltNames = [
        "DNS:openvpn.example.test"
        "IP:127.0.0.1"
      ];
      requestedProfile = "serverAuth";
      requestedDays = 825;
    };
    refreshInterval = "5m";
    provisioningUnits = [ "vault-agent.service" ];
    reloadUnits = [ "openvpn-server.service" ];
    keyCredentialPath = "/run/secrets/openvpn/server.key.pem";
    certificateSourcePath = "/var/lib/pd-pki/imports/server.cert.pem";
    chainSourcePath = "/var/lib/pd-pki/imports/server.chain.pem";
    crlSourcePath = "/var/lib/pd-pki/imports/intermediate.crl.pem";
  };

  services.pd-pki.roles.openvpnClientLeaf.request = {
    basename = "laptop-client";
    commonName = "laptop-01.example.test";
    requestedProfile = "clientAuth";
    requestedDays = 825;
  };
}
```

Provisioned inputs can be supplied as plain file paths through `*SourcePath`
options or loaded into the pd-pki units as systemd credentials through
`*CredentialPath` options. Imported artifacts are validated before they replace
live runtime files, and failed validation leaves the last good state untouched.

See [docs/NIXOS_MODULES.md](docs/NIXOS_MODULES.md) for the full runtime model,
role behavior, and example configurations.

## Flake Outputs

The flake exports the following top-level outputs:

- `packages`: aggregate package, signer tooling, operator tooling, role
  packages, step packages, and Raspberry Pi SD images on `aarch64-linux`
- `checks`: aggregate package checks, role and step checks, module checks, and
  Linux-only topology/OpenVPN integration tests
- `nixosModules`: `default` plus one module per role
- `nixosConfigurations`: Raspberry Pi root appliance configurations
- `apps`: `test-report` and `pd-pki-operator`
- `lib`: `definitions`, `roles`, `roleCount`, `stepCount`, and `checkNames`

Outputs are generated for:

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin`
- `aarch64-darwin`

The heavier NixOS VM tests run only on Linux hosts.

## Validation

Checks in [`checks/`](checks/) cover:

- aggregate package wiring
- role and step artifact presence
- JSON parsing plus X.509, CSR, SAN, EKU, and chain validation
- NixOS module evaluation and runtime artifact staging behavior
- Linux-only multi-node topology verification
- Linux-only OpenVPN daemon verification, including CRL-based client rejection

The Linux-only
[`role-topology` check](checks/nixos-role-topology.nix) adds
a multi-node NixOS test on top of the direct derivation-based checks. The
Linux-only
[`openvpn-daemon` check](checks/openvpn-daemon.nix) exercises
real OpenVPN server and client daemons against staged signer outputs and CRL
updates.

## Repository Layout

```text
.
├── apps/
├── checks/
├── docs/
├── modules/
├── packages/
├── systems/
├── flake.nix
└── README.md
```

Key files:

- [`flake.nix`](flake.nix) wires together packages, checks,
  modules, apps, and helper lib values
- [`packages/definitions.nix`](packages/definitions.nix) is
  the source of truth for role and step contracts
- [`packages/pd-pki-signing-tools.nix`](packages/pd-pki-signing-tools.nix)
  defines the external signer, signer-state, and CRL tooling
- [`packages/pd-pki-operator.nix`](packages/pd-pki-operator.nix)
  defines the interactive removable-media operator wizard
- [`packages/pd-pki-normalize-root-inventory-from-mount.nix`](packages/pd-pki-normalize-root-inventory-from-mount.nix)
  packages the mounted-media root-inventory normalization helper

## Further Reading

- [docs/NIXOS_MODULES.md](docs/NIXOS_MODULES.md)
- [docs/SIGNER_WORKFLOWS.md](docs/SIGNER_WORKFLOWS.md)
- [docs/ROOT_CA_WORKFLOW_CONTRACTS.md](docs/ROOT_CA_WORKFLOW_CONTRACTS.md)
- [docs/sops/ROOT_CA_YUBIKEY_INITIALIZATION_SOP.md](docs/sops/ROOT_CA_YUBIKEY_INITIALIZATION_SOP.md)
- [docs/sops/ROOT_CA_YUBIKEY_INITIALIZATION_MANUAL_SOP.md](docs/sops/ROOT_CA_YUBIKEY_INITIALIZATION_MANUAL_SOP.md)
- [docs/sops/ROOT_CA_INTERMEDIATE_SIGNING_SOP.md](docs/sops/ROOT_CA_INTERMEDIATE_SIGNING_SOP.md)
