# Root CA SOP: Initialize The YubiKey

## Purpose

This SOP defines the preferred reset-based procedure for initializing a
dedicated YubiKey as the root CA signing token on an offline NixOS workstation.

It uses the declarative root profile exported by the NixOS module and the
`pd-pki-signing-tools init-root-yubikey` command to perform the mechanical
token setup steps consistently.

For manual recovery or investigation, see
[`ROOT_CA_YUBIKEY_INITIALIZATION_MANUAL_SOP.md`](ROOT_CA_YUBIKEY_INITIALIZATION_MANUAL_SOP.md).

## Scope

This procedure is intentionally destructive-reset based.

Use it only when all of the following are true:

1. The token is new, blank, or explicitly approved for destroy-and-replace
2. The workstation is offline and under physical access control
3. The exported root initialization profile has been reviewed and approved
4. The operator has the PIN, PUK, and management key files required for the
   ceremony

Do not use this SOP to inspect or preserve an already-issued production root
token. Use the manual fallback SOP for those cases.

## Required Inputs

Before starting, gather the following.

1. A dedicated YubiKey with PIV support
2. An offline NixOS workstation where `ykman list --serials` can detect the
   token
3. `pd-pki-signing-tools` available in `PATH`, or a temporary shell that
   provides it
4. The root initialization profile, normally:
   `/etc/pd-pki/root-yubikey-init-profile.json`
5. The YubiKey serial number to initialize
6. A local working directory on encrypted or otherwise controlled storage
7. A file containing the routine PIN as a single trimmed line
8. A file containing the break-glass PUK as a single trimmed line
9. A file containing the `AES256` management key as 64 hexadecimal characters
10. Optional approved retry counts for PIN and PUK, if policy requires them

## Security Rules

1. Perform the entire procedure offline.
2. Do not initialize a production root token over remote access.
3. Do not place the PIN, PUK, or full management key in shell history.
4. Do not point the secret files at removable media that will leave controlled
   custody.
5. Treat `--force-reset` as destroy-and-replace authorization, not as a routine
   convenience flag.
6. Preserve the generated public artifacts, plan, and summary as part of the
   root CA inventory record.
7. Keep the PIN, PUK, and management key files outside `--work-dir`; the work
   directory is for public ceremony artifacts only.

## Procedure

### 1. Prepare The Workstation

Confirm the YubiKey is detectable:

```bash
ykman list --serials
```

If the token is not listed, fix that before continuing.

If `pd-pki-signing-tools` is not already available, open a temporary shell from
the repo:

```bash
nix shell .#pd-pki-signing-tools
```

Create a restricted working directory:

```bash
umask 077
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
PROFILE='/etc/pd-pki/root-yubikey-init-profile.json'
YK_SERIAL='<serial>'
PIN_FILE='/secure/root-pin.txt'
PUK_FILE='/secure/root-puk.txt'
MANAGEMENT_KEY_FILE='/secure/root-management-key.txt'
```

### 2. Review The Declarative Root Profile

Inspect the profile that will drive the ceremony:

```bash
jq '{
  subject,
  validityDays,
  slot,
  algorithm,
  pinPolicy,
  touchPolicy,
  pkcs11ModulePath,
  pkcs11ProviderDirectory,
  certificateInstallPath,
  archiveBaseDirectory
}' "$PROFILE"
```

Confirm at minimum:

1. The subject matches the approved root identity
2. The validity period matches the approved root lifetime
3. The slot, algorithm, PIN policy, and touch policy match the intended token
   controls
4. The certificate install path and archive base directory match the workstation
   runtime layout

### 3. Stage The Secret Files

Confirm the secret files exist and are tightly permissioned:

```bash
chmod 600 "$PIN_FILE" "$PUK_FILE" "$MANAGEMENT_KEY_FILE"
ls -l "$PIN_FILE" "$PUK_FILE" "$MANAGEMENT_KEY_FILE"
```

