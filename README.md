# pd-pki

Nix-based PKI workflow fixtures for Pseudo Design.

This repository is no longer just a scaffold. It now builds deterministic, machine-readable PKI workflow outputs for four certificate roles and validates them with Nix checks, NixOS module evaluation, and Linux VM tests.

## Current State

- 4 roles are implemented: root CA, intermediate signing authority, OpenVPN server leaf, and OpenVPN client leaf
- 19 workflow steps are modeled and exported as buildable flake packages
- 31 named checks are exported from the flake
- role packages emit public PEM and JSON artifacts plus per-step metadata and status files
- NixOS modules expose each role under `services.pd-pki.roles.*`; they manage mutable runtime artifacts under `/var/lib/pd-pki` without bootstrapping a CA hierarchy on deployment nodes
- `pd-pki-signing-tools` exports signer request bundles, signs them with an external issuer, imports signed artifacts back into runtime state, and can persist signer-side issuance state with automatic serial allocation and revocation metadata
- a `test-report` app runs all exported checks and writes Markdown and JSON reports

## What This Repository Is Today

`pd-pki` currently models PKI workflows as deterministic Nix derivations built with `openssl` and `jq`.

Each role package produces:

- `role.json` with role metadata
- `steps.json` with the ordered workflow definition
- `steps/<step-id>/define.json` with the step contract
- `steps/<step-id>/checks.json` with declared validations
- `steps/<step-id>/status.json` with the implementation summary
- `steps/<step-id>/artifacts/...` with representative public PEM and JSON outputs

The aggregate `pd-pki` package is a link farm that exposes the four role packages together.

When a role module is enabled, deployment nodes keep mutable runtime artifacts under `/var/lib/pd-pki/...`, generate only the local key and CSR material they own where appropriate, emit signer-facing JSON request metadata, and expect certificates and chains to be staged from an external signing workflow.

## What It Is Not Yet

This repo is still test-oriented rather than production-ready PKI automation:

- private keys used for runtime services are generated in software under `/var/lib/pd-pki`; they are not hardware-backed or escrowed
- root and intermediate hardware-backed flows are simulated, not integrated with YubiKey or HSM hardware
- revocation is represented as JSON metadata, not CRLs or OCSP
- issuance inputs are fixed representative values baked into the derivations today
- role packages still model certificate authorities as deterministic fixtures rather than an offline or HSM-backed production signing workflow

## Implemented Roles

### Root Certificate Authority

Implements 5 steps:

- `create-root-ca`
- `rotate-root-ca`
- `sign-intermediate-ca-certificate`
- `revoke-intermediate-ca-certificate`
- `publish-root-trust-artifacts`

This package creates a deterministic self-signed test root CA, simulates root rotation, signs a representative intermediate CA, records revocation metadata for that intermediate, and publishes a root trust bundle.

### Intermediate Signing Authority

Implements 6 steps:

- `create-intermediate-ca`
- `rotate-intermediate-ca`
- `sign-openvpn-server-leaf-certificate`
- `sign-openvpn-client-leaf-certificate`
- `revoke-leaf-certificate`
- `publish-intermediate-trust-artifacts`

This package creates and rotates an intermediate CA signed by the test root, signs representative OpenVPN server and client certificates, records leaf revocation metadata, and publishes an intermediate trust bundle.

### OpenVPN Server Leaf

Implements 4 steps:

- `create-openvpn-server-leaf-request`
- `package-openvpn-server-deployment-bundle`
- `rotate-openvpn-server-certificate`
- `consume-server-trust-updates`

This package generates a representative server CSR, signs and packages a public deployment bundle, creates a rotated server certificate, and stages trust updates for server-side validation. Runtime server keys live under `/var/lib/pd-pki/openvpn-server-leaf`.

### OpenVPN Client Leaf

Implements 4 steps:

- `create-openvpn-client-leaf-request`
- `package-openvpn-client-credential-bundle`
- `rotate-openvpn-client-certificate`
- `consume-client-trust-updates`

This package generates a representative client CSR, signs and packages a public client credential bundle, creates a rotated client certificate, and stages trust updates for client-side validation. Runtime client keys live under `/var/lib/pd-pki/openvpn-client-leaf`.

## Flake Outputs

The flake exports the following top-level outputs:

- `packages`
  - `pd-pki`
  - `pd-pki-signing-tools`
  - one package per role
  - one package per workflow step, named `<role-id>-<step-id>`
