# Root CA Workflow Contracts

## Purpose

This document defines the intended external interfaces for the workflow-first
refactor of `pd-pki`.

The goal is to make the real operator-facing workflows explicit:

1. Provision a root CA YubiKey on an offline appliance
2. Commit the resulting public root inventory into this repository
3. Use the committed root inventory plus the root CA YubiKey to sign an
   intermediate CSR on a separate offline appliance

These contracts are the target surface for future `checks/e2e/*`.

## Design Rules

1. Secrets never enter the repository or the Nix store.
2. Runtime ceremony inputs and outputs travel by removable media.
3. The repository stores only normalized, public root identity inventory.
4. The primary trust anchor is the root CA certificate and public key, not the
   YubiKey serial number.
5. The YubiKey serial remains audit metadata and operator assistance data.

## Workflow Summary

### 1. Root CA YubiKey Provisioning

An offline Raspberry Pi image initializes a dedicated root CA YubiKey and
produces public ceremony artifacts.

Those artifacts are exported to removable media as a provisioning bundle, then
normalized into a committed repository inventory entry.

The intended developer-machine normalization step is:

```bash
pd-pki-signing-tools normalize-root-inventory \
  --source-dir /media/transfer/pd-pki-transfer/root-inventory/root-<root-id>-<timestamp> \
  --inventory-root ./inventory/root-ca
```

### 2. Root CA Intermediate Signing

An offline Raspberry Pi image receives:

1. The committed root inventory from this repository
2. An intermediate request bundle from removable media
3. The inserted root CA YubiKey

Before signing, the appliance verifies that the inserted token presents the
expected root CA identity from the committed inventory.

The appliance then signs the intermediate request bundle and exports the signed
result back to removable media.

## Names And Identifiers

### `root-id`

`root-id` is the normalized SHA-256 fingerprint of the root CA certificate:

1. Compute the root certificate SHA-256 fingerprint
2. Remove colon separators
3. Lowercase the result

Example:

```text
9a2d...ff
```

The repository path for a root inventory entry is:

```text
inventory/root-ca/<root-id>/
```

The root certificate fingerprint, not the YubiKey serial, is the stable
identity key for the workflow.

### Bundle Names

USB bundle directory names are transport identifiers, not trust anchors.

Initial target names:

```text
pd-pki-transfer/root-inventory/root-<root-id>-<timestamp>/
pd-pki-transfer/requests/intermediate-request-<timestamp>/
pd-pki-transfer/signed/intermediate-signed-<timestamp>/
```

## Contract: Repository Root Inventory

This is the normalized, committed, public representation of the root CA
YubiKey.

Path:

```text
inventory/root-ca/<root-id>/
```

Required files:

```text
manifest.json
root-ca.cert.pem
root-ca.pub.verified.pem
root-ca.attestation.cert.pem
root-ca.metadata.json
root-yubikey-init-summary.json
root-key-uri.txt
```

### `manifest.json`

`manifest.json` is the primary machine-readable contract for the inventory
entry.

Target shape:

```json
{
  "schemaVersion": 1,
  "contractKind": "root-ca-inventory",
  "rootId": "<normalized-root-cert-fingerprint>",
  "source": {
    "command": "init-root-yubikey",
    "profileKind": "root-yubikey-initialization"
  },
  "yubiKey": {
    "serial": "<serial>",
    "slot": "<slot>",
    "routineKeyUri": "pkcs11:token=YubiKey%20PIV;id=%02;type=private"
  },
  "certificate": {
    "path": "root-ca.cert.pem",
    "subject": "<openssl-subject>",
    "serial": "<serial>",
    "sha256Fingerprint": "<fingerprint>",
    "notBefore": "<timestamp>",
    "notAfter": "<timestamp>"
  },
  "verifiedPublicKey": {
    "path": "root-ca.pub.verified.pem",
    "sha256": "<file-sha256>"
  },
  "attestation": {
    "path": "root-ca.attestation.cert.pem",
    "sha256Fingerprint": "<fingerprint>"
  },
  "metadata": {
    "path": "root-ca.metadata.json",
    "profile": "root-ca-yubikey-initialized"
  },
  "ceremony": {
    "summaryPath": "root-yubikey-init-summary.json"
  }
}
```

### Semantics

1. `rootId` must equal `certificate.sha256Fingerprint`, normalized for use in a
   path.
2. `certificate.sha256Fingerprint` must match both `root-ca.metadata.json` and
   `root-yubikey-init-summary.json`.
3. `attestation.sha256Fingerprint` must match
   `root-yubikey-init-summary.json.attestation.sha256Fingerprint`.
4. `routineKeyUri` is non-secret inventory data and must not include a PIN.
5. `yubiKey.serial` is audit metadata only. It must not be treated as the
   primary trust anchor.

### Existing Source Mapping

The committed inventory is expected to be normalized from the current
`init-root-yubikey` archive output:

1. `root-ca.cert.pem`
2. `root-ca.pub.verified.pem`
3. `root-ca.attestation.cert.pem`
4. `root-ca.metadata.json`
5. `root-yubikey-init-summary.json`
6. `root-key-uri.txt`

This keeps the repository contract aligned with the current implementation
without committing the entire working directory.

