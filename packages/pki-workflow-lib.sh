set -euo pipefail

json_string_array() {
  local target="$1"
  shift

  local jq_args=()
  local jq_filter="["
  local index=0
  local item
  for item in "$@"; do
    jq_args+=("--arg" "item${index}" "$item")
    if [ "$index" -gt 0 ]; then
      jq_filter="${jq_filter}, "
    fi
    jq_filter="${jq_filter}"'$item'"${index}"
    index=$((index + 1))
  done
  jq_filter="${jq_filter}]"

  jq -n "${jq_args[@]}" "${jq_filter}" > "$target"
}

write_status() {
  local step_dir="$1"
  local summary="$2"
  local role_id="${PD_PKI_ROLE_ID:-package}"
  local step_id

  step_id="$(basename "$step_dir")"

  printf '%s\n' "[package/${role_id}/${step_id}] ${summary}"

  jq -n \
    --arg status "implemented" \
    --arg summary "$summary" \
    '{
      status: $status,
      summary: $summary
    }' > "${step_dir}/status.json"
}

certificate_subject() {
  local certificate="$1"
  openssl x509 -in "$certificate" -noout -subject | sed 's/^subject=//'
}

certificate_issuer() {
  local certificate="$1"
  openssl x509 -in "$certificate" -noout -issuer | sed 's/^issuer=//'
}

certificate_serial() {
  local certificate="$1"
  openssl x509 -in "$certificate" -noout -serial | cut -d= -f2
}

certificate_fingerprint() {
  local certificate="$1"
  openssl x509 -in "$certificate" -noout -fingerprint -sha256 | cut -d= -f2
}

certificate_not_before() {
  local certificate="$1"
  openssl x509 -in "$certificate" -noout -startdate | cut -d= -f2-
}

certificate_not_after() {
  local certificate="$1"
  openssl x509 -in "$certificate" -noout -enddate | cut -d= -f2-
}

write_certificate_metadata() {
  local certificate="$1"
  local target="$2"
  local profile="$3"

  jq -n \
    --arg profile "$profile" \
    --arg serial "$(certificate_serial "$certificate")" \
    --arg subject "$(certificate_subject "$certificate")" \
    --arg issuer "$(certificate_issuer "$certificate")" \
    --arg notBefore "$(certificate_not_before "$certificate")" \
    --arg notAfter "$(certificate_not_after "$certificate")" \
    --arg sha256Fingerprint "$(certificate_fingerprint "$certificate")" \
    '{
      profile: $profile,
      serial: $serial,
      subject: $subject,
      issuer: $issuer,
      notBefore: $notBefore,
      notAfter: $notAfter,
      sha256Fingerprint: $sha256Fingerprint
    }' > "$target"
}

generate_self_signed_ca() {
  local artifacts_dir="$1"
  local basename="$2"
  local common_name="$3"
  local serial="$4"
  local days="$5"
  local pathlen="$6"

  local key_path="${artifacts_dir}/${basename}.key.pem"
  local csr_path="${artifacts_dir}/${basename}.csr.pem"
  local cert_path="${artifacts_dir}/${basename}.cert.pem"
  local ext_path="${artifacts_dir}/${basename}.ext"

  mkdir -p "$artifacts_dir"
  cat > "$ext_path" <<EOF
[ v3_ca ]
basicConstraints = critical, CA:true, pathlen:${pathlen}
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

  openssl genrsa -out "$key_path" 2048
  openssl req -new -sha256 -key "$key_path" -subj "/CN=${common_name}" -out "$csr_path"
  openssl x509 -req -sha256 -days "$days" -set_serial "$serial" \
    -in "$csr_path" \
    -signkey "$key_path" \
    -extfile "$ext_path" \
    -extensions v3_ca \
    -out "$cert_path"
}

generate_signed_ca() {
  local artifacts_dir="$1"
  local basename="$2"
  local common_name="$3"
  local serial="$4"
  local days="$5"
  local pathlen="$6"
  local issuer_key="$7"
  local issuer_cert="$8"

  local key_path="${artifacts_dir}/${basename}.key.pem"
  local csr_path="${artifacts_dir}/${basename}.csr.pem"
  local cert_path="${artifacts_dir}/${basename}.cert.pem"
  local chain_path="${artifacts_dir}/chain.pem"
  local ext_path="${artifacts_dir}/${basename}.ext"

  mkdir -p "$artifacts_dir"
  cat > "$ext_path" <<EOF
[ v3_intermediate_ca ]
basicConstraints = critical, CA:true, pathlen:${pathlen}
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

  openssl genrsa -out "$key_path" 2048
  openssl req -new -sha256 -key "$key_path" -subj "/CN=${common_name}" -out "$csr_path"
  openssl x509 -req -sha256 -days "$days" -set_serial "$serial" \
    -in "$csr_path" \
    -CA "$issuer_cert" \
    -CAkey "$issuer_key" \
    -extfile "$ext_path" \
    -extensions v3_intermediate_ca \
    -out "$cert_path"
  cat "$cert_path" "$issuer_cert" > "$chain_path"
}

generate_tls_request() {
  local artifacts_dir="$1"
  local basename="$2"
  local common_name="$3"
  local san_spec="$4"
  local profile="$5"

  local key_path="${artifacts_dir}/${basename}.key.pem"
  local csr_path="${artifacts_dir}/${basename}.csr.pem"
  local config_path="${artifacts_dir}/${basename}-req.conf"

  mkdir -p "$artifacts_dir"
  cat > "$config_path" <<EOF
[ req ]
distinguished_name = dn
prompt = no
req_extensions = req_ext

[ dn ]
CN = ${common_name}

[ req_ext ]
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = ${profile}
subjectAltName = ${san_spec}
EOF

  openssl genrsa -out "$key_path" 2048
  openssl req -new -sha256 -key "$key_path" -config "$config_path" -out "$csr_path"
}

sign_tls_certificate() {
  local artifacts_dir="$1"
  local basename="$2"
  local csr_path="$3"
  local san_spec="$4"
  local profile="$5"
  local serial="$6"
  local days="$7"
  local issuer_key="$8"
  local issuer_cert="$9"
  local root_cert="${10}"

  local cert_path="${artifacts_dir}/${basename}.cert.pem"
  local chain_path="${artifacts_dir}/chain.pem"
  local ext_path="${artifacts_dir}/${basename}.ext"

  mkdir -p "$artifacts_dir"
  cat > "$ext_path" <<EOF
[ tls_leaf ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = ${profile}
subjectAltName = ${san_spec}
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

  openssl x509 -req -sha256 -days "$days" -set_serial "$serial" \
    -in "$csr_path" \
    -CA "$issuer_cert" \
    -CAkey "$issuer_key" \
    -extfile "$ext_path" \
    -extensions tls_leaf \
    -out "$cert_path"
  cat "$issuer_cert" "$root_cert" > "$chain_path"
}