- `checks`
  - aggregate package check
  - role and step checks
  - NixOS module checks
  - `module-runtime-artifacts` check
  - `role-topology` check
- `nixosModules`
  - `default`
  - `root-certificate-authority`
  - `intermediate-signing-authority`
  - `openvpn-server-leaf`
  - `openvpn-client-leaf`
- `apps.test-report`
- `define`
  - the machine-readable role and step contract from [`packages/definitions.nix`](/home/adam/pd-pki/packages/definitions.nix)
- `lib`
  - `roles`
  - `roleCount`
  - `stepCount`
  - `checkNames`

Outputs are generated for:

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin`
- `aarch64-darwin`

The heavier NixOS VM tests run only on Linux hosts.

## Package Layout

Building any role package yields a directory shaped like this:

```text
result/
├── role.json
├── steps.json
└── steps/
    └── <step-id>/
        ├── artifacts/
        ├── checks.json
        ├── define.json
        └── status.json
```

Building a step package yields the corresponding `steps/<step-id>` directory directly.

Representative artifact types currently include:

- self-signed and issued X.509 certificates
- CSRs
- certificate chains
- deployment and credential bundles
- trust bundle directories
- JSON manifests, issuance metadata, revocation records, and publication metadata

## Validation

Checks in [`checks/`](/home/adam/pd-pki/checks) currently cover:

- aggregate package wiring
- role and step artifact presence
- JSON parsing for declared metadata files
- X.509 and CSR parsing
- chain verification
- CA basic constraints
- server and client extended key usage validation
- SAN presence checks
- NixOS module evaluation
- Linux-only verification that runtime modules generate only their local mutable artifacts, export signer request bundles, complete a root-to-intermediate-to-leaf signing roundtrip, and import signed certificates without bootstrapping a CA chain

The Linux-only [`role-topology` check](/home/adam/pd-pki/checks/nixos-role-topology.nix) adds a multi-node NixOS test on top of the direct derivation-based role and step checks exported on every supported system.

## NixOS Modules

Each role has a NixOS module built from [`modules/mk-role-module.nix`](/home/adam/pd-pki/modules/mk-role-module.nix). Enabling a role module:

- exposes the role package under `/etc/pd-pki/<role-id>` by default
- can add the role package to `environment.systemPackages`
- exposes read-only `definition` and `stepIds` values derived from the workflow contract

Each role module now has a single runtime behavior:

- `services.pd-pki.roles.rootCertificateAuthority` stages operator-provided root key, CSR, certificate, and optional metadata into mutable runtime paths.
- `services.pd-pki.roles.intermediateSigningAuthority` generates a local CA key and CSR, writes `signing-request.json`, then stages an imported intermediate certificate, chain, and optional metadata.
- `services.pd-pki.roles.openvpnServerLeaf` generates a local key and CSR, writes `issuance-request.json` plus `san-manifest.json`, then stages an imported server certificate, chain, and optional metadata.
- `services.pd-pki.roles.openvpnClientLeaf` generates a local key and CSR, writes `issuance-request.json` plus `identity-manifest.json`, then stages an imported client certificate, chain, and optional metadata.

Available option paths are:

- `services.pd-pki.roles.rootCertificateAuthority`
- `services.pd-pki.roles.intermediateSigningAuthority`
- `services.pd-pki.roles.openvpnServerLeaf`
- `services.pd-pki.roles.openvpnClientLeaf`

Example:

```nix
{
  imports = [ inputs.pd-pki.nixosModules.default ];

  services.pd-pki.roles.openvpnServerLeaf = {
    enable = true;
    certificateSourcePath = "/var/lib/pd-pki/imports/server.cert.pem";
    chainSourcePath = "/var/lib/pd-pki/imports/server.chain.pem";
  };

  services.pd-pki.roles.openvpnClientLeaf = {
    enable = true;
    certificateSourcePath = "/var/lib/pd-pki/imports/client.cert.pem";
    chainSourcePath = "/var/lib/pd-pki/imports/client.chain.pem";
  };
}
```

## External Signer Workflow

The repo now ships a small operator CLI as the `pd-pki-signing-tools` package. It turns the runtime artifacts emitted by the NixOS modules into portable request bundles, signs those bundles with an external issuer, and imports the signed results back into the mutable runtime paths.

Build it with:

```bash
nix build .#pd-pki-signing-tools
```

Typical flow:

1. On the request-generating node, export a signer bundle:

```bash
pd-pki-signing-tools export-request \
  --role openvpn-server-leaf \
  --state-dir /var/lib/pd-pki/openvpn-server-leaf \
  --out-dir /tmp/server-request
