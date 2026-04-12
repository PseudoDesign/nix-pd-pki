# Root CA SOP: Initialize The YubiKey

## Purpose

This SOP defines the procedure for initializing a dedicated YubiKey as the root
CA signing token on an offline NixOS workstation.

It covers:

1. Resetting or confirming a clean PIV application state
2. Setting PIN, PUK, and management controls
3. Generating the root signing key on-token
4. Capturing attestation and public artifacts
5. Creating and storing a self-signed root certificate in the token
6. Exporting the certificate and operational metadata needed by this repo

## Selected Profile

This SOP assumes the following decisions.

1. Token role: root CA signing token only
2. Key origin: generate the root signing key on the YubiKey
3. Slot: `9c` Digital Signature
4. Algorithm: `ECCP384`
5. PIN model: strong local PIN entered by the operator for each signing session
6. Touch policy: `always`
7. Management key: replaced with an `AES256` key handled under dual control
8. PUK: set to a strong break-glass value and kept out of routine operator use
9. PIV metadata: initialize standard metadata objects
10. Certificate handling: keep the root certificate on-token and export a copy
11. Attestation: capture and archive it
12. Backup model: single root token, no equivalent clone
13. Signing control model: single operator for routine signing
14. Host model: offline NixOS root workstation

## Consequences Of This Design

1. The root private key is intended to exist only on this token.
2. Resetting the token after root creation destroys the only signing key unless
   the organization has separately preserved the private key, which this SOP
   does not do.
3. Routine root signing uses the token PIN and touch confirmation only.
4. Administrative actions still require the management key, which remains a
   separate control from the routine signing PIN.

## Required Inputs

Before starting, gather the following.

1. A dedicated YubiKey with PIV support
2. An offline NixOS workstation with physical access control
3. `pcscd` available and working on that workstation
4. The desired root subject string in OpenSSL slash format, for example:
   `/CN=Pseudo Design Root CA`
5. The desired root validity period in days
6. A strong operator PIN, 6 to 8 characters
7. A strong break-glass PUK, 6 to 8 characters
8. A newly generated `AES256` management key, recorded under dual control
9. A local archive location for exported public artifacts and attestation data
10. The runtime destination for the exported root certificate:
    `/var/lib/pd-pki/authorities/root/root-ca.cert.pem`

## Tools

If the workstation does not already have the required tools in `PATH`, open a
temporary shell:

```bash
nix shell \
  nixpkgs#yubikey-manager \
  nixpkgs#yubico-piv-tool \
  nixpkgs#libp11 \
  nixpkgs#openssl \
  nixpkgs#opensc
```

## Security Rules

1. Perform the entire procedure offline.
2. Do not initialize a production root token over remote access.
3. Do not write the PIN, PUK, or full management key to removable media.
4. Do not store the full management key in a normal shell history file.
5. Do not reset an already-issued production root token unless explicit destroy
   and replace authorization has been granted.
6. Preserve exported attestation and certificate artifacts as part of the root
   CA inventory record.

## Procedure

### 1. Prepare The Workstation

Confirm smart-card support is available:

```bash
systemctl is-active pcscd
```

If `pcscd` is not active, start or fix it before continuing.

Create a working directory with restricted permissions:

```bash
umask 077
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
```

Choose the root subject and validity:

```bash
ROOT_SUBJECT='/CN=Pseudo Design Root CA'
ROOT_VALID_DAYS='7300'
```

### 2. Identify The Token

List attached YubiKeys:

```bash
ykman list --serials
```

Set the serial you intend to initialize:

```bash
YK_SERIAL='<serial>'
```

Review the token information:

```bash
ykman --device "$YK_SERIAL" info
ykman --device "$YK_SERIAL" piv info
```

Record at least:

1. Serial number
2. Firmware version
3. That the token is dedicated to the root CA role

### 3. Confirm Clean State Or Reset The PIV Application

If this token is new or explicitly approved for re-initialization, reset the
PIV application:

```bash
ykman --device "$YK_SERIAL" piv reset --force
```

If this is an existing token and you are not explicitly reinitializing it, stop
here and verify its current state instead of resetting it.

Factory-default credentials after reset are:

1. PIN: `123456`
2. PUK: `12345678`
3. Management key:
   `010203040506070801020304050607080102030405060708`

Set a shell variable for the factory-default management key:

```bash
DEFAULT_MGM_KEY='010203040506070801020304050607080102030405060708'
```

### 4. Optionally Set Retry Counters

If local policy requires non-default PIN or PUK retry counts, set them now.

Important:

1. This step resets PIN and PUK back to factory defaults.
2. Perform it before changing the PIN and PUK.

Example:

```bash
ykman --device "$YK_SERIAL" piv access set-retries 5 3 \
  --management-key "$DEFAULT_MGM_KEY" \
  --force
```

If local policy does not require different retry counts, skip this step.

### 5. Change The PIN

Enter the new routine signing PIN:

