{ pkgs, packages }:
let
  inherit (pkgs.lib) listToAttrs;

  contractDoc = ../../docs/ROOT_CA_WORKFLOW_CONTRACTS.md;

  mkE2ECheck =
    derivationName: script:
    pkgs.runCommand derivationName
      {
        nativeBuildInputs = [
          packages.pd-pki-signing-tools
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
          pkgs.openssl
        ];
      }
      script;
in
listToAttrs [
  {
    name = "e2e-root-yubikey-provisioning-contract";
    value = mkE2ECheck "pd-pki-e2e-root-yubikey-provisioning-contract-check" ''
      set -euo pipefail

      printf '%s\n' "[e2e-root-yubikey-provisioning-contract] starting root YubiKey provisioning contract check"

      workdir="$(mktemp -d)"
      trap 'rm -rf "$workdir"' EXIT

      fake_pkcs11_module="$workdir/libykcs11.so"
      fake_pkcs11_provider_dir="$workdir/ossl-modules"
      : > "$fake_pkcs11_module"
      mkdir -p "$fake_pkcs11_provider_dir"

      jq -n \
        --arg pkcs11ModulePath "$fake_pkcs11_module" \
        --arg pkcs11ProviderDirectory "$fake_pkcs11_provider_dir" \
        '{
          schemaVersion: 1,
          profileKind: "root-yubikey-initialization",
          roleId: "root-certificate-authority",
          subject: "/CN=Pseudo Design Workflow Root CA",
          validityDays: 7300,
          slot: "9c",
          algorithm: "ECCP384",
          pinPolicy: "always",
          touchPolicy: "always",
          pkcs11ModulePath: $pkcs11ModulePath,
          pkcs11ProviderDirectory: $pkcs11ProviderDirectory,
          certificateInstallPath: "/var/lib/pd-pki/authorities/root/root-ca.cert.pem",
          archiveBaseDirectory: "/var/lib/pd-pki/yubikey-inventory"
        }' > "$workdir/profile.json"

      pd-pki-signing-tools init-root-yubikey \
        --profile "$workdir/profile.json" \
        --yubikey-serial 42424242 \
        --work-dir "$workdir/out" \
        --dry-run

      test -f "$workdir/out/root-yubikey-init-plan.json"
      test -f "$workdir/out/root-yubikey-profile.json"
      test -f "$workdir/out/root-ca-openssl.cnf"
      test -f "$workdir/out/root-key-uri.txt"

      jq -r '.command' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx 'init-root-yubikey'
      jq -r '.mode' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx 'dry-run'
      jq -r '.subject' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx '/CN=Pseudo Design Workflow Root CA'
      jq -r '.slot' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx '9c'
      jq -r '.routineKeyUri' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx 'pkcs11:token=YubiKey%20PIV;id=%02;type=private'
      jq -r '.profileKind' "$workdir/out/root-yubikey-profile.json" | grep -Fx 'root-yubikey-initialization'
      grep -F 'inventory/root-ca/<root-id>/' ${contractDoc}
      grep -F 'pd-pki-transfer/root-inventory/root-<root-id>-<timestamp>/' ${contractDoc}

      printf '%s\n' "[e2e-root-yubikey-provisioning-contract] root YubiKey provisioning contract check passed"
      touch "$out"
    '';
  }
  {
    name = "e2e-root-inventory-export-bundle-contract";
    value = mkE2ECheck "pd-pki-e2e-root-inventory-export-bundle-contract-check" ''
      set -euo pipefail

      source ${../../packages/pki-workflow-lib.sh}

      printf '%s\n' "[e2e-root-inventory-export-bundle-contract] starting root inventory export bundle contract check"

      workdir="$(mktemp -d)"
      trap 'rm -rf "$workdir"' EXIT

      archive_dir="$workdir/archive/root-42424242"
      export_bundle_dir="$workdir/usb/pd-pki-transfer/root-inventory/root-bundle-20260413T000000Z"
      inventory_root="$workdir/inventory/root-ca"
      root_fixture="$workdir/root"
      attestation_fixture="$workdir/attestation"

      generate_self_signed_ca "$root_fixture" "root-ca" "Pseudo Design Workflow Root CA" 9001 7300 1 ec-p384
      generate_self_signed_ca "$attestation_fixture" "root-attestation" "Pseudo Design Root Attestation" 7001 3650 0 ec-p384

      mkdir -p "$archive_dir"
      cp "$root_fixture/root-ca.cert.pem" "$archive_dir/root-ca.cert.pem"
      openssl pkey -in "$root_fixture/root-ca.key.pem" -pubout -outform pem > "$archive_dir/root-ca.pub.verified.pem"
      cp "$attestation_fixture/root-attestation.cert.pem" "$archive_dir/root-ca.attestation.cert.pem"
      write_certificate_metadata "$archive_dir/root-ca.cert.pem" "$archive_dir/root-ca.metadata.json" "root-ca-yubikey-initialized"
      printf '%s\n' 'pkcs11:model=YubiKey%20YK5;manufacturer=Yubico%20%28www.yubico.com%29;serial=42424242;token=YubiKey%20PIV;id=%02;object=Private%20key%20for%20Digital%20Signature;type=private' > "$archive_dir/root-key-uri.txt"

      fingerprint="$(certificate_fingerprint "$archive_dir/root-ca.cert.pem")"
      root_id="$(printf '%s' "$fingerprint" | tr -d ':' | tr '[:upper:]' '[:lower:]')"

      jq -n \
        --arg completedAt "2026-04-13T00:00:00Z" \
        --arg yubikeySerial "42424242" \
        --arg slot "9c" \
        --arg routineKeyUri "$(cat "$archive_dir/root-key-uri.txt")" \
        --arg certificateInstallPath "/var/lib/pd-pki/authorities/root/root-ca.cert.pem" \
        --arg archiveDirectory "$archive_dir" \
        --arg profilePath "/etc/pd-pki/root-yubikey-init-profile.json" \
        --arg reviewedPlanPath "$archive_dir/root-yubikey-init-plan.json" \
        --arg reviewedPlanSha256 "deadbeef" \
        --arg subject "$(certificate_subject "$root_fixture/root-ca.cert.pem")" \
        --arg serial "$(certificate_serial "$root_fixture/root-ca.cert.pem")" \
        --arg fingerprint "$fingerprint" \
        --arg notBefore "$(certificate_not_before "$root_fixture/root-ca.cert.pem")" \
        --arg notAfter "$(certificate_not_after "$root_fixture/root-ca.cert.pem")" \
        --arg attestationFingerprint "$(certificate_fingerprint "$attestation_fixture/root-attestation.cert.pem")" \
        '{
          schemaVersion: 1,
          command: "init-root-yubikey",
          completedAt: $completedAt,
          yubikeySerial: $yubikeySerial,
          forceResetApplied: true,
          slot: $slot,
          routineKeyUri: $routineKeyUri,
          profilePath: $profilePath,
          reviewedPlan: {
            path: $reviewedPlanPath,
            sha256: $reviewedPlanSha256
          },
          certificateInstallPath: $certificateInstallPath,
          archiveDirectory: $archiveDirectory,
          certificate: {
            subject: $subject,
            serial: $serial,
            sha256Fingerprint: $fingerprint,
            notBefore: $notBefore,
            notAfter: $notAfter
          },
          attestation: {
            sha256Fingerprint: $attestationFingerprint
          }
        }' > "$archive_dir/root-yubikey-init-summary.json"

      pd-pki-signing-tools export-root-inventory \
        --source-dir "$archive_dir" \
        --out-dir "$export_bundle_dir"

      test -f "$export_bundle_dir/manifest.json"
      test -f "$export_bundle_dir/root-ca.cert.pem"
      test -f "$export_bundle_dir/root-ca.pub.verified.pem"
      test -f "$export_bundle_dir/root-ca.attestation.cert.pem"
      test -f "$export_bundle_dir/root-ca.metadata.json"
      test -f "$export_bundle_dir/root-yubikey-init-summary.json"
      test -f "$export_bundle_dir/root-key-uri.txt"

      jq -r '.contractKind' "$export_bundle_dir/manifest.json" | grep -Fx 'root-ca-inventory'
      jq -r '.rootId' "$export_bundle_dir/manifest.json" | grep -Fx "$root_id"
      jq -r '.yubiKey.serial' "$export_bundle_dir/manifest.json" | grep -Fx '42424242'
      jq -r '.yubiKey.routineKeyUri' "$export_bundle_dir/manifest.json" | grep -Fx 'pkcs11:model=YubiKey%20YK5;manufacturer=Yubico%20%28www.yubico.com%29;serial=42424242;token=YubiKey%20PIV;id=%02;object=Private%20key%20for%20Digital%20Signature;type=private'

      pd-pki-signing-tools normalize-root-inventory \
        --source-dir "$export_bundle_dir" \
        --inventory-root "$inventory_root"

      normalized_dir="$inventory_root/$root_id"
      test -f "$normalized_dir/manifest.json"
      jq -r '.rootId' "$normalized_dir/manifest.json" | grep -Fx "$root_id"

      printf '%s\n' "[e2e-root-inventory-export-bundle-contract] root inventory export bundle contract check passed"
      touch "$out"
    '';
  }
  {
    name = "e2e-root-yubikey-inventory-normalization";
    value = mkE2ECheck "pd-pki-e2e-root-yubikey-inventory-normalization-check" ''
      set -euo pipefail

      source ${../../packages/pki-workflow-lib.sh}

      printf '%s\n' "[e2e-root-yubikey-inventory-normalization] starting root inventory normalization check"

      workdir="$(mktemp -d)"
      trap 'rm -rf "$workdir"' EXIT

      bundle_dir="$workdir/root-bundle"
      inventory_root="$workdir/inventory/root-ca"
      root_fixture="$workdir/root"
      attestation_fixture="$workdir/attestation"

      generate_self_signed_ca "$root_fixture" "root-ca" "Pseudo Design Workflow Root CA" 9001 7300 1 ec-p384
      generate_self_signed_ca "$attestation_fixture" "root-attestation" "Pseudo Design Root Attestation" 7001 3650 0 ec-p384

      openssl pkey -in "$root_fixture/root-ca.key.pem" -pubout -outform pem > "$root_fixture/root-ca.pub.verified.pem"
      write_certificate_metadata \
        "$root_fixture/root-ca.cert.pem" \
        "$root_fixture/root-ca.metadata.json" \
        "root-ca-yubikey-initialized"

      fingerprint="$(certificate_fingerprint "$root_fixture/root-ca.cert.pem")"
      root_id="$(printf '%s' "$fingerprint" | tr -d ':' | tr '[:upper:]' '[:lower:]')"

      mkdir -p "$bundle_dir"
      cp "$root_fixture/root-ca.cert.pem" "$bundle_dir/root-ca.cert.pem"
      cp "$root_fixture/root-ca.pub.verified.pem" "$bundle_dir/root-ca.pub.verified.pem"
      cp "$attestation_fixture/root-attestation.cert.pem" "$bundle_dir/root-ca.attestation.cert.pem"
      cp "$root_fixture/root-ca.metadata.json" "$bundle_dir/root-ca.metadata.json"
      printf '%s\n' 'pkcs11:model=YubiKey%20YK5;manufacturer=Yubico%20%28www.yubico.com%29;serial=42424242;token=YubiKey%20PIV;id=%02;object=Private%20key%20for%20Digital%20Signature;type=private' > "$bundle_dir/root-key-uri.txt"

      jq -n \
        --arg completedAt "2026-04-13T00:00:00Z" \
        --arg yubikeySerial "42424242" \
        --arg slot "9c" \
        --arg routineKeyUri "$(cat "$bundle_dir/root-key-uri.txt")" \
        --arg certificateInstallPath "/var/lib/pd-pki/authorities/root/root-ca.cert.pem" \
        --arg archiveDirectory "/var/lib/pd-pki/yubikey-inventory/root-42424242" \
        --arg profilePath "/etc/pd-pki/root-yubikey-init-profile.json" \
        --arg reviewedPlanPath "/var/lib/pd-pki/yubikey-inventory/root-42424242/root-yubikey-init-plan.json" \
        --arg reviewedPlanSha256 "deadbeef" \
        --arg subject "$(certificate_subject "$root_fixture/root-ca.cert.pem")" \
        --arg serial "$(certificate_serial "$root_fixture/root-ca.cert.pem")" \
        --arg fingerprint "$fingerprint" \
        --arg notBefore "$(certificate_not_before "$root_fixture/root-ca.cert.pem")" \
        --arg notAfter "$(certificate_not_after "$root_fixture/root-ca.cert.pem")" \
        --arg attestationFingerprint "$(certificate_fingerprint "$attestation_fixture/root-attestation.cert.pem")" \
        '{
          schemaVersion: 1,
          command: "init-root-yubikey",
          completedAt: $completedAt,
          yubikeySerial: $yubikeySerial,
          forceResetApplied: true,
          slot: $slot,
          routineKeyUri: $routineKeyUri,
          profilePath: $profilePath,
          reviewedPlan: {
            path: $reviewedPlanPath,
            sha256: $reviewedPlanSha256
          },
          certificateInstallPath: $certificateInstallPath,
          archiveDirectory: $archiveDirectory,
          certificate: {
            subject: $subject,
            serial: $serial,
            sha256Fingerprint: $fingerprint,
            notBefore: $notBefore,
            notAfter: $notAfter
          },
          attestation: {
            sha256Fingerprint: $attestationFingerprint
          }
        }' > "$bundle_dir/root-yubikey-init-summary.json"

      pd-pki-signing-tools normalize-root-inventory \
        --source-dir "$bundle_dir" \
        --inventory-root "$inventory_root"

      inventory_dir="$inventory_root/$root_id"

      test -f "$inventory_dir/manifest.json"
      jq -r '.contractKind' "$inventory_dir/manifest.json" | grep -Fx 'root-ca-inventory'
      jq -r '.rootId' "$inventory_dir/manifest.json" | grep -Fx "$root_id"
      jq -r '.certificate.sha256Fingerprint' "$inventory_dir/manifest.json" | grep -Fx "$fingerprint"
      jq -r '.certificate.sha256Fingerprint' "$inventory_dir/manifest.json" | grep -Fx "$(jq -r '.sha256Fingerprint' "$inventory_dir/root-ca.metadata.json")"
      jq -r '.certificate.sha256Fingerprint' "$inventory_dir/manifest.json" | grep -Fx "$(jq -r '.certificate.sha256Fingerprint' "$inventory_dir/root-yubikey-init-summary.json")"
      jq -r '.attestation.sha256Fingerprint' "$inventory_dir/manifest.json" | grep -Fx "$(jq -r '.attestation.sha256Fingerprint' "$inventory_dir/root-yubikey-init-summary.json")"
      jq -r '.yubiKey.routineKeyUri' "$inventory_dir/manifest.json" | grep -Fx 'pkcs11:model=YubiKey%20YK5;manufacturer=Yubico%20%28www.yubico.com%29;serial=42424242;token=YubiKey%20PIV;id=%02;object=Private%20key%20for%20Digital%20Signature;type=private'

      printf '%s\n' "[e2e-root-yubikey-inventory-normalization] root inventory normalization check passed"
      touch "$out"
    '';
  }
  {
    name = "e2e-root-yubikey-identity-verification";
    value = mkE2ECheck "pd-pki-e2e-root-yubikey-identity-verification-check" ''
      set -euo pipefail

      source ${../../packages/pki-workflow-lib.sh}

      printf '%s\n' "[e2e-root-yubikey-identity-verification] starting root YubiKey identity verification check"

      workdir="$(mktemp -d)"
      trap 'rm -rf "$workdir"' EXIT

      bundle_dir="$workdir/root-bundle"
      inventory_root="$workdir/inventory/root-ca"
      root_fixture="$workdir/root"
      bad_fixture="$workdir/bad-root"
      attestation_fixture="$workdir/attestation"
      verify_good_dir="$workdir/verify-good"
      verify_bad_dir="$workdir/verify-bad"
      verify_audit_dir="$workdir/verify-audit"

      generate_self_signed_ca "$root_fixture" "root-ca" "Pseudo Design Workflow Root CA" 9001 7300 1 ec-p384
      generate_self_signed_ca "$bad_fixture" "replacement-root-ca" "Pseudo Design Replacement Root CA" 9002 7300 1 ec-p384
      generate_self_signed_ca "$attestation_fixture" "root-attestation" "Pseudo Design Root Attestation" 7001 3650 0 ec-p384

      mkdir -p "$bundle_dir"
      cp "$root_fixture/root-ca.cert.pem" "$bundle_dir/root-ca.cert.pem"
      openssl pkey -in "$root_fixture/root-ca.key.pem" -pubout -outform pem > "$bundle_dir/root-ca.pub.verified.pem"
      cp "$attestation_fixture/root-attestation.cert.pem" "$bundle_dir/root-ca.attestation.cert.pem"
      write_certificate_metadata "$bundle_dir/root-ca.cert.pem" "$bundle_dir/root-ca.metadata.json" "root-ca-yubikey-initialized"

      fingerprint="$(certificate_fingerprint "$bundle_dir/root-ca.cert.pem")"
      root_id="$(printf '%s' "$fingerprint" | tr -d ':' | tr '[:upper:]' '[:lower:]')"

      printf '%s\n' 'pkcs11:model=YubiKey%20YK5;manufacturer=Yubico%20%28www.yubico.com%29;serial=42424242;token=YubiKey%20PIV;id=%02;object=Private%20key%20for%20Digital%20Signature;type=private' > "$bundle_dir/root-key-uri.txt"
      jq -n \
        --arg completedAt "2026-04-13T00:00:00Z" \
        --arg yubikeySerial "42424242" \
        --arg slot "9c" \
        --arg routineKeyUri "$(cat "$bundle_dir/root-key-uri.txt")" \
        --arg certificateInstallPath "/var/lib/pd-pki/authorities/root/root-ca.cert.pem" \
        --arg archiveDirectory "/var/lib/pd-pki/yubikey-inventory/root-42424242" \
        --arg profilePath "/etc/pd-pki/root-yubikey-init-profile.json" \
        --arg reviewedPlanPath "/var/lib/pd-pki/yubikey-inventory/root-42424242/root-yubikey-init-plan.json" \
        --arg reviewedPlanSha256 "deadbeef" \
        --arg subject "$(certificate_subject "$bundle_dir/root-ca.cert.pem")" \
        --arg serial "$(certificate_serial "$bundle_dir/root-ca.cert.pem")" \
        --arg fingerprint "$fingerprint" \
        --arg notBefore "$(certificate_not_before "$bundle_dir/root-ca.cert.pem")" \
        --arg notAfter "$(certificate_not_after "$bundle_dir/root-ca.cert.pem")" \
        --arg attestationFingerprint "$(certificate_fingerprint "$bundle_dir/root-ca.attestation.cert.pem")" \
        '{
          schemaVersion: 1,
          command: "init-root-yubikey",
          completedAt: $completedAt,
          yubikeySerial: $yubikeySerial,
          forceResetApplied: true,
          slot: $slot,
          routineKeyUri: $routineKeyUri,
          profilePath: $profilePath,
          reviewedPlan: {
            path: $reviewedPlanPath,
            sha256: $reviewedPlanSha256
          },
          certificateInstallPath: $certificateInstallPath,
          archiveDirectory: $archiveDirectory,
          certificate: {
            subject: $subject,
            serial: $serial,
            sha256Fingerprint: $fingerprint,
            notBefore: $notBefore,
            notAfter: $notAfter
          },
          attestation: {
            sha256Fingerprint: $attestationFingerprint
          }
        }' > "$bundle_dir/root-yubikey-init-summary.json"

      pd-pki-signing-tools normalize-root-inventory \
        --source-dir "$bundle_dir" \
        --inventory-root "$inventory_root"

      inventory_dir="$inventory_root/$root_id"
      pin_file="$workdir/root-pin.txt"
      fake_ykman="$workdir/fake-ykman"
      bad_public_key_path="$bad_fixture/replacement-root-ca.pub.verified.pem"

      printf '%s\n' '12345678' > "$pin_file"
      chmod 600 "$pin_file"
      openssl pkey -in "$bad_fixture/replacement-root-ca.key.pem" -pubout -outform pem > "$bad_public_key_path"

      cat > "$fake_ykman" <<'EOF'
