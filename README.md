# pd-pki

Nix-based PKI workflow toolkit for Pseudo Design.

`pd-pki` publishes deterministic, machine-readable PKI workflow outputs for four certificate roles, provides NixOS modules for managing mutable runtime artifacts, and ships signer tooling for external issuance, import, revocation, and CRL generation.

## Overview

- 4 roles are implemented: root CA, intermediate signing authority, OpenVPN server leaf, and OpenVPN client leaf
- 19 workflow steps are modeled and exported as buildable flake packages
- 32 named checks are exported from the flake
- role packages emit public PEM and JSON artifacts plus per-step metadata and status files
- NixOS modules expose each role under `services.pd-pki.roles.*`; they manage mutable runtime artifacts under `/var/lib/pd-pki`, validate imported certificates, chains, CRLs, and metadata before staging them, reconcile imported artifacts on a timer, can consume provisioned inputs either from direct file paths or systemd credentials, and do not bootstrap a CA hierarchy on deployment nodes
- `pd-pki-signing-tools` exports signer request bundles, signs them with an external issuer, imports signed artifacts back into runtime state, enforces signer-side issuance policy down to the CSR key algorithm and RSA bit length, persists signer-side issuance state with automatic serial allocation under a lock, records approval and revocation attribution, and can generate CRLs from recorded revocations
- `pd-pki-operator` provides an interactive terminal TUI for USB-guided request export, offline signing, signed-bundle import, and CRL handoff
- a `test-report` app runs all exported checks and writes Markdown and JSON reports

## Repository Model

`pd-pki` models PKI workflows as deterministic Nix derivations built with `openssl` and `jq`.

Each role package produces:

- `role.json` with role metadata
- `steps.json` with the ordered workflow definition
- `steps/<step-id>/define.json` with the step contract
- `steps/<step-id>/checks.json` with declared validations
- `steps/<step-id>/status.json` with the implementation summary
- `steps/<step-id>/artifacts/...` with representative public PEM and JSON outputs

The aggregate `pd-pki` package is a link farm that exposes the four role packages together.

When a role module is enabled, deployment nodes keep mutable runtime artifacts under `/var/lib/pd-pki/...`, emit signer-facing JSON request metadata, accept either a managed private key or an externally generated CSR for request material, and expect certificates and chains to be staged from an external signing workflow.

## Operational Boundaries

This repository covers workflow definition, runtime artifact management, and signer-state handling. It expects some operational concerns to be provided by the surrounding environment:

- runtime roles expect request and import material to be provisioned from outside the module: direct file-path inputs remain available through `*SourcePath` options, the same artifacts can be scoped to the pd-pki units through `*CredentialPath` options, and roles can wait for external provisioners through `provisioningUnits`. Deployments that keep keys in another secret system or behind hardware-backed custody can provide `csrSourcePath` or `csrCredentialPath` and let pd-pki manage the CSR, certificate, chain, and CRL lifecycle around that external key
- hardware-backed root and intermediate custody are external to this repository
- signer-side and runtime CRL flows are included; OCSP responders and CRL distribution services remain external
- derivation outputs use fixed reference inputs so package builds stay deterministic
- role packages publish deterministic reference artifacts and workflow contracts rather than live CA state from an offline or HSM-backed signing environment

## Implemented Roles

### Root Certificate Authority

Implements 5 steps:

- `create-root-ca`
- `rotate-root-ca`
- `sign-intermediate-ca-certificate`
- `revoke-intermediate-ca-certificate`
- `publish-root-trust-artifacts`

This package creates a deterministic reference root CA, simulates root rotation, signs a representative intermediate CA, records revocation metadata for that intermediate, and publishes a root trust bundle.

### Intermediate Signing Authority

Implements 6 steps:

- `create-intermediate-ca`
- `rotate-intermediate-ca`
- `sign-openvpn-server-leaf-certificate`
- `sign-openvpn-client-leaf-certificate`
- `revoke-leaf-certificate`
- `publish-intermediate-trust-artifacts`

This package creates and rotates an intermediate CA signed by the reference root, signs representative OpenVPN server and client certificates, records leaf revocation metadata, and publishes an intermediate trust bundle.

### OpenVPN Server Leaf

Implements 4 steps:

