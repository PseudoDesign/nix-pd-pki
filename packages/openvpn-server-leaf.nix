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
  role = common.roleById "openvpn-server-leaf";
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
    generate_self_signed_ca "$root_private" "root-ca" "Pseudo Design OpenVPN Server Fixture Root CA" 4000 3650 1
    generate_signed_ca \
      "$intermediate_private" \
      "intermediate-ca" \
      "Pseudo Design OpenVPN Server Fixture Intermediate CA" \
      4001 \
      1825 \
      0 \
      "$root_private/root-ca.key.pem" \
      "$root_cert"

    request_step="$out/steps/create-openvpn-server-leaf-request"
    request_artifacts="$request_step/artifacts"
    server_sans="DNS:vpn.pseudo.test,DNS:openvpn.pseudo.test,IP:127.0.0.1"
    request_private="$workdir/create-openvpn-server-leaf-request"
    generate_tls_request "$request_private" "server" "vpn.pseudo.test" "$server_sans" "serverAuth"
    cp "$request_private/server.csr.pem" "$request_artifacts/server.csr.pem"
    jq -n \
      --arg commonName "vpn.pseudo.test" \
      --argjson sans '["DNS:vpn.pseudo.test", "DNS:openvpn.pseudo.test", "IP:127.0.0.1"]' \
      '{
        commonName: $commonName,
        sans: $sans
      }' > "$request_artifacts/san-manifest.json"
    jq -n \
      --arg csrFile "server.csr.pem" \
      --arg requestedProfile "serverAuth" \
      '{
        csrFile: $csrFile,
        requestedProfile: $requestedProfile
      }' > "$request_artifacts/issuance-request.json"
    write_status "$request_step" "Generated a representative OpenVPN server CSR and SAN manifest without exporting the private key."

    bundle_step="$out/steps/package-openvpn-server-deployment-bundle"
    bundle_artifacts="$bundle_step/artifacts"
    bundle_dir="$bundle_artifacts/deployment-bundle"
    mkdir -p "$bundle_dir"
    bundle_private="$workdir/package-openvpn-server-deployment-bundle"
    sign_tls_certificate \
      "$bundle_private" \
      "server" \
      "$request_private/server.csr.pem" \
      "$server_sans" \
      "serverAuth" \
      4101 \
      825 \
      "$intermediate_key" \
      "$intermediate_cert" \
      "$root_cert"
    cp "$bundle_private/server.cert.pem" "$bundle_dir/server.cert.pem"
    cp "$bundle_private/chain.pem" "$bundle_dir/chain.pem"
    jq -n \
      --arg currentSerial "$(certificate_serial "$bundle_private/server.cert.pem")" \
      '{
        revokedSerials: [],
        currentSerial: $currentSerial,
        status: "no-active-revocations"
      }' > "$bundle_dir/revocation-record.json"
    jq -n \
      --arg serial "$(certificate_serial "$bundle_dir/server.cert.pem")" \
      --arg subject "$(certificate_subject "$bundle_dir/server.cert.pem")" \
      --arg sanSet "$server_sans" \
      --arg runtimeKeyPath "/var/lib/pd-pki/openvpn-server-leaf/server.key.pem" \
      '{
        serial: $serial,
        subject: $subject,
        sanSet: $sanSet,
        runtimeKeyPath: $runtimeKeyPath
      }' > "$bundle_artifacts/bundle-manifest.json"
    write_status "$bundle_step" "Signed the representative server CSR and assembled a public deployment bundle that references a runtime-managed key path."

    rotate_step="$out/steps/rotate-openvpn-server-certificate"
    rotate_artifacts="$rotate_step/artifacts"
    replacement_sans="DNS:vpn-rotated.pseudo.test,DNS:openvpn.pseudo.test,IP:127.0.0.1"
    rotate_private="$workdir/rotate-openvpn-server-certificate"
    generate_tls_request "$rotate_private" "replacement-server" "vpn-rotated.pseudo.test" "$replacement_sans" "serverAuth"
    sign_tls_certificate \
      "$rotate_private" \
      "replacement-server" \
      "$rotate_private/replacement-server.csr.pem" \
      "$replacement_sans" \
      "serverAuth" \
      4102 \
      825 \
      "$intermediate_key" \
      "$intermediate_cert" \
      "$root_cert"
    cp "$rotate_private/replacement-server.csr.pem" "$rotate_artifacts/replacement-server.csr.pem"
    cp "$rotate_private/replacement-server.cert.pem" "$rotate_artifacts/replacement-server.cert.pem"
    cp "$rotate_private/chain.pem" "$rotate_artifacts/replacement-chain.pem"
    jq -n \
      --arg retiredSerial "$(certificate_serial "$bundle_dir/server.cert.pem")" \
      --arg replacementSerial "$(certificate_serial "$rotate_artifacts/replacement-server.cert.pem")" \
      '{
        retiredSerial: $retiredSerial,
        replacementSerial: $replacementSerial,
        reason: "scheduled-rotation"
      }' > "$rotate_artifacts/retirement-record.json"
    write_status "$rotate_step" "Issued a replacement OpenVPN server certificate and recorded rotation metadata without exporting the replacement private key."

    trust_step="$out/steps/consume-server-trust-updates"
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
    write_status "$trust_step" "Staged updated trust material for server-side validation."
  '';
}