#!${pkgs.bash}/bin/bash
set -euo pipefail

serial=""
if [ "''${1:-}" = "--device" ]; then
  serial="''${2:-}"
  shift 2
fi

case "''${1:-}" in
  info)
    printf '%s\n' "Device type: YubiKey 5"
    printf 'Serial number: %s\n' "$serial"
    ;;
  piv)
    shift
    case "''${1:-}" in
      info)
        printf '%s\n' "PIV version: 5.7.0"
        printf '%s\n' "PIN tries remaining: 3/3"
        printf '%s\n' "Slot 9C: X.509 Certificate"
        ;;
      certificates)
        [ "''${2:-}" = "export" ] || exit 64
        cp "$PD_PKI_FAKE_YKMAN_CERT" "''${4:-}"
        ;;
      keys)
        [ "''${2:-}" = "export" ] || exit 64
        destination="''${4:-}"
        shift 4
        verify=0
        pin=""
        while [ "''${#}" -gt 0 ]; do
          case "$1" in
            --verify)
              verify=1
              shift
              ;;
            --pin)
              pin="''${2:-}"
              shift 2
              ;;
            *)
              exit 64
              ;;
          esac
        done
        [ "$verify" = "1" ] || exit 64
        [ "$pin" = "$PD_PKI_FAKE_YKMAN_PIN" ] || exit 1
        cp "$PD_PKI_FAKE_YKMAN_PUB" "$destination"
        ;;
      *)
        exit 64
        ;;
    esac
    ;;
  *)
    exit 64
    ;;