- `create-openvpn-server-leaf-request`
- `package-openvpn-server-deployment-bundle`
- `rotate-openvpn-server-certificate`
- `consume-server-trust-updates`

This package generates a reference server CSR, signs and packages a public deployment bundle, creates a rotated server certificate, and stages trust updates for server-side validation. Runtime server keys live under `/var/lib/pd-pki/openvpn-server-leaf`.

### OpenVPN Client Leaf

Implements 4 steps:

- `create-openvpn-client-leaf-request`
- `package-openvpn-client-credential-bundle`
- `rotate-openvpn-client-certificate`
- `consume-client-trust-updates`

This package generates a reference client CSR, signs and packages a public client credential bundle, creates a rotated client certificate, and stages trust updates for client-side validation. Runtime client keys live under `/var/lib/pd-pki/openvpn-client-leaf`.

## Flake Outputs

The flake exports the following top-level outputs:

- `packages`
  - `pd-pki`
  - `pd-pki-signing-tools`
  - `pd-pki-operator`
  - one package per role
  - one package per workflow step, named `<role-id>-<step-id>`
- `checks`
  - aggregate package check
  - role and step checks
  - NixOS module checks
  - `module-runtime-artifacts` check
  - `openvpn-daemon` check
  - `role-topology` check
- `nixosModules`
  - `default`
  - `root-certificate-authority`
  - `intermediate-signing-authority`
  - `openvpn-server-leaf`
  - `openvpn-client-leaf`
- `apps.test-report`
- `apps.pd-pki-operator`
- `lib`
  - `definitions`
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

Artifact types include:

- self-signed and issued X.509 certificates
- CSRs
- certificate chains
- CRLs
- deployment and credential bundles
- trust bundle directories
- JSON manifests, issuance metadata, revocation records, and publication metadata

## Validation

Checks in [`checks/`](/home/adam/pd-pki/checks) cover:

- aggregate package wiring
- role and step artifact presence
- JSON parsing for declared metadata files
- X.509 and CSR parsing
- chain verification
- CA basic constraints
- server and client extended key usage validation
- SAN presence checks
- NixOS module evaluation
- Linux-only verification that runtime modules generate only their local mutable artifacts, export signer request bundles, complete a root-to-intermediate-to-leaf signing roundtrip, validate and stage imported certificates and metadata atomically without bootstrapping a CA chain, reconcile staged imports automatically on a timer, trigger configured consumer reload hooks only when runtime artifacts actually change, reject bad imports without clobbering the last good runtime state, generate and stage CRLs, and enforce revocation with `openssl verify -crl_check`
- Linux-only OpenVPN daemon verification that boots real `openvpn-server` and `openvpn-client` services, confirms mTLS tunnel establishment with staged runtime artifacts, verifies tunnel connectivity in both directions, and proves a revoked client certificate is rejected after CRL refresh

The Linux-only [`role-topology` check](/home/adam/pd-pki/checks/nixos-role-topology.nix) adds a multi-node NixOS test on top of the direct derivation-based role and step checks exported on every supported system. The Linux-only [`openvpn-daemon` check](/home/adam/pd-pki/checks/openvpn-daemon.nix) exercises the OpenVPN server and client daemons directly against staged signer outputs and CRL updates.

## NixOS Modules

Each role has a NixOS module built from [`modules/mk-role-module.nix`](/home/adam/pd-pki/modules/mk-role-module.nix). Enabling a role module:

- exposes the role package under `/etc/pd-pki/<role-id>` by default
- can add the role package to `environment.systemPackages`
- exposes read-only `definition` and `stepIds` values derived from the workflow contract

Each role module follows a single runtime model:

