# Root CA SOP: Sign The Intermediate CA CSR

## Purpose

This SOP defines the manual, CLI-only procedure for using the offline root CA
to sign the intermediate CA's certificate signing request (CSR), return the
signed bundle to the intermediate node, and preserve the approval and signer
state records created by `pd-pki-signing-tools`.

## Scope

Use this SOP when:

1. The intermediate CA runtime state already contains a valid CSR and
   `signing-request.json`.
2. The root CA is the issuing authority for that intermediate.
3. The signing operation will be performed on an offline root CA workstation.
4. The transfer between nodes will be performed with controlled removable media.

Do not use this SOP for:

1. Leaf certificate issuance.
2. GUI-assisted signing workflows.
3. Root CA key generation or rotation.

## Roles

1. Request Operator: exports the intermediate request bundle from the
   intermediate node and imports the signed bundle afterward.
2. Root CA Operator: reviews the request, signs it on the offline root CA
   machine, and records approval metadata.
3. Approver: authorizes the issuance according to local PKI policy. The Root CA
   Operator and Approver may be the same person only if local policy allows it.

## Required Inputs

Before starting, confirm the following are available.

1. On the intermediate node:
   `/var/lib/pd-pki/authorities/intermediate/intermediate-ca.csr.pem`
   and
   `/var/lib/pd-pki/authorities/intermediate/signing-request.json`
2. On the root CA node:
   `/var/lib/pd-pki/authorities/root/root-ca.cert.pem`
3. On the root CA node:
   `/var/lib/pd-pki/signer-state/root`
4. A signer policy file for root-issued intermediate CA certificates.
   Example location:
   `/secure/policy/root-policy.json`
5. One root signing backend:
   `--issuer-key /path/to/root-ca.key.pem`
   or
   `--issuer-key-uri pkcs11:... --pkcs11-module /path/to/module.so`
6. Controlled removable media dedicated to CA transfer.
7. Operator identity and, if used locally, approval ticket / change record ID.

## Security Rules

1. Keep the root CA workstation offline for the entire procedure.
2. Use only dedicated transfer media for CA operations.
3. Copy only the request bundle and the signed result bundle.
4. Review the request contents before signing. Do not sign based only on the
   filename.
5. If using a token PIN, write it only to a temporary file with mode `0600`,
   delete it immediately after use, and do not store it on removable media.
6. Stop the procedure if the request contents do not match the approved change.

## Procedure

### 1. Export The Intermediate Request Bundle

Run this on the intermediate node:

```bash
mkdir -p /tmp/intermediate-request

pd-pki-signing-tools export-request \
  --role intermediate-signing-authority \
  --state-dir /var/lib/pd-pki/authorities/intermediate \
  --out-dir /tmp/intermediate-request
```

Confirm the bundle contains the expected files:

```bash
find /tmp/intermediate-request -maxdepth 1 -type f | sort
```

Expected minimum contents:

1. `request.json`
2. `intermediate-ca.csr.pem`

Review the request metadata:

```bash
jq . /tmp/intermediate-request/request.json
openssl req -in /tmp/intermediate-request/intermediate-ca.csr.pem -noout -subject -text
```

At minimum, verify:

1. `roleId` is `intermediate-signing-authority`
2. `requestKind` is `intermediate-ca`
3. `commonName` matches the approved intermediate
4. `pathLen` matches the approved constraint
5. The CSR subject and CA constraints match `request.json`

Optionally record the request bundle digest before transfer:

```bash
(cd /tmp/intermediate-request && sha256sum request.json intermediate-ca.csr.pem) \
  > /tmp/intermediate-request.sha256
```

Copy the request bundle to the removable media.

Example:

```bash
mkdir -p /media/transfer/pd-pki-transfer/requests
cp -R /tmp/intermediate-request \
  /media/transfer/pd-pki-transfer/requests/intermediate-request-$(date -u +%Y%m%dT%H%M%SZ)
sync
```

### 2. Transfer The Bundle To The Offline Root CA

1. Unmount and transport the removable media according to local chain-of-custody
   practice.
2. Mount the removable media on the offline root CA machine.
3. Copy the request bundle to a local working directory on the root CA machine.

Example:

```bash
mkdir -p /tmp/root-signing
cp -R /media/transfer/pd-pki-transfer/requests/intermediate-request-* \
  /tmp/root-signing/
```

If a digest file was created, verify it before signing.

### 3. Review And Approve The Request On The Root CA

Set a shell variable for the request directory you are about to sign:

```bash
REQUEST_DIR="$(find /tmp/root-signing -maxdepth 1 -type d -name 'intermediate-request-*' | head -n1)"
```

Review the normalized request and CSR again on the root CA machine:

```bash
jq . "$REQUEST_DIR/request.json"
openssl req -in "$REQUEST_DIR/intermediate-ca.csr.pem" -noout -subject -text
```

Confirm all of the following:

1. The subject is the expected intermediate CA subject.
2. `Basic Constraints` indicate a CA request.
3. The requested `pathLen` is approved.
4. The requested validity is consistent with policy.
5. The request corresponds to the approved change / ticket.

If anything is unexpected, stop and return the request without signing it.

### 4. Sign The Request With The Root CA

Create an output directory on the root CA machine:

```bash
SIGNED_DIR="/tmp/intermediate-signed"
rm -rf "$SIGNED_DIR"
mkdir -p "$SIGNED_DIR"
```

Choose exactly one signing backend.

#### Option A: PEM Root Key