esac
EOF
      chmod 755 "$fake_ykman"

      env \
        PD_PKI_YKMAN_BIN="$fake_ykman" \
        PD_PKI_FAKE_YKMAN_CERT="$inventory_dir/root-ca.cert.pem" \
        PD_PKI_FAKE_YKMAN_PUB="$inventory_dir/root-ca.pub.verified.pem" \
        PD_PKI_FAKE_YKMAN_PIN="12345678" \
        pd-pki-signing-tools verify-root-yubikey-identity \
          --inventory-dir "$inventory_dir" \
          --yubikey-serial 42424242 \
          --pin-file "$pin_file" \
          --work-dir "$verify_good_dir"

      test -f "$verify_good_dir/root-yubikey-identity-summary.json"
      jq -r '.rootId' "$verify_good_dir/root-yubikey-identity-summary.json" | grep -Fx "$root_id"
      jq -r '.certificate.match' "$verify_good_dir/root-yubikey-identity-summary.json" | grep -Fx 'true'
      jq -r '.verifiedPublicKey.match' "$verify_good_dir/root-yubikey-identity-summary.json" | grep -Fx 'true'
      jq -r '.serialMatches' "$verify_good_dir/root-yubikey-identity-summary.json" | grep -Fx 'true'

      if env \
        PD_PKI_YKMAN_BIN="$fake_ykman" \
        PD_PKI_FAKE_YKMAN_CERT="$bad_fixture/replacement-root-ca.cert.pem" \
        PD_PKI_FAKE_YKMAN_PUB="$bad_public_key_path" \
        PD_PKI_FAKE_YKMAN_PIN="12345678" \
        pd-pki-signing-tools verify-root-yubikey-identity \
          --inventory-dir "$inventory_dir" \
          --yubikey-serial 42424242 \
          --pin-file "$pin_file" \
          --work-dir "$verify_bad_dir"; then
        printf '%s\n' "[e2e-root-yubikey-identity-verification] expected mismatched certificate and public key to fail verification" >&2
        exit 1
      fi

      test -f "$verify_bad_dir/root-yubikey-identity-summary.json"
      jq -e '.certificate.match == false and .verifiedPublicKey.match == false' "$verify_bad_dir/root-yubikey-identity-summary.json" >/dev/null

      env \
        PD_PKI_YKMAN_BIN="$fake_ykman" \
        PD_PKI_FAKE_YKMAN_CERT="$inventory_dir/root-ca.cert.pem" \
        PD_PKI_FAKE_YKMAN_PUB="$inventory_dir/root-ca.pub.verified.pem" \
        PD_PKI_FAKE_YKMAN_PIN="12345678" \
        pd-pki-signing-tools verify-root-yubikey-identity \
          --inventory-dir "$inventory_dir" \
          --yubikey-serial 99999999 \
          --pin-file "$pin_file" \
          --work-dir "$verify_audit_dir"

      jq -r '.certificate.match' "$verify_audit_dir/root-yubikey-identity-summary.json" | grep -Fx 'true'
      jq -r '.verifiedPublicKey.match' "$verify_audit_dir/root-yubikey-identity-summary.json" | grep -Fx 'true'
      jq -r '.serialMatches' "$verify_audit_dir/root-yubikey-identity-summary.json" | grep -Fx 'false'

      grep -F 'The primary trust anchor is the root CA certificate and public key' ${contractDoc}

      printf '%s\n' "[e2e-root-yubikey-identity-verification] root YubiKey identity verification check passed"
      touch "$out"
    '';
  }
  {
    name = "e2e-root-intermediate-request-bundle-contract";
    value = mkE2ECheck "pd-pki-e2e-root-intermediate-request-bundle-contract-check" ''
      set -euo pipefail

      source ${../../packages/pki-workflow-lib.sh}

      printf '%s\n' "[e2e-root-intermediate-request-bundle-contract] starting intermediate request bundle contract check"

      workdir="$(mktemp -d)"
      trap 'rm -rf "$workdir"' EXIT

      state_dir="$workdir/intermediate-state"
      bundle_dir="$workdir/request-bundle"

      generate_ca_request "$state_dir" "intermediate-ca" "Pseudo Design Runtime Intermediate Signing Authority" 0

      jq -n \
        --arg schemaVersion "1" \
        --arg roleId "intermediate-signing-authority" \
        --arg requestKind "intermediate-ca" \
        --arg basename "intermediate-ca" \
        --arg commonName "Pseudo Design Runtime Intermediate Signing Authority" \
        --arg pathLen "0" \
        --arg requestedDays "3650" \
        --arg csrFile "intermediate-ca.csr.pem" \
        '{
          schemaVersion: ($schemaVersion | tonumber),
          roleId: $roleId,
          requestKind: $requestKind,
          basename: $basename,
          commonName: $commonName,
          pathLen: ($pathLen | tonumber),
          requestedDays: ($requestedDays | tonumber),
          csrFile: $csrFile
        }' > "$state_dir/signing-request.json"

      pd-pki-signing-tools export-request \
        --role intermediate-signing-authority \
        --state-dir "$state_dir" \
        --out-dir "$bundle_dir"

      test -f "$bundle_dir/request.json"
      test -f "$bundle_dir/intermediate-ca.csr.pem"
      test ! -e "$bundle_dir/intermediate-ca.key.pem"

      jq -r '.roleId' "$bundle_dir/request.json" | grep -Fx 'intermediate-signing-authority'
      jq -r '.requestKind' "$bundle_dir/request.json" | grep -Fx 'intermediate-ca'
      jq -r '.basename' "$bundle_dir/request.json" | grep -Fx 'intermediate-ca'
      jq -r '.csrFile' "$bundle_dir/request.json" | grep -Fx 'intermediate-ca.csr.pem'
      csr_common_name "$bundle_dir/intermediate-ca.csr.pem" | grep -Fx 'Pseudo Design Runtime Intermediate Signing Authority'

      printf '%s\n' "[e2e-root-intermediate-request-bundle-contract] intermediate request bundle contract check passed"
      touch "$out"
    '';
  }
  {
    name = "e2e-root-intermediate-signed-bundle-contract";
    value = mkE2ECheck "pd-pki-e2e-root-intermediate-signed-bundle-contract-check" ''
      set -euo pipefail

      source ${../../packages/pki-workflow-lib.sh}

      printf '%s\n' "[e2e-root-intermediate-signed-bundle-contract] starting intermediate signed bundle contract check"

      workdir="$(mktemp -d)"
      trap 'rm -rf "$workdir"' EXIT

      root_dir="$workdir/root"
      request_dir="$workdir/request"
      signed_dir="$workdir/signed"
      signer_state_dir="$workdir/signer-state"

      generate_self_signed_ca "$root_dir" "root-ca" "Pseudo Design Workflow Root CA" 9001 7300 1 ec-p384
      generate_ca_request "$request_dir" "intermediate-ca" "Pseudo Design Runtime Intermediate Signing Authority" 0

      jq -n \
        --arg schemaVersion "1" \
        --arg roleId "intermediate-signing-authority" \
        --arg requestKind "intermediate-ca" \
        --arg basename "intermediate-ca" \
        --arg commonName "Pseudo Design Runtime Intermediate Signing Authority" \
        --arg pathLen "0" \
        --arg requestedDays "3650" \
        --arg csrFile "intermediate-ca.csr.pem" \
        '{
          schemaVersion: ($schemaVersion | tonumber),
          roleId: $roleId,
          requestKind: $requestKind,
          basename: $basename,
          commonName: $commonName,
          pathLen: ($pathLen | tonumber),
          requestedDays: ($requestedDays | tonumber),
          csrFile: $csrFile
        }' > "$request_dir/request.json"

      jq -n '
        {
          schemaVersion: 1,
          roles: {
            "intermediate-signing-authority": {
              defaultDays: 3650,
              maxDays: 3650,
              allowedKeyAlgorithms: ["RSA"],
              minimumRsaBits: 3072,
              allowedPathLens: [0],
              commonNamePatterns: ["^[A-Za-z0-9 .-]+$"]
            }
          }
        }
      ' > "$workdir/root-policy.json"

      pd-pki-signing-tools sign-request \
        --request-dir "$request_dir" \
        --out-dir "$signed_dir" \
        --issuer-key "$root_dir/root-ca.key.pem" \
        --issuer-cert "$root_dir/root-ca.cert.pem" \
        --signer-state-dir "$signer_state_dir" \
        --policy-file "$workdir/root-policy.json" \
        --approved-by workflow-root

      test -f "$signed_dir/request.json"
      test -f "$signed_dir/intermediate-ca.cert.pem"
      test -f "$signed_dir/chain.pem"
      test -f "$signed_dir/metadata.json"

      jq -r '.profile' "$signed_dir/metadata.json" | grep -Fx 'intermediate-ca-signed'
      jq -r '.roleId' "$signed_dir/request.json" | grep -Fx 'intermediate-signing-authority'
      openssl verify -CAfile "$signed_dir/chain.pem" "$signed_dir/intermediate-ca.cert.pem" >/dev/null

      test -f "$signer_state_dir/issuances/01/issuance.json"
      jq -r '.status' "$signer_state_dir/issuances/01/issuance.json" | grep -Fx 'issued'
      jq -r '.issuer.sha256Fingerprint' "$signer_state_dir/issuances/01/issuance.json" | grep -Fx "$(certificate_fingerprint "$root_dir/root-ca.cert.pem")"

      printf '%s\n' "[e2e-root-intermediate-signed-bundle-contract] intermediate signed bundle contract check passed"
      touch "$out"
    '';
  }
  {
    name = "e2e-root-intermediate-airgap-handoff";
    value = mkE2ECheck "pd-pki-e2e-root-intermediate-airgap-handoff-check" ''
      set -euo pipefail

      source ${../../packages/pki-workflow-lib.sh}

      printf '%s\n' "[e2e-root-intermediate-airgap-handoff] starting intermediate air-gap handoff check"

      workdir="$(mktemp -d)"
      trap 'rm -rf "$workdir"' EXIT

      transfer_root="$workdir/usb/pd-pki-transfer"
      intermediate_state="$workdir/intermediate-state"
      request_stage="$workdir/request-stage"
      signed_stage="$workdir/signed-stage"
      signer_state_dir="$workdir/root-signer-state"
      root_dir="$workdir/root"

      generate_self_signed_ca "$root_dir" "root-ca" "Pseudo Design Workflow Root CA" 9001 7300 1 ec-p384
      generate_ca_request "$intermediate_state" "intermediate-ca" "Pseudo Design Runtime Intermediate Signing Authority" 0

      jq -n \
        --arg schemaVersion "1" \
        --arg roleId "intermediate-signing-authority" \
        --arg requestKind "intermediate-ca" \
        --arg basename "intermediate-ca" \
        --arg commonName "Pseudo Design Runtime Intermediate Signing Authority" \
        --arg pathLen "0" \
        --arg requestedDays "3650" \
        --arg csrFile "intermediate-ca.csr.pem" \
        '{
          schemaVersion: ($schemaVersion | tonumber),
          roleId: $roleId,
          requestKind: $requestKind,
          basename: $basename,
          commonName: $commonName,
          pathLen: ($pathLen | tonumber),
          requestedDays: ($requestedDays | tonumber),
          csrFile: $csrFile
        }' > "$intermediate_state/signing-request.json"

      jq -n '
        {
          schemaVersion: 1,
          roles: {
            "intermediate-signing-authority": {
              defaultDays: 3650,
              maxDays: 3650,
              allowedKeyAlgorithms: ["RSA"],
              minimumRsaBits: 3072,
              allowedPathLens: [0],
              commonNamePatterns: ["^[A-Za-z0-9 .-]+$"]
            }
          }
        }
      ' > "$workdir/root-policy.json"

      pd-pki-signing-tools export-request \
        --role intermediate-signing-authority \
        --state-dir "$intermediate_state" \
        --out-dir "$request_stage"

      request_bundle="$transfer_root/requests/intermediate-request-20260413T000000Z"
      mkdir -p "$(dirname "$request_bundle")"
      cp -R "$request_stage" "$request_bundle"

      test -f "$request_bundle/request.json"
      test -f "$request_bundle/intermediate-ca.csr.pem"
      test ! -e "$request_bundle/intermediate-ca.key.pem"

      pd-pki-signing-tools sign-request \
        --request-dir "$request_bundle" \
        --out-dir "$signed_stage" \
        --issuer-key "$root_dir/root-ca.key.pem" \
        --issuer-cert "$root_dir/root-ca.cert.pem" \
        --signer-state-dir "$signer_state_dir" \
        --policy-file "$workdir/root-policy.json" \
        --approved-by workflow-root

      signed_bundle="$transfer_root/signed/intermediate-signed-20260413T000000Z"
      mkdir -p "$(dirname "$signed_bundle")"
      cp -R "$signed_stage" "$signed_bundle"

      test -f "$signed_bundle/intermediate-ca.cert.pem"
      test -f "$signed_bundle/chain.pem"
      test -f "$signed_bundle/metadata.json"
      test -f "$signed_bundle/request.json"

      pd-pki-signing-tools import-signed \
        --role intermediate-signing-authority \
        --state-dir "$intermediate_state" \
        --signed-dir "$signed_bundle"

      test -f "$intermediate_state/intermediate-ca.cert.pem"
      test -f "$intermediate_state/chain.pem"
      test -f "$intermediate_state/signer-metadata.json"
      openssl verify -CAfile "$intermediate_state/chain.pem" "$intermediate_state/intermediate-ca.cert.pem" >/dev/null
      jq -r '.profile' "$intermediate_state/signer-metadata.json" | grep -Fx 'intermediate-ca-signed'

      printf '%s\n' "[e2e-root-intermediate-airgap-handoff] intermediate air-gap handoff check passed"
      touch "$out"
    '';
  }
]