- `services.pd-pki.roles.rootCertificateAuthority` stages operator-provided root key, CSR, certificate, optional CRL, and optional metadata into mutable runtime paths.
- `services.pd-pki.roles.intermediateSigningAuthority` writes `signing-request.json`, then either derives a CSR from an operator-provided key via `keySourcePath` or `keyCredentialPath`, stages an externally generated CSR via `csrSourcePath` or `csrCredentialPath`, or reuses an already-seeded runtime key/CSR, and finally stages an imported intermediate certificate, chain, optional CRL, and optional metadata.
- `services.pd-pki.roles.openvpnServerLeaf` writes `issuance-request.json` plus `san-manifest.json`, then either derives a CSR from an operator-provided key via `keySourcePath` or `keyCredentialPath`, stages an externally generated CSR via `csrSourcePath` or `csrCredentialPath`, or reuses an already-seeded runtime key/CSR, and finally stages an imported server certificate, chain, issuer CRL, and optional metadata.
- `services.pd-pki.roles.openvpnClientLeaf` writes `issuance-request.json` plus `identity-manifest.json`, then either derives a CSR from an operator-provided key via `keySourcePath` or `keyCredentialPath`, stages an externally generated CSR via `csrSourcePath` or `csrCredentialPath`, or reuses an already-seeded runtime key/CSR, and finally stages an imported client certificate, chain, issuer CRL, and optional metadata.

Imported runtime artifacts are validated before they replace the live files. The modules reject certificate/key or certificate/CSR mismatches, broken chains, wrong EKUs or SANs for leaf roles, CA/profile mismatches for intermediate roles, invalid CRLs, expired CRLs, and metadata that does not match the staged certificate. Updated imports are written through a staging directory first so failed validation leaves the existing runtime state untouched.

Provisioned inputs can be supplied as plain file paths through `*SourcePath` options or loaded into the pd-pki units as systemd credentials through `*CredentialPath` options. `provisioningUnits` lets a role start and wait for external provisioners such as Vault agents, secret sync jobs, or CSR exporters before it validates anything.

If a role has source paths or credential paths configured, it also enables a periodic refresh timer. The timer re-runs validation and staging automatically, and roles can optionally reload or restart dependent systemd units through `reloadUnits` and `reloadMode` when the staged runtime artifacts actually change.

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
    refreshInterval = "5m";
    provisioningUnits = [ "vault-agent.service" ];
    reloadUnits = [ "openvpn-server.service" ];
    keyCredentialPath = "/run/secrets/openvpn/server.key.pem";
    certificateSourcePath = "/var/lib/pd-pki/imports/server.cert.pem";
    chainSourcePath = "/var/lib/pd-pki/imports/server.chain.pem";
    crlSourcePath = "/var/lib/pd-pki/imports/intermediate.crl.pem";
  };

  services.pd-pki.roles.openvpnClientLeaf = {
    enable = true;
    csrSourcePath = "/run/secrets/openvpn/client.csr.pem";
    certificateSourcePath = "/var/lib/pd-pki/imports/client.cert.pem";
    chainSourcePath = "/var/lib/pd-pki/imports/client.chain.pem";
    crlSourcePath = "/var/lib/pd-pki/imports/intermediate.crl.pem";
  };
}
```

## External Signer Workflow

The repository ships a small operator CLI as the `pd-pki-signing-tools` package. It turns the runtime artifacts emitted by the NixOS modules into portable request bundles, signs those bundles with an external issuer, and imports the signed results back into the mutable runtime paths.

For manual, CLI-only root procedures, see:

- [`docs/sops/ROOT_CA_INTERMEDIATE_SIGNING_SOP.md`](docs/sops/ROOT_CA_INTERMEDIATE_SIGNING_SOP.md)
- [`docs/sops/ROOT_CA_YUBIKEY_INITIALIZATION_SOP.md`](docs/sops/ROOT_CA_YUBIKEY_INITIALIZATION_SOP.md)

Build it with:

```bash
nix build .#pd-pki-signing-tools
nix build .#pd-pki-operator
```

A typical request, signing, and import flow looks like this:

1. On the request-generating node, export a signer bundle:

```bash
pd-pki-signing-tools export-request \
  --role openvpn-server-leaf \
  --state-dir /var/lib/pd-pki/openvpn-server-leaf \
  --out-dir /tmp/server-request
```

2. On the signer, sign the bundle with the issuing CA key and certificate plus an explicit signer policy and approval attribution:

```bash
pd-pki-signing-tools sign-request \
  --request-dir /tmp/server-request \
  --out-dir /tmp/server-signed \
  --issuer-key /secure/issuer/intermediate-ca.key.pem \
  --issuer-cert /secure/issuer/intermediate-ca.cert.pem \
  --issuer-chain /secure/issuer/chain.pem \
  --signer-state-dir /secure/issuer/state/intermediate \
  --policy-file /secure/issuer/policy/intermediate.json \
  --approved-by operator-vpn