```bash
read -rsp 'Enter new routine PIN: ' ROOT_PIN
printf '\n'
read -rsp 'Re-enter new routine PIN: ' ROOT_PIN_CONFIRM
printf '\n'
test "$ROOT_PIN" = "$ROOT_PIN_CONFIRM"
unset ROOT_PIN_CONFIRM
```

Apply it:

```bash
ykman --device "$YK_SERIAL" piv access change-pin \
  --pin 123456 \
  --new-pin "$ROOT_PIN"
```

### 6. Change The PUK

Enter the break-glass PUK:

```bash
read -rsp 'Enter new break-glass PUK: ' ROOT_PUK
printf '\n'
read -rsp 'Re-enter new break-glass PUK: ' ROOT_PUK_CONFIRM
printf '\n'
test "$ROOT_PUK" = "$ROOT_PUK_CONFIRM"
unset ROOT_PUK_CONFIRM
```

Apply it:

```bash
ykman --device "$YK_SERIAL" piv access change-puk \
  --puk 12345678 \
  --new-puk "$ROOT_PUK"
```

Notes:

1. Keep the PUK outside routine operator access.
2. Treat PUK use as a break-glass recovery event.

### 7. Replace The Management Key

This SOP assumes the new management key has already been generated and is held
under dual control. Assemble it only long enough to set it on the token.

Enter the new management key:

```bash
read -rsp 'Enter assembled AES256 management key (64 hex chars): ' ROOT_MGM_KEY
printf '\n'
```

Replace the factory-default management key:

```bash
ykman --device "$YK_SERIAL" piv access change-management-key \
  --algorithm aes256 \
  --management-key "$DEFAULT_MGM_KEY" \
  --new-management-key "$ROOT_MGM_KEY" \
  --force
```

Unset the factory-default key variable once it is no longer needed:

```bash
unset DEFAULT_MGM_KEY
```

### 8. Generate The Root Signing Key In Slot 9c

Generate the key pair on-token with the selected controls:

```bash
ykman --device "$YK_SERIAL" piv keys generate 9c "$WORKDIR/root-ca.pub.pem" \
  --management-key "$ROOT_MGM_KEY" \
  --algorithm eccp384 \
  --pin-policy always \
  --touch-policy always
```

This creates the root private key on the token and exports the public key to:

```text
$WORKDIR/root-ca.pub.pem
```

### 9. Capture Key Attestation

Generate and archive the slot attestation certificate:

```bash
ykman --device "$YK_SERIAL" piv keys attest 9c "$WORKDIR/root-ca.attestation.cert.pem"
```

Record the attestation certificate fingerprint:

```bash
openssl x509 -in "$WORKDIR/root-ca.attestation.cert.pem" -noout -fingerprint -sha256
```

### 10. Generate The Root CA Certificate With OpenSSL

Set the PKCS#11 provider locations expected on the NixOS workstation:

```bash
export OPENSSL_MODULES='/run/current-system/sw/lib/ossl-module'
export PKCS11_MODULE_PATH='/run/current-system/sw/lib/libykcs11.so'
```

Write the PIN to a temporary local file for the OpenSSL PKCS#11 URI:

```bash
PIN_FILE="$WORKDIR/root-pin.txt"
printf '%s\n' "$ROOT_PIN" > "$PIN_FILE"
chmod 600 "$PIN_FILE"
ROOT_KEY_URI="pkcs11:token=YubiKey%20PIV;id=%02;type=private;pin-source=file:$PIN_FILE"
```

Write a root CA extension profile:

```bash
cat > "$WORKDIR/root-ca-openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3_root_ca

[ dn ]
CN = placeholder

[ v3_root_ca ]
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
```

Generate the self-signed root CA certificate using the on-token key:

```bash
openssl req -new -x509 \
  -provider default \
  -provider pkcs11prov \
  -key "$ROOT_KEY_URI" \
  -subj "$ROOT_SUBJECT" \
  -days "$ROOT_VALID_DAYS" \
  -sha384 \
  -extensions v3_root_ca \
  -config "$WORKDIR/root-ca-openssl.cnf" \
  -out "$WORKDIR/root-ca.cert.pem"
```

Delete the temporary PIN file immediately afterward:

```bash
rm -f "$PIN_FILE"
unset ROOT_KEY_URI PIN_FILE
```

### 11. Import The Root CA Certificate Into Slot 9c

Import the CA certificate you just created into the token:

```bash
ykman --device "$YK_SERIAL" piv certificates import 9c "$WORKDIR/root-ca.cert.pem" \
  --management-key "$ROOT_MGM_KEY" \
  --pin "$ROOT_PIN" \
  --verify \
  --no-update-chuid
```

### 12. Initialize Standard PIV Metadata

Generate a fresh CHUID:

```bash
ykman --device "$YK_SERIAL" piv objects generate CHUID \
  --management-key "$ROOT_MGM_KEY" \
  --pin "$ROOT_PIN"
```

Generate a fresh CCC:

```bash
ykman --device "$YK_SERIAL" piv objects generate CCC \
  --management-key "$ROOT_MGM_KEY" \
  --pin "$ROOT_PIN"
```

### 13. Export Public Artifacts

