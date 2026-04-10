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
    root_artifacts="${rootCertificateAuthority}/steps/create-root-ca/artifacts"
    intermediate_artifacts="${intermediateSigningAuthority}/steps/create-intermediate-ca/artifacts"
    published_trust="${intermediateSigningAuthority}/steps/publish-intermediate-trust-artifacts/artifacts/trust-bundle"

    root_cert="$root_artifacts/root-ca.cert.pem"
    intermediate_key="$intermediate_artifacts/intermediate-ca.key.pem"
    intermediate_cert="$intermediate_artifacts/intermediate-ca.cert.pem"

    request_step="$out/steps/create-openvpn-client-leaf-request"
    request_artifacts="$request_step/artifacts"
    client_sans="DNS:client-01.pseudo.test"
    generate_tls_request "$request_artifacts" "client" "client-01.pseudo.test" "$client_sans" "clientAuth"
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
    write_status "$request_step" "Generated a representative OpenVPN client keypair, CSR, and identity manifest."

    bundle_step="$out/steps/package-openvpn-client-credential-bundle"
    bundle_artifacts="$bundle_step/artifacts"
    bundle_dir="$bundle_artifacts/credential-bundle"
    mkdir -p "$bundle_dir"
    sign_tls_certificate \
      "$bundle_dir" \
      "client" \
      "$request_artifacts/client.csr.pem" \
      "$client_sans" \
      "clientAuth" \
      5101 \
      825 \
      "$intermediate_key" \
      "$intermediate_cert" \
      "$root_cert"
    cp "$request_artifacts/client.key.pem" "$bundle_dir/client.key.pem"
    cp "${intermediateSigningAuthority}/steps/revoke-leaf-certificate/artifacts/revocation-record.json" "$bundle_dir/revocation-record.json"
    jq -n \
      --arg serial "$(certificate_serial "$bundle_dir/client.cert.pem")" \
      --arg subject "$(certificate_subject "$bundle_dir/client.cert.pem")" \
      '{
        serial: $serial,
        subject: $subject,
        distribution: "credential-bundle"
      }' > "$bundle_artifacts/bundle-manifest.json"
    write_status "$bundle_step" "Signed the representative client CSR and assembled a client credential bundle."

    rotate_step="$out/steps/rotate-openvpn-client-certificate"
    rotate_artifacts="$rotate_step/artifacts"
    replacement_sans="DNS:client-01-rotated.pseudo.test"
    generate_tls_request "$rotate_artifacts" "replacement-client" "client-01-rotated.pseudo.test" "$replacement_sans" "clientAuth"
    sign_tls_certificate \
      "$rotate_artifacts" \
      "replacement-client" \
      "$rotate_artifacts/replacement-client.csr.pem" \
      "$replacement_sans" \
      "clientAuth" \
      5102 \
      825 \
      "$intermediate_key" \
      "$intermediate_cert" \
      "$root_cert"
    mv "$rotate_artifacts/chain.pem" "$rotate_artifacts/replacement-chain.pem"
    jq -n \
      --arg retiredSerial "$(certificate_serial "$bundle_dir/client.cert.pem")" \
      --arg replacementSerial "$(certificate_serial "$rotate_artifacts/replacement-client.cert.pem")" \
      '{
        retiredSerial: $retiredSerial,
        replacementSerial: $replacementSerial,
        reason: "scheduled-rotation"
      }' > "$rotate_artifacts/retirement-record.json"
    write_status "$rotate_step" "Issued a replacement OpenVPN client certificate and recorded rotation metadata."

    trust_step="$out/steps/consume-client-trust-updates"
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
    write_status "$trust_step" "Staged updated trust material for client-side validation."
  '';
}