```

For a YubiKey or other PKCS#11-backed issuer key, use a `pkcs11:` URI plus the module path instead of `--issuer-key`:

```bash
pd-pki-signing-tools sign-request \
  --request-dir /tmp/server-request \
  --out-dir /tmp/server-signed \
  --issuer-key-uri 'pkcs11:token=YubiKey%20PIV;id=%02;type=private' \
  --pkcs11-module /run/current-system/sw/lib/libykcs11.so \
  --pkcs11-pin-file /secure/issuer/pin.txt \
  --issuer-cert /secure/issuer/intermediate-ca.cert.pem \
  --issuer-chain /secure/issuer/chain.pem \
  --signer-state-dir /secure/issuer/state/intermediate \
  --policy-file /secure/issuer/policy/intermediate.json \
  --approved-by operator-vpn
```

3. Back on the request node, import the signed bundle into runtime state:

```bash
pd-pki-signing-tools import-signed \
  --role openvpn-server-leaf \
  --state-dir /var/lib/pd-pki/openvpn-server-leaf \
  --signed-dir /tmp/server-signed
```

The request-export step works the same way whether the node prepared its CSR from a staged PEM key via `keySourcePath` or `keyCredentialPath`, or received the CSR directly via `csrSourcePath` or `csrCredentialPath`.

When `sign-request` runs with `--signer-state-dir`, it requires `--policy-file`, acquires an advisory lock for the signer state, allocates the next serial automatically, and records the issuance under a signer-managed state tree:

```text
<signer-state-dir>/
├── audit/
│   └── <timestamp>-<event>-<serial-or-request>.json
├── crls/
│   ├── current.pem
│   ├── metadata.json
│   └── next-crl-number
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

Repeated signing of the same normalized request bundle reuses the recorded issued bundle instead of allocating a second serial. If that issuance has been revoked, `sign-request` refuses to reuse it and requires a new CSR.

A minimal signer policy looks like this:

```json
{
  "schemaVersion": 1,
  "roles": {
    "openvpn-server-leaf": {
      "defaultDays": 825,
      "maxDays": 825,
      "allowedKeyAlgorithms": ["RSA"],
      "minimumRsaBits": 3072,
      "allowedProfiles": ["serverAuth"],
      "crlDistributionPoints": [
        "https://pki.example.test/intermediate.crl"
      ],
      "commonNamePatterns": ["^[A-Za-z0-9.-]+$"],
      "subjectAltNamePatterns": [
        "^DNS:[A-Za-z0-9.-]+$",
        "^IP:(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$"
      ]
    },
    "openvpn-client-leaf": {
      "defaultDays": 825,
      "maxDays": 825,
      "allowedKeyAlgorithms": ["RSA"],
      "minimumRsaBits": 3072,
      "allowedProfiles": ["clientAuth"],
      "crlDistributionPoints": [
        "https://pki.example.test/intermediate.crl"
      ],
      "commonNamePatterns": ["^[A-Za-z0-9.-]+$"],
      "subjectAltNamePatterns": ["^DNS:[A-Za-z0-9.-]+$"]
    }
  }
}
```

For intermediate CA requests, the same policy format can constrain `defaultDays`, `maxDays`, `commonNamePatterns`, `allowedPathLens`, `allowedKeyAlgorithms`, `minimumRsaBits`, and `crlDistributionPoints`.

To revoke an issued serial in signer state:

```bash
pd-pki-signing-tools revoke-issued \
  --signer-state-dir /secure/issuer/state/intermediate \
  --serial 2 \
  --reason keyCompromise \
  --revoked-by operator-security
```

That updates the issuance, request, and serial records to `status = "revoked"`, records the revocation actor and optional ticket metadata, and writes a matching revocation record under `revocations/`.

To generate a CRL from the recorded signer state:

```bash
pd-pki-signing-tools generate-crl \
  --signer-state-dir /secure/issuer/state/intermediate \
  --issuer-key /secure/issuer/intermediate-ca.key.pem \
  --issuer-cert /secure/issuer/intermediate-ca.cert.pem \
  --out-dir /tmp/intermediate-crl \
  --days 30
```

