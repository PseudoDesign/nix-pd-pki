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
      fake_pkcs11_provider_dir="$workdir/ossl-module"
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
      printf '%s\n' 'pkcs11:token=YubiKey%20PIV;id=%02;type=private' > "$bundle_dir/root-key-uri.txt"

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

      inventory_dir="$inventory_root/$root_id"
      mkdir -p "$inventory_dir"
      cp "$bundle_dir/root-ca.cert.pem" "$inventory_dir/root-ca.cert.pem"
      cp "$bundle_dir/root-ca.pub.verified.pem" "$inventory_dir/root-ca.pub.verified.pem"
      cp "$bundle_dir/root-ca.attestation.cert.pem" "$inventory_dir/root-ca.attestation.cert.pem"
      cp "$bundle_dir/root-ca.metadata.json" "$inventory_dir/root-ca.metadata.json"
      cp "$bundle_dir/root-yubikey-init-summary.json" "$inventory_dir/root-yubikey-init-summary.json"
      cp "$bundle_dir/root-key-uri.txt" "$inventory_dir/root-key-uri.txt"

      verified_pub_sha256="$(sha256sum "$inventory_dir/root-ca.pub.verified.pem" | cut -d' ' -f1)"
      jq -n \
        --arg rootId "$root_id" \
        --arg serial "42424242" \
        --arg slot "9c" \
        --arg routineKeyUri "$(cat "$inventory_dir/root-key-uri.txt")" \
        --arg certificatePath "root-ca.cert.pem" \
        --arg subject "$(certificate_subject "$inventory_dir/root-ca.cert.pem")" \
        --arg certificateSerial "$(certificate_serial "$inventory_dir/root-ca.cert.pem")" \
        --arg certificateFingerprint "$(certificate_fingerprint "$inventory_dir/root-ca.cert.pem")" \
        --arg notBefore "$(certificate_not_before "$inventory_dir/root-ca.cert.pem")" \
        --arg notAfter "$(certificate_not_after "$inventory_dir/root-ca.cert.pem")" \
        --arg verifiedPublicKeyPath "root-ca.pub.verified.pem" \
        --arg verifiedPublicKeySha256 "$verified_pub_sha256" \
        --arg attestationPath "root-ca.attestation.cert.pem" \
        --arg attestationFingerprint "$(certificate_fingerprint "$inventory_dir/root-ca.attestation.cert.pem")" \
        --arg metadataPath "root-ca.metadata.json" \
        --arg summaryPath "root-yubikey-init-summary.json" \
        '{
          schemaVersion: 1,
          contractKind: "root-ca-inventory",
          rootId: $rootId,
          source: {
            command: "init-root-yubikey",
            profileKind: "root-yubikey-initialization"
          },
          yubiKey: {
            serial: $serial,
            slot: $slot,
            routineKeyUri: $routineKeyUri
          },
          certificate: {
            path: $certificatePath,
            subject: $subject,
            serial: $certificateSerial,
            sha256Fingerprint: $certificateFingerprint,
            notBefore: $notBefore,
            notAfter: $notAfter
          },
          verifiedPublicKey: {
            path: $verifiedPublicKeyPath,
            sha256: $verifiedPublicKeySha256
          },
          attestation: {
            path: $attestationPath,
            sha256Fingerprint: $attestationFingerprint
          },
          metadata: {
            path: $metadataPath,
            profile: "root-ca-yubikey-initialized"
          },
          ceremony: {
            summaryPath: $summaryPath
          }
        }' > "$inventory_dir/manifest.json"

      test -f "$inventory_dir/manifest.json"
      jq -r '.contractKind' "$inventory_dir/manifest.json" | grep -Fx 'root-ca-inventory'
      jq -r '.rootId' "$inventory_dir/manifest.json" | grep -Fx "$root_id"
      jq -r '.certificate.sha256Fingerprint' "$inventory_dir/manifest.json" | grep -Fx "$fingerprint"
      jq -r '.certificate.sha256Fingerprint' "$inventory_dir/manifest.json" | grep -Fx "$(jq -r '.sha256Fingerprint' "$inventory_dir/root-ca.metadata.json")"
      jq -r '.certificate.sha256Fingerprint' "$inventory_dir/manifest.json" | grep -Fx "$(jq -r '.certificate.sha256Fingerprint' "$inventory_dir/root-yubikey-init-summary.json")"
      jq -r '.attestation.sha256Fingerprint' "$inventory_dir/manifest.json" | grep -Fx "$(jq -r '.attestation.sha256Fingerprint' "$inventory_dir/root-yubikey-init-summary.json")"
      jq -r '.yubiKey.routineKeyUri' "$inventory_dir/manifest.json" | grep -Fx 'pkcs11:token=YubiKey%20PIV;id=%02;type=private'

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

      write_inventory_manifest() {
        local inventory_dir="$1"
        local inventory_serial="$2"
        local verified_pub_sha256

        verified_pub_sha256="$(sha256sum "$inventory_dir/root-ca.pub.verified.pem" | cut -d' ' -f1)"

        jq -n \
          --arg rootId "$(printf '%s' "$(certificate_fingerprint "$inventory_dir/root-ca.cert.pem")" | tr -d ':' | tr '[:upper:]' '[:lower:]')" \
          --arg serial "$inventory_serial" \
          --arg slot "9c" \
          --arg routineKeyUri "pkcs11:token=YubiKey%20PIV;id=%02;type=private" \
          --arg certificatePath "root-ca.cert.pem" \
          --arg subject "$(certificate_subject "$inventory_dir/root-ca.cert.pem")" \
          --arg certificateSerial "$(certificate_serial "$inventory_dir/root-ca.cert.pem")" \
          --arg certificateFingerprint "$(certificate_fingerprint "$inventory_dir/root-ca.cert.pem")" \
          --arg notBefore "$(certificate_not_before "$inventory_dir/root-ca.cert.pem")" \
          --arg notAfter "$(certificate_not_after "$inventory_dir/root-ca.cert.pem")" \
          --arg verifiedPublicKeyPath "root-ca.pub.verified.pem" \
          --arg verifiedPublicKeySha256 "$verified_pub_sha256" \
          --arg attestationPath "root-ca.attestation.cert.pem" \
          --arg attestationFingerprint "$(certificate_fingerprint "$inventory_dir/root-ca.attestation.cert.pem")" \
          '{
            schemaVersion: 1,
            contractKind: "root-ca-inventory",
            rootId: $rootId,
            source: {
              command: "init-root-yubikey",
              profileKind: "root-yubikey-initialization"
            },
            yubiKey: {
              serial: $serial,
              slot: $slot,
              routineKeyUri: $routineKeyUri
            },
            certificate: {
              path: $certificatePath,
              subject: $subject,
              serial: $certificateSerial,
              sha256Fingerprint: $certificateFingerprint,
              notBefore: $notBefore,
              notAfter: $notAfter
            },
            verifiedPublicKey: {
              path: $verifiedPublicKeyPath,
              sha256: $verifiedPublicKeySha256
            },
            attestation: {
              path: $attestationPath,
              sha256Fingerprint: $attestationFingerprint
            },
            metadata: {
              path: "root-ca.metadata.json",
              profile: "root-ca-yubikey-initialized"
            },
            ceremony: {
              summaryPath: "root-yubikey-init-summary.json"
            }
          }' > "$inventory_dir/manifest.json"
      }

      verify_root_identity() {
        local inventory_dir="$1"
        local token_cert="$2"
        local token_pub="$3"
        local expected_fingerprint
        local actual_fingerprint
        local expected_pub_sha256
        local actual_pub_sha256

        expected_fingerprint="$(jq -r '.certificate.sha256Fingerprint' "$inventory_dir/manifest.json")"
        actual_fingerprint="$(certificate_fingerprint "$token_cert")"
        [ "$expected_fingerprint" = "$actual_fingerprint" ] || return 1

        expected_pub_sha256="$(sha256sum "$inventory_dir/root-ca.pub.verified.pem" | cut -d' ' -f1)"
        actual_pub_sha256="$(sha256sum "$token_pub" | cut -d' ' -f1)"
        [ "$expected_pub_sha256" = "$actual_pub_sha256" ] || return 1
      }

      inventory_dir="$workdir/inventory"
      token_good_dir="$workdir/token-good"
      token_bad_dir="$workdir/token-bad"
      root_fixture="$workdir/root"
      bad_fixture="$workdir/bad-root"
      attestation_fixture="$workdir/attestation"

      mkdir -p "$inventory_dir" "$token_good_dir" "$token_bad_dir"
      generate_self_signed_ca "$root_fixture" "root-ca" "Pseudo Design Workflow Root CA" 9001 7300 1 ec-p384
      generate_self_signed_ca "$bad_fixture" "replacement-root-ca" "Pseudo Design Replacement Root CA" 9002 7300 1 ec-p384
      generate_self_signed_ca "$attestation_fixture" "root-attestation" "Pseudo Design Root Attestation" 7001 3650 0 ec-p384

      cp "$root_fixture/root-ca.cert.pem" "$inventory_dir/root-ca.cert.pem"
      openssl pkey -in "$root_fixture/root-ca.key.pem" -pubout -outform pem > "$inventory_dir/root-ca.pub.verified.pem"
      cp "$attestation_fixture/root-attestation.cert.pem" "$inventory_dir/root-ca.attestation.cert.pem"
      write_certificate_metadata "$inventory_dir/root-ca.cert.pem" "$inventory_dir/root-ca.metadata.json" "root-ca-yubikey-initialized"
      jq -n \
        --arg fingerprint "$(certificate_fingerprint "$inventory_dir/root-ca.cert.pem")" \
        --arg attestationFingerprint "$(certificate_fingerprint "$inventory_dir/root-ca.attestation.cert.pem")" \
        '{
          schemaVersion: 1,
          command: "init-root-yubikey",
          certificate: {
            sha256Fingerprint: $fingerprint
          },
          attestation: {
            sha256Fingerprint: $attestationFingerprint
          }
        }' > "$inventory_dir/root-yubikey-init-summary.json"
      printf '%s\n' 'pkcs11:token=YubiKey%20PIV;id=%02;type=private' > "$inventory_dir/root-key-uri.txt"
      write_inventory_manifest "$inventory_dir" "42424242"

      cp "$inventory_dir/root-ca.cert.pem" "$token_good_dir/token.cert.pem"
      cp "$inventory_dir/root-ca.pub.verified.pem" "$token_good_dir/token.pub.pem"

      if ! verify_root_identity "$inventory_dir" "$token_good_dir/token.cert.pem" "$token_good_dir/token.pub.pem"; then
        printf '%s\n' "[e2e-root-yubikey-identity-verification] expected matching certificate and public key to verify" >&2
        exit 1
      fi

      cp "$bad_fixture/replacement-root-ca.cert.pem" "$token_bad_dir/token.cert.pem"
      openssl pkey -in "$bad_fixture/replacement-root-ca.key.pem" -pubout -outform pem > "$token_bad_dir/token.pub.pem"
      if verify_root_identity "$inventory_dir" "$token_bad_dir/token.cert.pem" "$token_bad_dir/token.pub.pem"; then
        printf '%s\n' "[e2e-root-yubikey-identity-verification] expected mismatched certificate and public key to fail verification" >&2
        exit 1
      fi

      write_inventory_manifest "$inventory_dir" "99999999"
      if ! verify_root_identity "$inventory_dir" "$token_good_dir/token.cert.pem" "$token_good_dir/token.pub.pem"; then
        printf '%s\n' "[e2e-root-yubikey-identity-verification] expected serial-only changes to remain audit-only metadata" >&2
        exit 1
      fi

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