## Contract: Root Inventory USB Export Bundle

This is the removable-media transport bundle produced by the root CA YubiKey
provisioning workflow before normalization into the repository.

Path:

```text
pd-pki-transfer/root-inventory/root-<root-id>-<timestamp>/
```

Required files:

```text
manifest.json
root-ca.cert.pem
root-ca.pub.verified.pem
root-ca.attestation.cert.pem
root-ca.metadata.json
root-yubikey-init-summary.json
root-key-uri.txt
```

The file set intentionally matches the committed inventory contract so the
normalization step is a structural check plus path normalization rather than a
semantic rewrite.

Files that remain outside this bundle:

1. PIN file
2. PUK file
3. Management key file
4. Any temporary PIN source file used during PKCS#11 operations

## Contract: Intermediate Request Bundle

This bundle moves from the intermediate node to the offline root CA signing
appliance by removable media.

Path:

```text
pd-pki-transfer/requests/intermediate-request-<timestamp>/
```

Required files:

```text
request.json
intermediate-ca.csr.pem
```

Optional files:

```text
bundle-digests.sha256
```

### `request.json`

The current intermediate request bundle contract already exists in the runtime
module and `export-request`.

Current required fields:

```json
{
  "schemaVersion": 1,
  "roleId": "intermediate-signing-authority",
  "requestKind": "intermediate-ca",
  "basename": "intermediate-ca",
  "commonName": "<approved-intermediate-common-name>",
  "pathLen": 0,
  "requestedDays": 3650,
  "csrFile": "intermediate-ca.csr.pem"
}
```

### Semantics

1. `requestKind` must be `intermediate-ca`.
2. `csrFile` must point to a CSR file present in the same bundle directory.
3. The CSR subject and CA constraints must match `request.json`.
4. This bundle is runtime ceremony input and should travel by removable media,
   not through the Nix store, for the real workflow.

## Contract: Intermediate Signed Bundle

This bundle moves from the offline root CA signing appliance back to the
intermediate node by removable media.

Path:

```text
pd-pki-transfer/signed/intermediate-signed-<timestamp>/
```

Required files:

```text
request.json
intermediate-ca.cert.pem
chain.pem
metadata.json
```

Optional files:

```text
bundle-digests.sha256
```

### `metadata.json`

The signed bundle uses the existing certificate metadata shape written by
`write_certificate_metadata`.

Current required fields:

```json
{
  "profile": "intermediate-ca-signed",
  "serial": "<issued-serial>",
  "subject": "<openssl-subject>",
  "issuer": "<openssl-issuer>",
  "notBefore": "<timestamp>",
  "notAfter": "<timestamp>",
  "sha256Fingerprint": "<fingerprint>"
}
```

### Semantics

1. `request.json` is copied into the signed bundle to preserve the reviewed
   request context.
2. `chain.pem` must validate `intermediate-ca.cert.pem`.
3. `metadata.json.profile` must be `intermediate-ca-signed`.
4. The intermediate node must reject imports where the runtime CSR does not
   match `intermediate-ca.cert.pem`.

## Contract: Root CA Identity Verification

The signing appliance must verify the inserted token as the root CA YubiKey by
matching committed inventory artifacts, not by serial number alone.

Minimum required checks:

1. The token-exported certificate matches `inventory/root-ca/<root-id>/root-ca.cert.pem`
2. The token-exported public key matches
   `inventory/root-ca/<root-id>/root-ca.pub.verified.pem`
3. The signing certificate fingerprint matches
   `inventory/root-ca/<root-id>/manifest.json.certificate.sha256Fingerprint`
4. If attestation is available for validation at signing time, it matches
   `inventory/root-ca/<root-id>/root-ca.attestation.cert.pem`
5. The observed YubiKey serial matches the committed inventory serial, but only
   as audit metadata

Failure of the certificate or public-key match is a hard stop. Serial mismatch
without a certificate/public-key mismatch is an audit event and policy review
trigger.

## Boundary Between Repo And Runtime

### Safe To Commit

1. Root certificate
2. Root verified public key
3. Attestation certificate
4. Root certificate metadata
5. Root initialization summary
6. PIN-free PKCS#11 URI
7. Normalized inventory manifest

### Must Stay Runtime-Only

1. PIN
2. PUK
3. Management key
4. Intermediate private keys
5. Leaf private keys
6. Temporary PIN files
7. Request or signed bundles that have not yet been normalized into a committed
   contract

## Planned `checks/e2e` Targets

These contracts are intended to drive checks like:

1. `root-yubikey-provisioning-contract`
2. `root-yubikey-inventory-normalization`
3. `root-yubikey-identity-verification`
4. `root-intermediate-request-bundle-contract`
5. `root-intermediate-signed-bundle-contract`
6. `root-intermediate-airgap-handoff`

## Open Questions

The following remain policy or implementation choices:

1. Whether `bundle-digests.sha256` is required or merely recommended for USB
   transport
2. Whether the provisioning bundle should include the full archive or only the
   normalized public subset
3. Whether the signing appliance should consume a single selected root inventory
   entry or a repository tree containing multiple root inventories
4. How strict attestation validation should be on the signing appliance if the
   token certificate and public key already match the committed inventory