```

2. On the signer, sign the bundle with the issuing CA key and certificate:

```bash
pd-pki-signing-tools sign-request \
  --request-dir /tmp/server-request \
  --out-dir /tmp/server-signed \
  --issuer-key /secure/issuer/intermediate-ca.key.pem \
  --issuer-cert /secure/issuer/intermediate-ca.cert.pem \
  --issuer-chain /secure/issuer/chain.pem \
  --signer-state-dir /secure/issuer/state/intermediate \
  --days 825
```

3. Back on the request node, import the signed bundle into runtime state:

```bash
pd-pki-signing-tools import-signed \
  --role openvpn-server-leaf \
  --state-dir /var/lib/pd-pki/openvpn-server-leaf \
  --signed-dir /tmp/server-signed
```

When `sign-request` runs with `--signer-state-dir`, it allocates the next serial automatically and records the issuance under a signer-managed state tree:

```text
<signer-state-dir>/
├── issuances/
│   └── <serial>/
│       ├── issuance.json
│       ├── metadata.json
│       ├── request.json
│       ├── chain.pem
│       └── <role cert and csr files>
├── requests/
│   └── <request-id>.json
├── revocations/
│   └── <serial>.json
└── serials/
    ├── next-serial
    └── allocated/
        └── <serial>.json
```

Repeated signing of the same normalized request bundle reuses the recorded issuance instead of allocating a second serial.

To revoke an issued serial in signer state:

```bash
pd-pki-signing-tools revoke-issued \
  --signer-state-dir /secure/issuer/state/intermediate \
  --serial 2 \
  --reason keyCompromise
```

That updates the issuance, request, and serial records to `status = "revoked"` and writes a matching revocation record under `revocations/`.

Exported request bundles always include `request.json`, the canonical CSR filename for the role, and any role-specific manifest such as `san-manifest.json` or `identity-manifest.json`. Signed bundles contain the issued certificate, `chain.pem`, `metadata.json`, and a copy of the normalized `request.json`.

## Usage

Build the aggregate package:

```bash
nix build .#pd-pki
```

Build a role package:

```bash
nix build .#root-certificate-authority
nix build .#intermediate-signing-authority
nix build .#openvpn-server-leaf
nix build .#openvpn-client-leaf
nix build .#pd-pki-signing-tools
```

Build a single workflow step:

```bash
nix build .#root-certificate-authority-create-root-ca
nix build .#openvpn-server-leaf-package-openvpn-server-deployment-bundle
```

Inspect the machine-readable contract:

```bash
nix eval --json .#define | jq .
nix eval --json .#lib.checkNames | jq .
```

Run all checks:

```bash
nix flake check -L --keep-going
```

Generate a report for the exported checks:

```bash
nix run .#test-report
nix run .#test-report -- --verbose
```

`test-report` writes output to `reports/test-report-<timestamp>/` and produces:

- `report.md`
- `report.json`
- `index.html`
- `style.css`
- `logs/<check-name>.log`

On pushes to the repository default branch, the GitHub Actions workflow publishes the latest generated report directory to GitHub Pages so the HTML report can be viewed directly in a browser.

## Repository Layout

```text
.
├── apps/
├── checks/
├── modules/
├── packages/
├── flake.nix
└── README.md
```

Key files:

- [`flake.nix`](/home/adam/pd-pki/flake.nix) wires together packages, checks, modules, app outputs, and helper lib values
- [`packages/definitions.nix`](/home/adam/pd-pki/packages/definitions.nix) is the source of truth for role and step contracts
- [`packages/pki-workflow-lib.sh`](/home/adam/pd-pki/packages/pki-workflow-lib.sh) contains the OpenSSL helper functions used by the role packages
- [`apps/default.nix`](/home/adam/pd-pki/apps/default.nix) defines the `test-report` app

## Verified Commands

These commands resolve successfully in the repo as of the current state of this README:

- `nix build --no-link --print-out-paths .#root-certificate-authority`
- `nix build --no-link .#root-certificate-authority-create-root-ca`
- `nix build --no-link .#openvpn-server-leaf-package-openvpn-server-deployment-bundle`
- `nix build --no-link .#checks.x86_64-linux.role-topology .#checks.x86_64-linux.pd-pki .#checks.x86_64-linux.nixos-module-default`
- `nix eval --json .#define | jq '.roleCount, .stepCount'`
- `nix run .#test-report -- --help`