Export the certificate from the token and compare it to the locally generated
copy:

```bash
ykman --device "$YK_SERIAL" piv certificates export 9c "$WORKDIR/root-ca.token-export.cert.pem"
cmp -s "$WORKDIR/root-ca.cert.pem" "$WORKDIR/root-ca.token-export.cert.pem"
```

Export the public key again and verify it matches the private key in slot `9c`:

```bash
ykman --device "$YK_SERIAL" piv keys export 9c "$WORKDIR/root-ca.pub.verified.pem" \
  --verify \
  --pin "$ROOT_PIN"
```

Review the exported certificate:

```bash
openssl x509 -in "$WORKDIR/root-ca.cert.pem" -noout -subject -issuer -serial -text
openssl verify -CAfile "$WORKDIR/root-ca.cert.pem" "$WORKDIR/root-ca.cert.pem"
```

Confirm:

1. Subject and issuer are the same
2. The certificate is a CA certificate
3. The public key is `EC` on `secp384r1`
4. The validity period matches the approved root profile

### 14. Record The Operational PKCS#11 URI

For this selected layout, the routine root signing URI is normally:

```text
pkcs11:token=YubiKey%20PIV;id=%02;type=private
```

Record it in the workstation inventory along with:

1. Token serial
2. Slot `9c`
3. Algorithm `ECCP384`
4. PIN policy `always`
5. Touch policy `always`

If your local environment requires a more explicit token URI, derive and record
the serial-qualified URI from:

```bash
pkcs11-tool --module /run/current-system/sw/lib/libykcs11.so --list-objects --type cert
```

### 15. Install The Exported Root Certificate For Repo Use

Install the exported certificate where the repo expects the root certificate to
live at runtime:

```bash
install -D -m 644 \
  "$WORKDIR/root-ca.cert.pem" \
  /var/lib/pd-pki/authorities/root/root-ca.cert.pem
```

Optionally archive the public artifacts under a local inventory directory:

```bash
ARCHIVE_DIR="/var/lib/pd-pki/yubikey-inventory/root-$YK_SERIAL"
install -d -m 700 "$ARCHIVE_DIR"
install -m 644 "$WORKDIR/root-ca.cert.pem" "$ARCHIVE_DIR/root-ca.cert.pem"
install -m 644 "$WORKDIR/root-ca.token-export.cert.pem" "$ARCHIVE_DIR/root-ca.token-export.cert.pem"
install -m 644 "$WORKDIR/root-ca.pub.pem" "$ARCHIVE_DIR/root-ca.pub.pem"
install -m 644 "$WORKDIR/root-ca.pub.verified.pem" "$ARCHIVE_DIR/root-ca.pub.verified.pem"
install -m 644 "$WORKDIR/root-ca.attestation.cert.pem" "$ARCHIVE_DIR/root-ca.attestation.cert.pem"
```

### 16. Final Verification

Run a final review:

```bash
ykman --device "$YK_SERIAL" piv info
ykman --device "$YK_SERIAL" piv keys info 9c
pkcs11-tool --module /run/current-system/sw/lib/libykcs11.so --list-objects --type cert
openssl x509 -in /var/lib/pd-pki/authorities/root/root-ca.cert.pem -noout -subject -serial
```

Confirm:

1. Slot `9c` contains the root certificate
2. The exported certificate matches the intended root subject
3. The token remains physically present and under root-CA custody

### 17. Cleanup

Unset sensitive shell variables:

```bash
unset ROOT_PIN ROOT_PUK ROOT_MGM_KEY
```

Lock the token in its designated storage location when not in use.

## Verification Checklist

Initialization is complete only if all of the following are true.

1. `9c` contains an on-token `ECCP384` key
2. The key was generated on-token, not imported
3. The slot requires PIN entry and touch for signing
4. The self-signed root certificate is present on-token
5. The root certificate has been exported to
   `/var/lib/pd-pki/authorities/root/root-ca.cert.pem`
6. The attestation certificate has been captured and archived
7. CHUID and CCC have been initialized
8. The routine signing URI has been recorded
9. The management key is no longer available to routine operators

## Rollback And Failure Handling

Use the following rules if something goes wrong.

1. If the procedure fails before key generation in `9c`, you may reset the PIV
   application and restart the procedure.
2. If the procedure fails after key generation but before the certificate and
   attestation are archived, stop and decide whether to complete the ceremony or
   formally destroy and reinitialize the token.
3. If the wrong subject, validity period, or slot policy was used, do not
   continue into production use. Escalate for explicit destroy and replace
   approval.
4. If the single root token is reset after acceptance, the root signing key is
   lost. Because this design has no equivalent spare token, replacement becomes
   a root rotation event.

## Result

When this SOP completes successfully:

1. The YubiKey contains the root CA private key in slot `9c`
2. The token enforces PIN and touch for root signing operations
3. The self-signed root certificate is stored on-token and exported locally
4. Public inventory artifacts and attestation data have been archived
5. The token is ready to be used with `pd-pki-signing-tools` through the
   recorded PKCS#11 URI
