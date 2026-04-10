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
    root_artifacts="${rootCertificateAuthority}/steps/create-root-ca/artifacts"
    intermediate_artifacts="${intermediateSigningAuthority}/steps/create-intermediate-ca/artifacts"
    published_trust="${intermediateSigningAuthority}/steps/publish-intermediate-trust-artifacts/artifacts/trust-bundle"

    root_cert="$root_artifacts/root-ca.cert.pem"
    intermediate_key="$intermediate_artifacts/intermediate-ca.key.pem"
    intermediate_cert="$intermediate_artifacts/intermediate-ca.cert.pem"

    request_step="$out/steps/create-openvpn-server-leaf-request"
    request_artifacts="$request_step/artifacts"
    server_sans="DNS:vpn.pseudo.test,DNS:openvpn.pseudo.test,IP:127.0.0.1"
    generate_tls_request "$request_artifacts" "server" "vpn.pseudo.test" "$server_sans" "serverAuth"
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
    write_status "$request_step" "Generated a representative OpenVPN server keypair, CSR, and SAN manifest."

    bundle_step="$out/steps/package-openvpn-server-deployment-bundle"
    bundle_artifacts="$bundle_step/artifacts"
    bundle_dir="$bundle_artifacts/deployment-bundle"
    mkdir -p "$bundle_dir"
    sign_tls_certificate \
      "$bundle_dir" \
      "server" \
      "$request_artifacts/server.csr.pem" \
      "$server_sans" \
      "serverAuth" \
      4101 \
      825 \
      "$intermediate_key" \
      "$intermediate_cert" \
      "$root_cert"
    cp "$request_artifacts/server.key.pem" "$bundle_dir/server.key.pem"
    cp "${intermediateSigningAuthority}/steps/revoke-leaf-certificate/artifacts/revocation-record.json" "$bundle_dir/revocation-record.json"
    jq -n \
      --arg serial "$(certificate_serial "$bundle_dir/server.cert.pem")" \
      --arg subject "$(certificate_subject "$bundle_dir/server.cert.pem")" \
      --arg sanSet "$server_sans" \
      '{
        serial: $serial,
        subject: $subject,
        sanSet: $sanSet
      }' > "$bundle_artifacts/bundle-manifest.json"
    write_status "$bundle_step" "Signed the representative server CSR and assembled a deployment-ready bundle."

    rotate_step="$out/steps/rotate-openvpn-server-certificate"
    rotate_artifacts="$rotate_step/artifacts"
    replacement_sans="DNS:vpn-rotated.pseudo.test,DNS:openvpn.pseudo.test,IP:127.0.0.1"
    generate_tls_request "$rotate_artifacts" "replacement-server" "vpn-rotated.pseudo.test" "$replacement_sans" "serverAuth"
    sign_tls_certificate \
      "$rotate_artifacts" \
      "replacement-server" \
      "$rotate_artifacts/replacement-server.csr.pem" \
      "$replacement_sans" \
      "serverAuth" \
      4102 \
      825 \
      "$intermediate_key" \
      "$intermediate_cert" \
      "$root_cert"
    mv "$rotate_artifacts/chain.pem" "$rotate_artifacts/replacement-chain.pem"
    jq -n \
      --arg retiredSerial "$(certificate_serial "$bundle_dir/server.cert.pem")" \
      --arg replacementSerial "$(certificate_serial "$rotate_artifacts/replacement-server.cert.pem")" \
      '{
        retiredSerial: $retiredSerial,
        replacementSerial: $replacementSerial,
        reason: "scheduled-rotation"
      }' > "$rotate_artifacts/retirement-record.json"
    write_status "$rotate_step" "Issued a replacement OpenVPN server certificate and recorded rotation metadata."

    trust_step="$out/steps/consume-server-trust-updates"
    trust_artifacts="$trust_step/artifacts"
    mkdir -p "$trust_artifacts/staged-trust"
    cp "$root_cert" "$trust_artifacts/staged-trust/root-ca.cert.pem"
    cp "$published_trust/intermediate-ca.cert.pem" "$trust_artifacts/staged-trust/intermediate-ca.cert.pem"
    cp "$published_trust/revocation-record.json" "$trust_artifacts/staged-trust/revocation-record.json"
    jq -n \
      --arg rootFingerprint "$(certificate_fingerprint "$root_cert")" \
      --arg intermediateSerial "$(certificate_serial "$published_trust/intermediate-ca.cert.pem")" \
      '{
        rootFingerprint: $rootFingerprint,
        intermediateSerial: $intermediateSerial,
        activation: "staged"
      }' > "$trust_artifacts/trust-update-status.json"
    write_status "$trust_step" "Staged updated trust material for server-side validation."
  '';
}
