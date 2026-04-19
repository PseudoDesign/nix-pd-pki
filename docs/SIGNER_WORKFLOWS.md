# Signing Workflows

This guide collects the longer operational flows that used to live in the main
README:

- request export, signing, and signed-bundle import
- root inventory export and normalization
- root YubiKey identity verification
- revocation and CRL generation
- the interactive removable-media operator wizard

## Build The Tools

```bash
nix build .#pd-pki-signing-tools
nix build .#pd-pki-operator
```

## Root Signer Procedures

For root signer procedures, see:

- [docs/sops/ROOT_CA_INTERMEDIATE_SIGNING_SOP.md](sops/ROOT_CA_INTERMEDIATE_SIGNING_SOP.md)
- [docs/sops/ROOT_CA_YUBIKEY_INITIALIZATION_SOP.md](sops/ROOT_CA_YUBIKEY_INITIALIZATION_SOP.md)
- [docs/sops/ROOT_CA_YUBIKEY_INITIALIZATION_MANUAL_SOP.md](sops/ROOT_CA_YUBIKEY_INITIALIZATION_MANUAL_SOP.md)

For root token provisioning from the exported root profile,
`pd-pki-signing-tools init-root-yubikey` can consume
`/etc/pd-pki/root-yubikey-init-profile.json`; use `--dry-run` first to review
the generated plan and OpenSSL config before touching hardware, then reuse the
same `--work-dir` for apply so the reviewed plan remains the ceremony record.
Use `--force-reset` for destroy-and-replace ceremonies, or omit it only when a
factory-fresh token should fail rather than reset if it already contains PIV
state.

## Root Inventory Export And Normalization

After a root ceremony, `pd-pki-signing-tools export-root-inventory` can turn
the archived public artifacts into the removable-media root inventory bundle:

```bash
pd-pki-signing-tools export-root-inventory \
  --source-dir /var/lib/pd-pki/yubikey-inventory/root-<serial> \
  --out-dir /media/transfer/pd-pki-transfer/root-inventory/root-<root-id>-<timestamp>
```

On the development machine,
`pd-pki-signing-tools normalize-root-inventory` can then normalize that public
bundle into the committed repository contract under `inventory/root-ca/<root-id>/`:

```bash
pd-pki-signing-tools normalize-root-inventory \
  --source-dir /media/transfer/pd-pki-transfer/root-inventory/root-<root-id>-<timestamp> \
  --inventory-root ./inventory/root-ca
```

From the repository root, the helper script can automate that mounted-media
workflow, print root certificate metadata, and stage the resulting inventory
directory in git:

```bash
nix run .#pd-pki-normalize-root-inventory-from-mount -- ./mnt
```

To also print the copied file list and git status, add `-v`:

```bash
nix run .#pd-pki-normalize-root-inventory-from-mount -- -v ./mnt
```

On the signing appliance, `pd-pki-signing-tools verify-root-yubikey-identity`
can verify that the inserted token presents the committed root CA identity
before an intermediate signing ceremony begins:

```bash
pd-pki-signing-tools verify-root-yubikey-identity \
  --inventory-dir /var/lib/pd-pki/inventory/root-ca/<root-id> \
  --yubikey-serial <serial> \
  --pin-file /var/lib/pd-pki/secrets/root-pin.txt \
  --work-dir /var/lib/pd-pki/verify-root-yubikey
```

The resulting `root-yubikey-identity-summary.json` records whether the inserted
token's certificate and verified public key match the committed inventory.
Serial mismatches are reported for audit purposes, but they are not the primary
trust check.

## Request, Signing, And Import Flow

A typical request, signing, and import flow looks like this:

1. On the request-generating node, export a signer bundle:

```bash
pd-pki-signing-tools export-request \
  --role openvpn-server-leaf \
  --state-dir /var/lib/pd-pki/openvpn-server-leaf \
  --out-dir /tmp/server-request
```

2. On the signer, sign the bundle with the issuing CA key and certificate plus
an explicit signer policy and approval attribution:

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

For a YubiKey or other PKCS#11-backed issuer key, use the token-reported
`pkcs11:` private-key URI plus the module path instead of `--issuer-key`:

```bash
pd-pki-signing-tools sign-request \
  --request-dir /tmp/server-request \
  --out-dir /tmp/server-signed \
  --issuer-key-uri "$(cat /secure/issuer/key-uri.txt)" \
  --pkcs11-module /run/current-system/sw/lib/libykcs11.so \
  --pkcs11-pin-file /secure/issuer/pin.txt \
  --issuer-cert /secure/issuer/intermediate-ca.cert.pem \
  --issuer-chain /secure/issuer/chain.pem \
  --signer-state-dir /secure/issuer/state/intermediate \
  --policy-file /secure/issuer/policy/intermediate.json \
  --approved-by operator-vpn
```