The same PKCS#11 options are available for CRL generation:

```bash
pd-pki-signing-tools generate-crl \
  --signer-state-dir /secure/issuer/state/intermediate \
  --issuer-key-uri 'pkcs11:token=YubiKey%20PIV;id=%02;type=private' \
  --pkcs11-module /run/current-system/sw/lib/libykcs11.so \
  --pkcs11-pin-file /secure/issuer/pin.txt \
  --issuer-cert /secure/issuer/intermediate-ca.cert.pem \
  --out-dir /tmp/intermediate-crl \
  --days 30
```

That writes `crl.pem` and `metadata.json` into `--out-dir`, updates `<signer-state-dir>/crls/`, and lets deployment nodes stage the resulting CRL through `crlSourcePath`.

Exported request bundles always include `request.json`, the canonical CSR filename for the role, and any role-specific manifest such as `san-manifest.json` or `identity-manifest.json`. Signed bundles contain the issued certificate, `chain.pem`, `metadata.json`, and a copy of the normalized `request.json`.

## Interactive Operator Wizard

The repository also ships an interactive terminal TUI as the `pd-pki-operator` package and flake app. It wraps the existing `pd-pki-signing-tools` commands with an operator-guided flow for removable-media handoff:

- export request bundles to a mounted USB volume
- sign request bundles from a mounted USB volume and copy the signed result back to that volume
- import signed bundles from a mounted USB volume into runtime state
- generate CRLs and copy them to a mounted USB volume

Run it with:

```bash
nix run .#pd-pki-operator
```

The current wizard supports both file-backed and token-backed signing flows:

- in an interactive terminal it uses a full-screen `dialog` interface and live wait screens that refresh while USB media or a YubiKey is being inserted
- operators can choose either a PEM issuer key path or a YubiKey / PKCS#11 signer backend for request signing and CRL generation
- the PKCS#11 flow defaults to YubiKey PIV's `libykcs11.so`, can discover token certificate objects with `pkcs11-tool`, and always offers manual URI entry as a fallback
- the wizard still prompts for a local issuer certificate and optional chain path so it can verify returned certificates and assemble bundles
- removable-volume auto-detection uses `lsblk` when available and always offers a manual mounted-path fallback
- `PD_PKI_OPERATOR_PLAIN=1` forces the original line-oriented prompt mode when desired

The wizard writes transfer material beneath `pd-pki-transfer/` on the selected removable volume so request, signed, and CRL bundles stay grouped cleanly during air-gapped handoff.

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
nix build .#pd-pki-operator
```

Build a single workflow step:

```bash
nix build .#root-certificate-authority-create-root-ca
nix build .#openvpn-server-leaf-package-openvpn-server-deployment-bundle
```

Inspect the machine-readable contract:

```bash
nix eval --json .#lib.definitions | jq .
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
nix run .#pd-pki-operator -- --help
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
- [`packages/pki-workflow-lib.sh`](/home/adam/pd-pki/packages/pki-workflow-lib.sh) contains the OpenSSL helper functions used by the role packages and runtime module validation scripts
- [`packages/pd-pki-signing-tools.nix`](/home/adam/pd-pki/packages/pd-pki-signing-tools.nix) defines the external signer, signer-state, and CRL tooling
- [`packages/pd-pki-operator.nix`](/home/adam/pd-pki/packages/pd-pki-operator.nix) defines the interactive removable-media operator wizard
- [`apps/default.nix`](/home/adam/pd-pki/apps/default.nix) defines the `test-report` and `pd-pki-operator` apps

## Verified Commands

These commands resolve successfully in the repository:

- `nix build --no-link --print-out-paths .#root-certificate-authority`
- `nix build --no-link .#root-certificate-authority-create-root-ca`
- `nix build --no-link .#openvpn-server-leaf-package-openvpn-server-deployment-bundle`
- `nix build --no-link .#checks.x86_64-linux.role-topology .#checks.x86_64-linux.openvpn-daemon .#checks.x86_64-linux.pd-pki .#checks.x86_64-linux.nixos-module-default`
- `nix eval --json .#lib.definitions | jq '.roleCount, .stepCount'`
- `nix run .#test-report -- --help`
- `nix run .#pd-pki-operator -- --help`