```bash
pd-pki-signing-tools sign-request \
  --request-dir "$REQUEST_DIR" \
  --out-dir "$SIGNED_DIR" \
  --issuer-key /var/lib/pd-pki/authorities/root/root-ca.key.pem \
  --issuer-cert /var/lib/pd-pki/authorities/root/root-ca.cert.pem \
  --signer-state-dir /var/lib/pd-pki/signer-state/root \
  --policy-file /secure/policy/root-policy.json \
  --approved-by operator-root \
  --approval-ticket CHG-1234
```

#### Option B: YubiKey / PKCS#11 Root Key

First, identify the token object if needed:

```bash
pkcs11-tool --module /run/current-system/sw/lib/libykcs11.so --list-objects --type cert
```

Use the certificate object ID to choose the matching private key URI. Then run:

```bash
PIN_FILE="$(mktemp)"
trap 'rm -f "$PIN_FILE"' EXIT
chmod 600 "$PIN_FILE"
printf '%s\n' '<root-token-pin>' > "$PIN_FILE"

pd-pki-signing-tools sign-request \
  --request-dir "$REQUEST_DIR" \
  --out-dir "$SIGNED_DIR" \
  --issuer-key-uri 'pkcs11:token=YubiKey%20PIV;id=%NN;type=private' \
  --pkcs11-module /run/current-system/sw/lib/libykcs11.so \
  --pkcs11-pin-file "$PIN_FILE" \
  --issuer-cert /var/lib/pd-pki/authorities/root/root-ca.cert.pem \
  --signer-state-dir /var/lib/pd-pki/signer-state/root \
  --policy-file /secure/policy/root-policy.json \
  --approved-by operator-root \
  --approval-ticket CHG-1234

rm -f "$PIN_FILE"
```

Notes:

1. Replace `%NN` with the object ID for the root signing key.
2. Replace `/run/current-system/sw/lib/libykcs11.so` if your token module lives
   somewhere else.
3. Keep the PIN file on the local offline machine only.
4. Remove the PIN file immediately after the command returns.

### 5. Verify The Signed Output On The Root CA

Confirm the signed bundle exists:

```bash
find "$SIGNED_DIR" -maxdepth 1 -type f | sort
```

Expected minimum contents:

1. `intermediate-ca.cert.pem`
2. `chain.pem`
3. `metadata.json`
4. `request.json`

Verify the certificate chains to the root bundle that was written to the signed
result:

```bash
openssl verify -CAfile "$SIGNED_DIR/chain.pem" "$SIGNED_DIR/intermediate-ca.cert.pem"
```

Review the resulting certificate:

```bash
openssl x509 -in "$SIGNED_DIR/intermediate-ca.cert.pem" -noout -subject -issuer -serial -text
jq . "$SIGNED_DIR/metadata.json"
```

Confirm:

1. Issuer is the root CA.
2. Subject is the approved intermediate CA.
3. `CA:TRUE` is present.
4. `pathLen` matches the request and policy.
5. Serial number and validity window are acceptable.

Optionally record the output bundle digest:

```bash
(cd "$SIGNED_DIR" && sha256sum request.json metadata.json intermediate-ca.cert.pem chain.pem) \
  > /tmp/intermediate-signed.sha256
```

### 6. Return The Signed Bundle To The Intermediate Node

Copy the signed bundle to the removable media:

```bash
mkdir -p /media/transfer/pd-pki-transfer/signed
cp -R "$SIGNED_DIR" \
  /media/transfer/pd-pki-transfer/signed/intermediate-signed-$(date -u +%Y%m%dT%H%M%SZ)
sync
```

Unmount and transport the removable media back to the intermediate node.

### 7. Import The Signed Bundle On The Intermediate Node

Set the signed bundle path:

```bash
SIGNED_IMPORT_DIR="$(find /media/transfer/pd-pki-transfer/signed -maxdepth 1 -type d -name 'intermediate-signed-*' | head -n1)"
```

Import it into runtime state:

```bash
pd-pki-signing-tools import-signed \
  --role intermediate-signing-authority \
  --state-dir /var/lib/pd-pki/authorities/intermediate \
  --signed-dir "$SIGNED_IMPORT_DIR"
```

Verify the imported runtime artifacts:

```bash
test -f /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem
test -f /var/lib/pd-pki/authorities/intermediate/chain.pem
test -f /var/lib/pd-pki/authorities/intermediate/signer-metadata.json
openssl verify \
  -CAfile /var/lib/pd-pki/authorities/intermediate/chain.pem \
  /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem
```

## Records To Keep

Record the following in the local issuance record, ticket, or change log:

1. Date and time of signing
2. Request Operator
3. Root CA Operator
4. Approval ticket or change record ID
5. Common name of the intermediate CA
6. Signed certificate serial number
7. Request and signed-bundle digests, if recorded
8. Removable media identifier, if tracked locally

## Failure Conditions

Stop and escalate if any of the following occur:

1. `request.json` and the CSR do not describe the same subject or CA settings
2. The request does not match the approved common name or `pathLen`
3. `pd-pki-signing-tools sign-request` reports a policy violation
4. The issuer certificate does not match the configured root signing key
5. The signed certificate fails `openssl verify`
6. The removable media contains unexpected extra material or appears tampered

## Result

When this SOP completes successfully:

1. The root signer state contains an issuance record for the intermediate CA.
2. The signed intermediate certificate bundle has been returned through
   controlled removable media.
3. The intermediate node has imported the signed certificate and chain into its
   runtime state.