You can capture that URI once with:

```bash
pkcs11-tool --module /run/current-system/sw/lib/libykcs11.so --login --pin '<issuer-pin>' --list-objects --type privkey
```

3. Back on the request node, import the signed bundle into runtime state:

```bash
pd-pki-signing-tools import-signed \
  --role openvpn-server-leaf \
  --state-dir /var/lib/pd-pki/openvpn-server-leaf \
  --signed-dir /tmp/server-signed
```

The request-export step works the same way whether the node prepared its CSR
from a staged PEM key via `keySourcePath` or `keyCredentialPath`, or received
the CSR directly via `csrSourcePath` or `csrCredentialPath`.

## Signer State

When `sign-request` runs with `--signer-state-dir`, it requires
`--policy-file`, acquires an advisory lock for the signer state, allocates the
next serial automatically, and records the issuance under a signer-managed
state tree:

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

Repeated signing of the same normalized request bundle reuses the recorded
issued bundle instead of allocating a second serial. If that issuance has been
revoked, `sign-request` refuses to reuse it and requires a new CSR.

## Minimal Signer Policy

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

For intermediate CA requests, the same policy format can constrain
`defaultDays`, `maxDays`, `commonNamePatterns`, `allowedPathLens`,
`allowedKeyAlgorithms`, `minimumRsaBits`, and `crlDistributionPoints`.

## Revocation And CRL Generation

To revoke an issued serial in signer state:

```bash
pd-pki-signing-tools revoke-issued \
  --signer-state-dir /secure/issuer/state/intermediate \
  --serial 2 \
  --reason keyCompromise \
  --revoked-by operator-security
```

That updates the issuance, request, and serial records to `status = "revoked"`,
records the revocation actor and optional ticket metadata, and writes a matching
revocation record under `revocations/`.

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
  --issuer-key-uri "$(cat /secure/issuer/key-uri.txt)" \
  --pkcs11-module /run/current-system/sw/lib/libykcs11.so \
  --pkcs11-pin-file /secure/issuer/pin.txt \
  --issuer-cert /secure/issuer/intermediate-ca.cert.pem \
  --out-dir /tmp/intermediate-crl \
  --days 30
```

That writes `crl.pem` and `metadata.json` into `--out-dir`, updates
`<signer-state-dir>/crls/`, and lets deployment nodes stage the resulting CRL
through `crlSourcePath`.

Exported request bundles always include `request.json`, the canonical CSR
filename for the role, and any role-specific manifest such as
`san-manifest.json` or `identity-manifest.json`. Signed bundles contain the
issued certificate, `chain.pem`, `metadata.json`, and a copy of the normalized
`request.json`.

## Interactive Operator Wizard

The repository also ships an interactive terminal TUI as the `pd-pki-operator`
package and flake app. It wraps the existing `pd-pki-signing-tools` commands
with an operator-guided flow for removable-media handoff:

- export root inventory bundles to a mounted USB volume
- export request bundles to a mounted USB volume
- sign request bundles from a mounted USB volume and copy the signed result
  back to that volume
- import signed bundles from a mounted USB volume into runtime state
- generate CRLs and copy them to a mounted USB volume

Run it with:

```bash
nix run .#pd-pki-operator
```

The current wizard supports both file-backed and token-backed signing flows:

- in an interactive terminal it uses a full-screen `dialog` interface and live
  wait screens that refresh while USB media or a YubiKey is being inserted
- operators can choose either a PEM issuer key path or a YubiKey / PKCS#11
  signer backend for request signing and CRL generation
- when signing an intermediate request with the root PKCS#11 profile, the
  wizard requires committed root inventory selection and runs
  `verify-root-yubikey-identity` before signing continues
- the PKCS#11 flow defaults to YubiKey PIV's `libykcs11.so`, can discover token
  certificate objects with `pkcs11-tool`, and always offers manual URI entry as
  a fallback
- the wizard still prompts for a local issuer certificate and optional chain
  path so it can verify returned certificates and assemble bundles
- removable-volume auto-detection uses `lsblk` when available and always offers
  a manual mounted-path fallback
- `PD_PKI_OPERATOR_PLAIN=1` forces the original line-oriented prompt mode when
  desired

The wizard writes transfer material beneath `pd-pki-transfer/` on the selected
removable volume so root inventory, request, signed, and CRL bundles stay
grouped cleanly during air-gapped handoff.
