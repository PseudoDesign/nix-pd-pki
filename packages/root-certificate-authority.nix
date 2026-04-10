{ pkgs, definitions ? import ./definitions.nix }:
let
  common = import ./common.nix { inherit pkgs definitions; };
  role = common.roleById "root-certificate-authority";
in
common.mkRolePackage {
  inherit role;
  nativeBuildInputs = [
    pkgs.openssl
    pkgs.jq
  ];
  buildScript = ''
    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    create_step="$out/steps/create-root-ca"
    create_artifacts="$create_step/artifacts"
    create_private="$workdir/create-root-ca"
    generate_self_signed_ca "$create_private" "root-ca" "Pseudo Design Test Root CA" 1001 3650 1
    cp "$create_private/root-ca.csr.pem" "$create_artifacts/root-ca.csr.pem"
    cp "$create_private/root-ca.cert.pem" "$create_artifacts/root-ca.cert.pem"
    write_certificate_metadata "$create_artifacts/root-ca.cert.pem" "$create_artifacts/root-ca.metadata.json" "root-ca"
    write_status "$create_step" "Generated a dummy self-signed root CA certificate and CSR for automated checks without exporting the signer key."

    rotate_step="$out/steps/rotate-root-ca"
    rotate_artifacts="$rotate_step/artifacts"
    rotate_private="$workdir/rotate-root-ca"
    generate_self_signed_ca "$rotate_private" "replacement-root-ca" "Pseudo Design Test Root CA Rotated" 1002 3650 1
    cp "$rotate_private/replacement-root-ca.csr.pem" "$rotate_artifacts/replacement-root-ca.csr.pem"
    cp "$rotate_private/replacement-root-ca.cert.pem" "$rotate_artifacts/replacement-root-ca.cert.pem"
    write_certificate_metadata "$rotate_artifacts/replacement-root-ca.cert.pem" "$rotate_artifacts/replacement-root-ca.metadata.json" "root-ca-rotation"
    jq -n \
      --arg retiredSerial "$(certificate_serial "$create_artifacts/root-ca.cert.pem")" \
      --arg replacementSerial "$(certificate_serial "$rotate_artifacts/replacement-root-ca.cert.pem")" \
      --arg retiredFingerprint "$(certificate_fingerprint "$create_artifacts/root-ca.cert.pem")" \
      --arg replacementFingerprint "$(certificate_fingerprint "$rotate_artifacts/replacement-root-ca.cert.pem")" \
      '{
        retiredSerial: $retiredSerial,
        replacementSerial: $replacementSerial,
        retiredFingerprint: $retiredFingerprint,
        replacementFingerprint: $replacementFingerprint,
        reason: "scheduled-rotation"
      }' > "$rotate_artifacts/retirement-record.json"
    write_status "$rotate_step" "Generated replacement dummy root CA public artifacts and a retirement record without exporting the replacement signer key."

    sign_step="$out/steps/sign-intermediate-ca-certificate"
    sign_artifacts="$sign_step/artifacts"
    sign_private="$workdir/sign-intermediate-ca"
    generate_signed_ca \
      "$sign_private" \
      "intermediate-ca" \
      "Pseudo Design Test Intermediate CA" \
      2001 \
      1825 \
      0 \
      "$create_private/root-ca.key.pem" \
      "$create_private/root-ca.cert.pem"
    cp "$sign_private/intermediate-ca.csr.pem" "$sign_artifacts/intermediate-ca.csr.pem"
    cp "$sign_private/intermediate-ca.cert.pem" "$sign_artifacts/intermediate-ca.cert.pem"
    cp "$sign_private/chain.pem" "$sign_artifacts/chain.pem"
    write_certificate_metadata "$sign_artifacts/intermediate-ca.cert.pem" "$sign_artifacts/issuance-metadata.json" "intermediate-ca"
    write_status "$sign_step" "Signed a representative intermediate CA certificate with the dummy root CA while keeping the root signer key outside the store output."

    revoke_step="$out/steps/revoke-intermediate-ca-certificate"
    revoke_artifacts="$revoke_step/artifacts"
    jq -n \
      --arg serial "$(certificate_serial "$sign_artifacts/intermediate-ca.cert.pem")" \
      --arg subject "$(certificate_subject "$sign_artifacts/intermediate-ca.cert.pem")" \
      --arg issuer "$(certificate_issuer "$sign_artifacts/intermediate-ca.cert.pem")" \
      --arg reason "cessationOfOperation" \
      --arg effectiveTime "2026-04-09T00:00:00Z" \
      '{
        serial: $serial,
        subject: $subject,
        issuer: $issuer,
        reason: $reason,
        effectiveTime: $effectiveTime
      }' > "$revoke_artifacts/revocation-record.json"
    jq -n \
      --arg revokedSerial "$(certificate_serial "$sign_artifacts/intermediate-ca.cert.pem")" \
      '{ revokedSerials: [ $revokedSerial ], format: "json-simulation" }' \
      > "$revoke_artifacts/revocation-status.json"
    write_status "$revoke_step" "Recorded representative revocation metadata for the intermediate CA."

    publish_step="$out/steps/publish-root-trust-artifacts"
    publish_artifacts="$publish_step/artifacts"
    mkdir -p "$publish_artifacts/trust-bundle"
    cp "$create_artifacts/root-ca.cert.pem" "$publish_artifacts/trust-bundle/root-ca.cert.pem"
    cp "$sign_artifacts/intermediate-ca.cert.pem" "$publish_artifacts/trust-bundle/intermediate-ca.cert.pem"
    cp "$sign_artifacts/chain.pem" "$publish_artifacts/trust-bundle/chain.pem"
    cp "$revoke_artifacts/revocation-record.json" "$publish_artifacts/trust-bundle/revocation-record.json"
    jq -n \
      --arg rootFingerprint "$(certificate_fingerprint "$create_artifacts/root-ca.cert.pem")" \
      --arg intermediateFingerprint "$(certificate_fingerprint "$sign_artifacts/intermediate-ca.cert.pem")" \
      '{
        publishedArtifacts: [
          "root-ca.cert.pem",
          "intermediate-ca.cert.pem",
          "chain.pem",
          "revocation-record.json"
        ],
        rootFingerprint: $rootFingerprint,
        intermediateFingerprint: $intermediateFingerprint
      }' > "$publish_artifacts/publication-manifest.json"
    write_status "$publish_step" "Published a deterministic root trust bundle for downstream role checks."
  '';
}
