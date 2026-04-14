{ pkgs, packages }:
pkgs.runCommand "pd-pki-signing-tools-pkcs11-check"
  {
    nativeBuildInputs = [
      packages.pd-pki-signing-tools
      pkgs.jq
      pkgs.libp11
      pkgs.opensc
      pkgs.openssl
      pkgs.softhsm
    ];
  }
  ''
    set -euo pipefail

    printf '%s\n' "[signing-tools-pkcs11] starting PKCS#11 signing-tools check"

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    export SOFTHSM2_CONF="$workdir/softhsm2.conf"
    cat > "$SOFTHSM2_CONF" <<EOF
directories.tokendir = $workdir/tokens
objectstore.backend = file
slots.removable = false
EOF
    mkdir -p "$workdir/tokens"

    module_path="${pkgs.softhsm}/lib/softhsm/libsofthsm2.so"
    pin_file="$workdir/pin.txt"
    printf '%s' "123456" > "$pin_file"

    softhsm2-util --init-token --free --label signer-token --so-pin 0000 --pin "$(tr -d '\n' < "$pin_file")" >/dev/null
    pkcs11-tool --module "$module_path" --token-label signer-token --login --pin "$(tr -d '\n' < "$pin_file")" --keypairgen --key-type rsa:3072 --id 01 --label issuer >/dev/null

    export OPENSSL_ENGINES="${pkgs.libp11}/lib/engines"
    export PKCS11_MODULE_PATH="$module_path"
    issuer_key_uri="pkcs11:token=signer-token;id=%01;type=private;pin-source=file:$pin_file"

    openssl req -new -x509 -days 3650 -subj /CN=SoftHSM-Test-Issuer -engine pkcs11 -keyform ENGINE -key "$issuer_key_uri" -out "$workdir/issuer.cert.pem" >/dev/null 2>&1

    pkcs11-tool --module "$module_path" --token-label signer-token --login --pin "$(tr -d '\n' < "$pin_file")" --keypairgen --key-type EC:secp384r1 --id 02 --label ec-root >/dev/null
    ec_root_key_uri="$(
      pkcs11-tool --module "$module_path" --login --pin "$(tr -d '\n' < "$pin_file")" --list-objects --type privkey |
        awk '/^[[:space:]]+uri:/ && /id=%02/ && /type=private/ { sub(/^[[:space:]]+uri:[[:space:]]*/, ""); print; exit }'
    );pin-source=file:$pin_file"

    cat > "$workdir/root.ext" <<EOF
[ v3_root_ca ]
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

    openssl x509 -new \
      -engine pkcs11 \
      -keyform ENGINE \
      -key "$ec_root_key_uri" \
      -subj /CN=SoftHSM-Test-EC-Root \
      -days 3650 \
      -sha384 \
      -extfile "$workdir/root.ext" \
      -extensions v3_root_ca \
      -out "$workdir/ec-root.cert.pem" >/dev/null 2>&1
    openssl verify -CAfile "$workdir/ec-root.cert.pem" "$workdir/ec-root.cert.pem" >/dev/null

    cat > "$workdir/server.req.conf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
req_extensions = req_ext

[ dn ]
CN = vpn.example.test

[ req_ext ]
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:vpn.example.test,IP:127.0.0.1
EOF

    openssl req -new -newkey rsa:3072 -nodes -keyout "$workdir/server.key.pem" -config "$workdir/server.req.conf" -out "$workdir/server.csr.pem" >/dev/null 2>&1

    mkdir -p "$workdir/request" "$workdir/signed" "$workdir/state" "$workdir/crl"
    cp "$workdir/server.csr.pem" "$workdir/request/server.csr.pem"

    jq -n \
      --arg schemaVersion "1" \
      --arg roleId "openvpn-server-leaf" \
      --arg requestKind "tls-leaf" \
      --arg basename "server" \
      --arg commonName "vpn.example.test" \
      --argjson subjectAltNames '["DNS:vpn.example.test", "IP:127.0.0.1"]' \
      --arg requestedProfile "serverAuth" \
      --arg requestedDays "30" \
      --arg csrFile "server.csr.pem" \
      '{
        schemaVersion: ($schemaVersion | tonumber),
        roleId: $roleId,
        requestKind: $requestKind,
        basename: $basename,
        commonName: $commonName,
        subjectAltNames: $subjectAltNames,
        requestedProfile: $requestedProfile,
        requestedDays: ($requestedDays | tonumber),
        csrFile: $csrFile
      }' > "$workdir/request/request.json"

    jq -n '
      {
        schemaVersion: 1,
        roles: {
          "openvpn-server-leaf": {
            defaultDays: 30,
            maxDays: 30,
            allowedKeyAlgorithms: ["RSA"],
            minimumRsaBits: 3072,
            allowedProfiles: ["serverAuth"],
            commonNamePatterns: ["^[A-Za-z0-9.-]+$"],
            subjectAltNamePatterns: [
              "^DNS:[A-Za-z0-9.-]+$",
              "^IP:[0-9.]+$"
            ]
          }
        }
      }
    ' > "$workdir/policy.json"

    pd-pki-signing-tools sign-request \
      --request-dir "$workdir/request" \
      --out-dir "$workdir/signed" \
      --issuer-key-uri "pkcs11:token=signer-token;id=%01;type=private" \
      --pkcs11-module "$module_path" \
      --pkcs11-pin-file "$pin_file" \
      --issuer-cert "$workdir/issuer.cert.pem" \
      --signer-state-dir "$workdir/state" \
      --policy-file "$workdir/policy.json" \
      --approved-by operator-test

    test -f "$workdir/signed/server.cert.pem"
    test -f "$workdir/state/issuances/01/issuance.json"
    openssl verify -CAfile "$workdir/signed/chain.pem" "$workdir/signed/server.cert.pem" >/dev/null

    pd-pki-signing-tools revoke-issued \
      --signer-state-dir "$workdir/state" \
      --serial 1 \
      --reason keyCompromise \
      --revoked-by security-test

    pd-pki-signing-tools generate-crl \
      --signer-state-dir "$workdir/state" \
      --issuer-key-uri "pkcs11:token=signer-token;id=%01;type=private" \
      --pkcs11-module "$module_path" \
      --pkcs11-pin-file "$pin_file" \
      --issuer-cert "$workdir/issuer.cert.pem" \
      --out-dir "$workdir/crl" \
      --days 30

    test -f "$workdir/crl/crl.pem"
    test "$(jq -r '.crlNumber' "$workdir/crl/metadata.json")" = "01"
    test "$(jq -r '.revokedSerials[0]' "$workdir/crl/metadata.json")" = "01"
    openssl crl -in "$workdir/crl/crl.pem" -noout >/dev/null

    printf '%s\n' "[signing-tools-pkcs11] PKCS#11 signing-tools check passed"
    touch "$out"
  ''
