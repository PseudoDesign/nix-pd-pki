{
  pkgs,
  definitions ? import ./definitions.nix,
  rootCertificateAuthority ? import ./root-certificate-authority.nix {
    inherit pkgs definitions;
  },
  intermediateSigningAuthority ? import ./intermediate-signing-authority.nix {
    inherit pkgs definitions rootCertificateAuthority;
  },
}:
let
  common = import ./common.nix { inherit pkgs definitions; };
  role = common.roleById "openvpn-client-leaf";
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

    root_private="$workdir/runtime-root"
    intermediate_private="$workdir/runtime-intermediate"
    root_cert="$root_private/root-ca.cert.pem"
    intermediate_key="$intermediate_private/intermediate-ca.key.pem"
    intermediate_cert="$intermediate_private/intermediate-ca.cert.pem"
    generate_self_signed_ca "$root_private" "root-ca" "Pseudo Design OpenVPN Client Fixture Root CA" 5000 3650 1
    generate_signed_ca \
      "$intermediate_private" \
      "intermediate-ca" \
      "Pseudo Design OpenVPN Client Fixture Intermediate CA" \
      5001 \
      1825 \
      0 \
      "$root_private/root-ca.key.pem" \
      "$root_cert"

    request_step="$out/steps/create-openvpn-client-leaf-request"
    request_artifacts="$request_step/artifacts"
    client_sans="DNS:client-01.pseudo.test"
    request_private="$workdir/create-openvpn-client-leaf-request"
    generate_tls_request "$request_private" "client" "client-01.pseudo.test" "$client_sans" "clientAuth"
    cp "$request_private/client.csr.pem" "$request_artifacts/client.csr.pem"
    jq -n \
      --arg identity "client-01.pseudo.test" \
      --arg enrollment "automated-test" \
      '{
        identity: $identity,
        enrollment: $enrollment
      }' > "$request_artifacts/identity-manifest.json"
    jq -n \
      --arg csrFile "client.csr.pem" \
      --arg requestedProfile "clientAuth" \
      '{
        csrFile: $csrFile,
        requestedProfile: $requestedProfile
      }' > "$request_artifacts/issuance-request.json"
    write_status "$request_step" "Generated a representative OpenVPN client CSR and identity manifest without exporting the private key."

    bundle_step="$out/steps/package-openvpn-client-credential-bundle"
    bundle_artifacts="$bundle_step/artifacts"
    bundle_dir="$bundle_artifacts/credential-bundle"
    mkdir -p "$bundle_dir"
    bundle_private="$workdir/package-openvpn-client-credential-bundle"
    sign_tls_certificate \
      "$bundle_private" \
      "client" \
      "$request_private/client.csr.pem" \
      "$client_sans" \
      "clientAuth" \
      5101 \
      825 \
      "$intermediate_key" \
      "$intermediate_cert" \
      "$root_cert"
    cp "$bundle_private/client.cert.pem" "$bundle_dir/client.cert.pem"
    cp "$bundle_private/chain.pem" "$bundle_dir/chain.pem"
    jq -n \
      --arg currentSerial "$(certificate_serial "$bundle_private/client.cert.pem")" \
      '{
        revokedSerials: [],
        currentSerial: $currentSerial,
        status: "no-active-revocations"
      }' > "$bundle_dir/revocation-record.json"
    jq -n \
      --arg serial "$(certificate_serial "$bundle_dir/client.cert.pem")" \
      --arg subject "$(certificate_subject "$bundle_dir/client.cert.pem")" \
      --arg runtimeKeyPath "/var/lib/pd-pki/openvpn-client-leaf/client.key.pem" \
      '{
        serial: $serial,
        subject: $subject,
        distribution: "credential-bundle",
        runtimeKeyPath: $runtimeKeyPath
      }' > "$bundle_artifacts/bundle-manifest.json"
    write_status "$bundle_step" "Signed the representative client CSR and assembled a public client credential bundle that references a runtime-managed key path."

    rotate_step="$out/steps/rotate-openvpn-client-certificate"
    rotate_artifacts="$rotate_step/artifacts"
    replacement_sans="DNS:client-01-rotated.pseudo.test"
    rotate_private="$workdir/rotate-openvpn-client-certificate"
    generate_tls_request "$rotate_private" "replacement-client" "client-01-rotated.pseudo.test" "$replacement_sans" "clientAuth"
    sign_tls_certificate \
      "$rotate_private" \
      "replacement-client" \
      "$rotate_private/replacement-client.csr.pem" \
      "$replacement_sans" \
      "clientAuth" \
      5102 \
      825 \
      "$intermediate_key" \
      "$intermediate_cert" \
      "$root_cert"
    cp "$rotate_private/replacement-client.csr.pem" "$rotate_artifacts/replacement-client.csr.pem"
    cp "$rotate_private/replacement-client.cert.pem" "$rotate_artifacts/replacement-client.cert.pem"
    cp "$rotate_private/chain.pem" "$rotate_artifacts/replacement-chain.pem"
    jq -n \
      --arg retiredSerial "$(certificate_serial "$bundle_dir/client.cert.pem")" \
      --arg replacementSerial "$(certificate_serial "$rotate_artifacts/replacement-client.cert.pem")" \
      '{
        retiredSerial: $retiredSerial,
        replacementSerial: $replacementSerial,
        reason: "scheduled-rotation"
      }' > "$rotate_artifacts/retirement-record.json"
    write_status "$rotate_step" "Issued a replacement OpenVPN client certificate and recorded rotation metadata without exporting the replacement private key."

    trust_step="$out/steps/consume-client-trust-updates"
    trust_artifacts="$trust_step/artifacts"
    mkdir -p "$trust_artifacts/staged-trust"
    cp "$root_cert" "$trust_artifacts/staged-trust/root-ca.cert.pem"
    cp "$intermediate_cert" "$trust_artifacts/staged-trust/intermediate-ca.cert.pem"
    cp "$bundle_dir/revocation-record.json" "$trust_artifacts/staged-trust/revocation-record.json"
    jq -n \
      --arg rootFingerprint "$(certificate_fingerprint "$root_cert")" \
      --arg intermediateSerial "$(certificate_serial "$intermediate_cert")" \
      '{
        rootFingerprint: $rootFingerprint,
        intermediateSerial: $intermediateSerial,
        activation: "staged"
      }' > "$trust_artifacts/trust-update-status.json"
    write_status "$trust_step" "Staged updated trust material for client-side validation."
  '';
}