The command reads trimmed values from those files and validates:

1. PIN length is 6 to 8 characters
2. PUK length is 6 to 8 characters
3. Management key is exactly 64 hexadecimal characters
4. The files are owner-readable only, with no group or world access
5. The files are outside `--work-dir`
6. The PIN and PUK are not factory-default values
7. The management key is not the factory-default value
8. The PIN and PUK are not identical

### 4. Generate And Review The Dry-Run Plan

Run the command in dry-run mode first:

```bash
pd-pki-signing-tools init-root-yubikey \
  --profile "$PROFILE" \
  --yubikey-serial "$YK_SERIAL" \
  --work-dir "$WORKDIR" \
  --dry-run
```

If policy requires non-default retry counts, include both values:

```bash
pd-pki-signing-tools init-root-yubikey \
  --profile "$PROFILE" \
  --yubikey-serial "$YK_SERIAL" \
  --work-dir "$WORKDIR" \
  --pin-retries 5 \
  --puk-retries 3 \
  --dry-run
```

Review the generated plan and supporting files:

```bash
jq . "$WORKDIR/root-yubikey-init-plan.json"
cat "$WORKDIR/root-ca-openssl.cnf"
cat "$WORKDIR/root-key-uri.txt"
```

Confirm the plan shows:

1. `mode` is `dry-run`
2. The intended subject, validity, slot, algorithm, PIN policy, and touch
   policy
3. The expected certificate install path and archive directory
4. The expected PKCS#11 module path, provider directory, and routine key URI
5. The exact `--work-dir` you intend to reuse for the apply step

Dry-run is intentionally review-only:

1. Do not pass `--force-reset` with `--dry-run`
2. Do not pass `--pin-file`, `--puk-file`, or `--management-key-file` with
   `--dry-run`
3. Reuse the same `--work-dir` for the apply step so the reviewed plan remains
   the ceremony record

### 5. Apply The Reset-Based Initialization

Once the dry-run output is approved, run the destructive apply step:

```bash
pd-pki-signing-tools init-root-yubikey \
  --profile "$PROFILE" \
  --yubikey-serial "$YK_SERIAL" \
  --work-dir "$WORKDIR" \
  --pin-file "$PIN_FILE" \
  --puk-file "$PUK_FILE" \
  --management-key-file "$MANAGEMENT_KEY_FILE" \
  --force-reset
```

If approved retry counts are part of the ceremony, include them here too:

```bash
pd-pki-signing-tools init-root-yubikey \
  --profile "$PROFILE" \
  --yubikey-serial "$YK_SERIAL" \
  --work-dir "$WORKDIR" \
  --pin-file "$PIN_FILE" \
  --puk-file "$PUK_FILE" \
  --management-key-file "$MANAGEMENT_KEY_FILE" \
  --pin-retries 5 \
  --puk-retries 3 \
  --force-reset
```

This command performs the following actions:

1. Captures device and PIV state before the reset
2. Resets the PIV application
3. Optionally sets PIN and PUK retry counters
4. Changes the PIN, PUK, and management key from factory defaults
5. Generates the root signing key on-token
6. Captures the slot attestation certificate
7. Creates the self-signed root certificate through the PKCS#11 signer path
8. Imports the certificate into the configured slot
9. Generates fresh CHUID and CCC objects
10. Verifies the exported certificate and public key
11. Installs the root certificate to the configured runtime path
12. Archives the generated public artifacts, plan, and summary

Before the command touches hardware, it also refuses to continue unless all of
the following are true:

1. The reviewed dry-run plan already exists in the same `--work-dir`
2. The reviewed plan exactly matches the current apply invocation
3. The secret files are owner-only and outside `--work-dir`
4. The target install path does not already exist
5. The archive directory does not already contain files

### 6. Review The Summary And Installed Outputs

Review the generated summary:

