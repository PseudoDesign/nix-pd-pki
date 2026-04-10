{
  pkgs,
  definitions ? import ./definitions.nix,
  rootCertificateAuthority ? import ./root-certificate-authority.nix {
    inherit pkgs definitions;
  },
}:
let
  common = import ./common.nix { inherit pkgs definitions; };
  role = common.roleById "intermediate-signing-authority";
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
    root_key="$root_private/root-ca.key.pem"
    root_cert="$root_private/root-ca.cert.pem"
    generate_self_signed_ca "$root_private" "root-ca" "Pseudo Design Test Root CA" 2000 3650 1

    create_step="$out/steps/create-intermediate-ca"
    create_artifacts="$create_step/artifacts"
    create_private="$workdir/create-intermediate-ca"
    generate_signed_ca \
      "$create_private" \
      "intermediate-ca" \
      "Pseudo Design Intermediate Signing Authority" \
      2101 \
      1825 \
      0 \
      "$root_key" \
      "$root_cert"
    cp "$create_private/intermediate-ca.csr.pem" "$create_artifacts/intermediate-ca.csr.pem"
    cp "$create_private/intermediate-ca.cert.pem" "$create_artifacts/intermediate-ca.cert.pem"
    cp "$create_private/chain.pem" "$create_artifacts/chain.pem"
    write_certificate_metadata "$create_artifacts/intermediate-ca.cert.pem" "$create_artifacts/signer-metadata.json" "intermediate-ca"
    write_status "$create_step" "Generated an intermediate CA and signed it with a build-local dummy root certificate without exporting the intermediate signer key."

    rotate_step="$out/steps/rotate-intermediate-ca"
    rotate_artifacts="$rotate_step/artifacts"
    rotate_private="$workdir/rotate-intermediate-ca"
    generate_signed_ca \
      "$rotate_private" \
      "replacement-intermediate-ca" \
      "Pseudo Design Intermediate Signing Authority Rotated" \
      2102 \
      1825 \
      0 \
      "$root_key" \
      "$root_cert"
    cp "$rotate_private/replacement-intermediate-ca.csr.pem" "$rotate_artifacts/replacement-intermediate-ca.csr.pem"
    cp "$rotate_private/replacement-intermediate-ca.cert.pem" "$rotate_artifacts/replacement-intermediate-ca.cert.pem"
    cp "$rotate_private/chain.pem" "$rotate_artifacts/replacement-chain.pem"
    jq -n \
      --arg retiredSerial "$(certificate_serial "$create_artifacts/intermediate-ca.cert.pem")" \
      --arg replacementSerial "$(certificate_serial "$rotate_artifacts/replacement-intermediate-ca.cert.pem")" \
      '{
        retiredSerial: $retiredSerial,
        replacementSerial: $replacementSerial,
        reason: "scheduled-rotation"
      }' > "$rotate_artifacts/retirement-record.json"
    write_status "$rotate_step" "Provisioned a replacement intermediate CA public bundle and recorded retirement metadata without exporting the replacement key."

    server_step="$out/steps/sign-openvpn-server-leaf-certificate"
    server_artifacts="$server_step/artifacts"
    server_sans="DNS:vpn.pseudo.test,DNS:openvpn.pseudo.test,IP:127.0.0.1"
    server_private="$workdir/sign-openvpn-server-leaf-certificate"
    generate_tls_request "$server_private" "server" "vpn.pseudo.test" "$server_sans" "serverAuth"
    sign_tls_certificate \
      "$server_private" \
      "server" \
      "$server_private/server.csr.pem" \
      "$server_sans" \
      "serverAuth" \
      3101 \
      825 \
      "$create_private/intermediate-ca.key.pem" \
      "$create_private/intermediate-ca.cert.pem" \
      "$root_cert"
    cp "$server_private/server.csr.pem" "$server_artifacts/server.csr.pem"
    cp "$server_private/server.cert.pem" "$server_artifacts/server.cert.pem"
    cp "$server_private/chain.pem" "$server_artifacts/chain.pem"
    write_certificate_metadata "$server_artifacts/server.cert.pem" "$server_artifacts/issuance-metadata.json" "openvpn-server"
    write_status "$server_step" "Signed a representative OpenVPN server certificate with the intermediate CA while keeping private key material outside the exported artifacts."

    client_step="$out/steps/sign-openvpn-client-leaf-certificate"
    client_artifacts="$client_step/artifacts"
    client_sans="DNS:client-01.pseudo.test"
    client_private="$workdir/sign-openvpn-client-leaf-certificate"
    generate_tls_request "$client_private" "client" "client-01.pseudo.test" "$client_sans" "clientAuth"
    sign_tls_certificate \
      "$client_private" \
      "client" \
      "$client_private/client.csr.pem" \
      "$client_sans" \
      "clientAuth" \
      3201 \
      825 \
      "$create_private/intermediate-ca.key.pem" \
      "$create_private/intermediate-ca.cert.pem" \
      "$root_cert"
    cp "$client_private/client.csr.pem" "$client_artifacts/client.csr.pem"
    cp "$client_private/client.cert.pem" "$client_artifacts/client.cert.pem"
    cp "$client_private/chain.pem" "$client_artifacts/chain.pem"
    write_certificate_metadata "$client_artifacts/client.cert.pem" "$client_artifacts/issuance-metadata.json" "openvpn-client"
    write_status "$client_step" "Signed a representative OpenVPN client certificate with the intermediate CA while keeping private key material outside the exported artifacts."

    revoke_step="$out/steps/revoke-leaf-certificate"
    revoke_artifacts="$revoke_step/artifacts"
    jq -n \
      --arg serverSerial "$(certificate_serial "$server_artifacts/server.cert.pem")" \
      --arg clientSerial "$(certificate_serial "$client_artifacts/client.cert.pem")" \
      '{
        serverSerial: $serverSerial,
        clientSerial: $clientSerial,
        reason: "superseded",
        effectiveTime: "2026-04-09T00:00:00Z"
      }' > "$revoke_artifacts/revocation-record.json"
    jq -n \
      --arg serverSubject "$(certificate_subject "$server_artifacts/server.cert.pem")" \
      --arg clientSubject "$(certificate_subject "$client_artifacts/client.cert.pem")" \
      '{
        revokedCertificates: [
          { subject: $serverSubject, role: "server" },
          { subject: $clientSubject, role: "client" }
        ]
      }' > "$revoke_artifacts/revoked-certificates.json"
    write_status "$revoke_step" "Recorded representative revocation metadata for server and client leaves."

    publish_step="$out/steps/publish-intermediate-trust-artifacts"
    publish_artifacts="$publish_step/artifacts"
    mkdir -p "$publish_artifacts/trust-bundle"
    cp "$create_artifacts/intermediate-ca.cert.pem" "$publish_artifacts/trust-bundle/intermediate-ca.cert.pem"
    cp "$create_artifacts/chain.pem" "$publish_artifacts/trust-bundle/chain.pem"
    cp "$revoke_artifacts/revocation-record.json" "$publish_artifacts/trust-bundle/revocation-record.json"
    cp "$server_artifacts/server.cert.pem" "$publish_artifacts/trust-bundle/server.cert.pem"
    cp "$client_artifacts/client.cert.pem" "$publish_artifacts/trust-bundle/client.cert.pem"
    jq -n \
      --arg intermediateSerial "$(certificate_serial "$create_artifacts/intermediate-ca.cert.pem")" \
      --arg serverSerial "$(certificate_serial "$server_artifacts/server.cert.pem")" \
      --arg clientSerial "$(certificate_serial "$client_artifacts/client.cert.pem")" \
      '{
        intermediateSerial: $intermediateSerial,
        publishedLeafSerials: [ $serverSerial, $clientSerial ]
      }' > "$publish_artifacts/publication-manifest.json"
    write_status "$publish_step" "Published a deterministic intermediate trust bundle for downstream leaf-role checks."
  '';
}