```bash
jq . "$WORKDIR/root-yubikey-init-summary.json"
```

Review the resulting root certificate:

```bash
openssl x509 -in "$WORKDIR/root-ca.cert.pem" \
  -noout \
  -subject \
  -issuer \
  -serial \
  -dates \
  -fingerprint -sha256
```

Check the token state:

```bash
ykman --device "$YK_SERIAL" piv info
```

Resolve the final install and archive locations from the summary, then confirm
they exist:

```bash
INSTALL_PATH="$(jq -r '.certificateInstallPath' "$WORKDIR/root-yubikey-init-summary.json")"
ARCHIVE_DIR="$(jq -r '.archiveDirectory' "$WORKDIR/root-yubikey-init-summary.json")"
test -f "$INSTALL_PATH"
find "$ARCHIVE_DIR" -maxdepth 1 -type f | sort
```

Confirm that the summary recorded the reviewed plan path and digest:

```bash
jq '.reviewedPlan' "$WORKDIR/root-yubikey-init-summary.json"
```

### 7. Cleanup

Keep the generated public record in the approved archive location and remove any
temporary copies of secrets that were created outside the controlled secret
store.

Lock the token in its designated storage location when not in use.

## Expected Artifacts

The command writes an auditable working set in `--work-dir`, including:

1. `root-ca.cert.pem`
2. `root-ca.token-export.cert.pem`
3. `root-ca.pub.pem`
4. `root-ca.pub.verified.pem`
5. `root-ca.attestation.cert.pem`
6. `root-ca.metadata.json`
7. `root-yubikey-init-plan.json`
8. `root-yubikey-init-summary.json`
9. `root-ca-openssl.cnf`
10. `root-key-uri.txt`
11. `root-yubikey-profile.json`
12. `yubikey-device-info.before.txt`
13. `yubikey-device-info.after.txt`
14. `yubikey-piv-info.before.txt`
15. `yubikey-piv-info.after.txt`

The command also copies the public ceremony artifacts and records into the final
archive directory reported by `root-yubikey-init-summary.json`.

## Verification Checklist

Initialization is complete only if all of the following are true.

1. The dry-run plan was reviewed before the destructive apply step
2. The token was explicitly approved for reset-based initialization
3. The root private key was generated on-token, not imported
4. The configured slot contains the self-signed root certificate
5. The certificate subject, validity period, and fingerprint match the approved
   root profile and ceremony record
6. The runtime root certificate exists at the installed path from the summary
7. The attestation certificate, metadata, plan, and summary have been archived
8. The summary records the reviewed dry-run plan path and digest
9. The routine signing URI has been recorded from `root-key-uri.txt`
10. The PIN, PUK, and management key were not copied into the archive

## Failure Handling

Use the following rules if something goes wrong.

1. If dry-run validation fails, stop and correct the profile or invocation
   before touching hardware.
2. If apply preflight rejects the reviewed plan, secret files, archive
   directory, or install path, fix those inputs first and rerun `--dry-run`
   when required before attempting apply again.
3. If the destructive apply step fails before key generation, you may rerun the
   procedure on the same token after re-establishing a clean state.
4. If the apply step fails after key generation but before the summary and
   archive are complete, stop and decide whether to complete the ceremony or
   formally destroy and reinitialize the token.
5. If the wrong subject, validity period, slot, or policy was used, do not
   place the token into production use. Escalate for explicit destroy-and-
   replace approval.
6. If the token already carried an issued production root key, do not continue
   with this SOP. Use the manual fallback SOP to inspect and recover safely.

## Result

When this SOP completes successfully:

1. The YubiKey contains the root CA private key in the configured slot
2. The token enforces the configured PIN and touch policies for root signing
3. The self-signed root certificate is stored on-token and installed at the
   configured runtime path
4. Public inventory artifacts, attestation data, plan, and summary have been
   archived
5. The token is ready for routine root signing with the recorded PKCS#11 URI
