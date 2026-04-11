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

copy_optional_artifact() {
  local source_path="$1"
  local target_path="$2"
  local mode="$3"

  if [ -n "$source_path" ] && [ -f "$source_path" ]; then
    cp "$source_path" "$target_path"
    chmod "$mode" "$target_path"
  fi
}

prepare_candidate_artifact() {
  local current_path="$1"
  local source_path="$2"
  local candidate_path="$3"
  local mode="$4"

  mkdir -p "$(dirname "$candidate_path")"

  if [ -f "$current_path" ]; then
    cp "$current_path" "$candidate_path"
    chmod "$mode" "$candidate_path"
  fi

  if [ -n "$source_path" ] && [ -f "$source_path" ]; then
    cp "$source_path" "$candidate_path"
    chmod "$mode" "$candidate_path"
  fi
}

install_candidate_artifact() {
  local candidate_path="$1"
  local target_path="$2"
  local mode="$3"
  local target_dir=""
  local target_tmp=""

  [ -f "$candidate_path" ] || return 0

  target_dir="$(dirname "$target_path")"
  mkdir -p "$target_dir"
  target_tmp="$(mktemp "${target_dir}/.pd-pki-staged.XXXXXX")"
  cp "$candidate_path" "$target_tmp"
  chmod "$mode" "$target_tmp"
  mv -f "$target_tmp" "$target_path"
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

private_key_public_key() {
  local key_path="$1"
  openssl pkey -in "$key_path" -pubout -outform pem
}

csr_public_key() {
  local csr_path="$1"
  openssl req -in "$csr_path" -pubkey -noout | openssl pkey -pubin -outform pem
}

certificate_public_key() {
  local certificate="$1"
  openssl x509 -in "$certificate" -pubkey -noout | openssl pkey -pubin -outform pem
}

private_key_matches_csr() {
  local key_path="$1"
  local csr_path="$2"
  [ "$(private_key_public_key "$key_path")" = "$(csr_public_key "$csr_path")" ]
}

private_key_matches_certificate() {
  local key_path="$1"
  local certificate="$2"
  [ "$(private_key_public_key "$key_path")" = "$(certificate_public_key "$certificate")" ]
}

csr_matches_certificate() {
  local csr_path="$1"
  local certificate="$2"
  [ "$(csr_public_key "$csr_path")" = "$(certificate_public_key "$certificate")" ]
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

certificate_subject_rfc2253() {
  local certificate="$1"
  openssl x509 -in "$certificate" -noout -subject -nameopt RFC2253 | sed 's/^subject=//'
}

certificate_issuer_rfc2253() {
  local certificate="$1"
  openssl x509 -in "$certificate" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//'
}

certificate_common_name() {
  local certificate="$1"
  certificate_subject_rfc2253 "$certificate" | sed -n 's/.*CN=\([^,]*\).*/\1/p'
}

crl_issuer_rfc2253() {
  local crl_path="$1"
  openssl crl -in "$crl_path" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//'
}

crl_next_update() {
  local crl_path="$1"
  openssl crl -in "$crl_path" -noout -nextupdate -dateopt iso_8601 | cut -d= -f2-
}

certificate_is_ca() {
  local certificate="$1"
  openssl x509 -in "$certificate" -noout -text |
    grep -A1 "Basic Constraints" |
    grep -q "CA:TRUE"
}

certificate_pathlen() {
  local certificate="$1"
  openssl x509 -in "$certificate" -noout -text |
    grep -A1 "Basic Constraints" |
    grep -o 'pathlen:[0-9]\+' |
    cut -d: -f2
}

certificate_extended_key_usage_text() {
  local certificate="$1"
  openssl x509 -in "$certificate" -noout -ext extendedKeyUsage 2>/dev/null |
    sed -n '2p' |
    sed 's/^[[:space:]]*//'
}

write_certificate_subject_alt_names() {
  local certificate="$1"
  local target="$2"
  local ext_output=""

  ext_output="$(mktemp)"
  if openssl x509 -in "$certificate" -noout -ext subjectAltName > "$ext_output" 2>/dev/null; then
    sed '1d' "$ext_output" |
      tr ',' '\n' |
      sed -e 's/^[[:space:]]*//' -e 's/^IP Address:/IP:/' |
      grep -v '^$' |
      sort -u > "$target"
  else
    : > "$target"
  fi
  rm -f "$ext_output"
}

write_request_subject_alt_names() {
  local request_path="$1"
  local target="$2"
  jq -r '(.subjectAltNames // [])[]' "$request_path" | sort -u > "$target"
}

validate_certificate_metadata() {
  local metadata_path="$1"
  local certificate="$2"

  jq -e \
    --arg serial "$(certificate_serial "$certificate")" \
    --arg subject "$(certificate_subject "$certificate")" \
    --arg issuer "$(certificate_issuer "$certificate")" \
    --arg notBefore "$(certificate_not_before "$certificate")" \
    --arg notAfter "$(certificate_not_after "$certificate")" \
    --arg sha256Fingerprint "$(certificate_fingerprint "$certificate")" \
    '
      .serial == $serial and
      .subject == $subject and
      .issuer == $issuer and
      .notBefore == $notBefore and
      .notAfter == $notAfter and
      .sha256Fingerprint == $sha256Fingerprint
    ' "$metadata_path" >/dev/null
}

validate_crl_signature() {
  local crl_path="$1"
  local issuer_bundle="$2"
  openssl crl -in "$crl_path" -noout -verify -CAfile "$issuer_bundle" >/dev/null 2>&1
}

validate_crl_issuer_matches_bundle() {
  local crl_path="$1"
  local issuer_bundle="$2"
  [ "$(crl_issuer_rfc2253 "$crl_path")" = "$(certificate_subject_rfc2253 "$issuer_bundle")" ]
}

ensure_crl_current() {
  local crl_path="$1"
  local next_update=""
  local next_update_epoch=""

  next_update="$(crl_next_update "$crl_path")"
  [ -n "$next_update" ] || return 1
  next_update_epoch="$(date -u -d "$next_update" +%s 2>/dev/null)" || return 1
  [ "$next_update_epoch" -gt "$(date -u +%s)" ]
}

validate_certificate_common_name_matches_request() {
  local certificate="$1"
  local request_path="$2"
  local expected_common_name=""
  local actual_common_name=""

  expected_common_name="$(jq -r '.commonName // empty' "$request_path")"
  actual_common_name="$(certificate_common_name "$certificate")"
  [ -n "$expected_common_name" ] || return 1
  [ "$actual_common_name" = "$expected_common_name" ]
}

validate_certificate_subject_alt_names_match_request() {
  local certificate="$1"
  local request_path="$2"
  local certificate_sans=""
  local request_sans=""
  local certificate_sans_hash=""
  local request_sans_hash=""

  certificate_sans="$(mktemp)"
  request_sans="$(mktemp)"
  write_certificate_subject_alt_names "$certificate" "$certificate_sans"
  write_request_subject_alt_names "$request_path" "$request_sans"
  certificate_sans_hash="$(sha256sum "$certificate_sans" | cut -d' ' -f1)"
  request_sans_hash="$(sha256sum "$request_sans" | cut -d' ' -f1)"
  if [ "$certificate_sans_hash" != "$request_sans_hash" ]; then
    rm -f "$certificate_sans" "$request_sans"
    return 1
  fi
  rm -f "$certificate_sans" "$request_sans"
}

validate_tls_certificate_profile() {
  local certificate="$1"
  local requested_profile="$2"
  local expected_eku=""

  case "$requested_profile" in
    serverAuth) expected_eku="TLS Web Server Authentication" ;;
    clientAuth) expected_eku="TLS Web Client Authentication" ;;
    *) return 1 ;;
  esac

  [ "$(certificate_extended_key_usage_text "$certificate")" = "$expected_eku" ]
}

validate_root_runtime_import_state() {
  local key_path="$1"
  local csr_path="$2"
  local cert_path="$3"
  local crl_path="$4"
  local metadata_path="$5"

  if [ -f "$key_path" ] && [ -f "$csr_path" ]; then
    private_key_matches_csr "$key_path" "$csr_path" ||
      { printf '%s\n' "Root private key does not match CSR in runtime state" >&2; return 1; }
  fi

  if [ -f "$key_path" ] && [ -f "$cert_path" ]; then
    private_key_matches_certificate "$key_path" "$cert_path" ||
      { printf '%s\n' "Root private key does not match certificate in runtime state" >&2; return 1; }
  fi

  if [ -f "$csr_path" ] && [ -f "$cert_path" ]; then
    csr_matches_certificate "$csr_path" "$cert_path" ||
      { printf '%s\n' "Root CSR does not match certificate in runtime state" >&2; return 1; }
  fi

  if [ -f "$cert_path" ]; then
    openssl x509 -in "$cert_path" -noout >/dev/null ||
      { printf '%s\n' "Root certificate is not a valid X.509 certificate" >&2; return 1; }
    certificate_is_ca "$cert_path" ||
      { printf '%s\n' "Root certificate is not a CA certificate" >&2; return 1; }
  fi

  if [ -f "$metadata_path" ]; then
    [ -f "$cert_path" ] ||
      { printf '%s\n' "Root metadata requires a root certificate" >&2; return 1; }
    validate_certificate_metadata "$metadata_path" "$cert_path" ||
      { printf '%s\n' "Root metadata does not match the staged root certificate" >&2; return 1; }
  fi

  if [ -f "$crl_path" ]; then
    [ -f "$cert_path" ] ||
      { printf '%s\n' "Root CRL requires a root certificate" >&2; return 1; }
    openssl crl -in "$crl_path" -noout >/dev/null ||
      { printf '%s\n' "Root CRL is not a valid CRL" >&2; return 1; }
    validate_crl_issuer_matches_bundle "$crl_path" "$cert_path" ||
      { printf '%s\n' "Root CRL issuer does not match the staged root certificate" >&2; return 1; }
    validate_crl_signature "$crl_path" "$cert_path" ||
      { printf '%s\n' "Root CRL signature does not verify against the staged root certificate" >&2; return 1; }
    ensure_crl_current "$crl_path" ||
      { printf '%s\n' "Root CRL is expired or missing nextUpdate" >&2; return 1; }
  fi
}

validate_intermediate_runtime_import_state() {
  local key_path="$1"
  local csr_path="$2"
  local request_path="$3"
  local cert_path="$4"
  local chain_path="$5"
  local crl_path="$6"
  local metadata_path="$7"
  local expected_pathlen=""
  local actual_pathlen=""

  if [ -f "$key_path" ] && [ -f "$csr_path" ]; then
    private_key_matches_csr "$key_path" "$csr_path" ||
      { printf '%s\n' "Intermediate private key does not match CSR in runtime state" >&2; return 1; }
  fi

  if [ -f "$chain_path" ] && [ ! -f "$cert_path" ]; then
    printf '%s\n' "Intermediate chain requires an intermediate certificate" >&2
    return 1
  fi

  if [ -f "$crl_path" ] && [ ! -f "$cert_path" ]; then
    printf '%s\n' "Intermediate CRL requires an intermediate certificate" >&2
    return 1
  fi

  if [ -f "$metadata_path" ] && [ ! -f "$cert_path" ]; then
    printf '%s\n' "Intermediate metadata requires an intermediate certificate" >&2
    return 1
  fi

  if [ -f "$cert_path" ]; then
    [ -f "$chain_path" ] ||
      { printf '%s\n' "Intermediate certificate requires a certificate chain" >&2; return 1; }
    openssl x509 -in "$cert_path" -noout >/dev/null ||
      { printf '%s\n' "Intermediate certificate is not a valid X.509 certificate" >&2; return 1; }
    csr_matches_certificate "$csr_path" "$cert_path" ||
      { printf '%s\n' "Intermediate certificate does not match the local CSR" >&2; return 1; }
    openssl verify -CAfile "$chain_path" "$cert_path" >/dev/null ||
      { printf '%s\n' "Intermediate certificate does not verify against the staged chain" >&2; return 1; }
    certificate_is_ca "$cert_path" ||
      { printf '%s\n' "Intermediate certificate is not a CA certificate" >&2; return 1; }
    validate_certificate_common_name_matches_request "$cert_path" "$request_path" ||
      { printf '%s\n' "Intermediate certificate common name does not match signing-request.json" >&2; return 1; }
    expected_pathlen="$(jq -r '(.pathLen // empty) | tostring' "$request_path")"
    actual_pathlen="$(certificate_pathlen "$cert_path")"
    [ -n "$expected_pathlen" ] && [ "$actual_pathlen" = "$expected_pathlen" ] ||
      { printf '%s\n' "Intermediate certificate pathLen does not match signing-request.json" >&2; return 1; }
  fi

  if [ -f "$metadata_path" ]; then
    validate_certificate_metadata "$metadata_path" "$cert_path" ||
      { printf '%s\n' "Intermediate metadata does not match the staged certificate" >&2; return 1; }
  fi

  if [ -f "$crl_path" ]; then
    openssl crl -in "$crl_path" -noout >/dev/null ||
      { printf '%s\n' "Intermediate CRL is not a valid CRL" >&2; return 1; }
    validate_crl_issuer_matches_bundle "$crl_path" "$cert_path" ||
      { printf '%s\n' "Intermediate CRL issuer does not match the staged intermediate certificate" >&2; return 1; }
    validate_crl_signature "$crl_path" "$cert_path" ||
      { printf '%s\n' "Intermediate CRL signature does not verify against the staged intermediate certificate" >&2; return 1; }
    ensure_crl_current "$crl_path" ||
      { printf '%s\n' "Intermediate CRL is expired or missing nextUpdate" >&2; return 1; }
  fi
}

validate_tls_runtime_import_state() {
  local role_label="$1"
  local csr_path="$2"
  local request_path="$3"
  local cert_path="$4"
  local chain_path="$5"
  local crl_path="$6"
  local metadata_path="$7"
  local requested_profile=""

  if [ -f "$metadata_path" ] && [ ! -f "$cert_path" ]; then
    printf '%s\n' "${role_label} metadata requires a certificate" >&2
    return 1
  fi

  if [ -f "$cert_path" ] && [ ! -f "$chain_path" ]; then
    printf '%s\n' "${role_label} certificate requires a certificate chain" >&2
    return 1
  fi

  if [ -f "$cert_path" ]; then
    openssl x509 -in "$cert_path" -noout >/dev/null ||
      { printf '%s\n' "${role_label} certificate is not a valid X.509 certificate" >&2; return 1; }
    csr_matches_certificate "$csr_path" "$cert_path" ||
      { printf '%s\n' "${role_label} certificate does not match the local CSR" >&2; return 1; }
    openssl verify -CAfile "$chain_path" "$cert_path" >/dev/null ||
      { printf '%s\n' "${role_label} certificate does not verify against the staged chain" >&2; return 1; }
    validate_certificate_common_name_matches_request "$cert_path" "$request_path" ||
      { printf '%s\n' "${role_label} certificate common name does not match issuance-request.json" >&2; return 1; }
    validate_certificate_subject_alt_names_match_request "$cert_path" "$request_path" ||
      { printf '%s\n' "${role_label} certificate subjectAltNames do not match issuance-request.json" >&2; return 1; }
    requested_profile="$(jq -r '.requestedProfile // empty' "$request_path")"
    [ -n "$requested_profile" ] ||
      { printf '%s\n' "${role_label} issuance-request.json is missing requestedProfile" >&2; return 1; }
    validate_tls_certificate_profile "$cert_path" "$requested_profile" ||
      { printf '%s\n' "${role_label} certificate extendedKeyUsage does not match issuance-request.json" >&2; return 1; }
  fi

  if [ -f "$metadata_path" ]; then
    validate_certificate_metadata "$metadata_path" "$cert_path" ||
      { printf '%s\n' "${role_label} metadata does not match the staged certificate" >&2; return 1; }
  fi

  if [ -f "$crl_path" ]; then
    [ -f "$chain_path" ] ||
      { printf '%s\n' "${role_label} CRL requires a certificate chain" >&2; return 1; }
    openssl crl -in "$crl_path" -noout >/dev/null ||
      { printf '%s\n' "${role_label} CRL is not a valid CRL" >&2; return 1; }
    validate_crl_issuer_matches_bundle "$crl_path" "$chain_path" ||
      { printf '%s\n' "${role_label} CRL issuer does not match the staged issuing certificate" >&2; return 1; }
    validate_crl_signature "$crl_path" "$chain_path" ||
      { printf '%s\n' "${role_label} CRL signature does not verify against the staged chain" >&2; return 1; }
    ensure_crl_current "$crl_path" ||
      { printf '%s\n' "${role_label} CRL is expired or missing nextUpdate" >&2; return 1; }
  fi
}

write_certificate_chain() {
  local target="$1"
  local issuer_cert="$2"
  local issuer_chain="${3:-}"

  if [ -n "$issuer_chain" ]; then
    cat "$issuer_cert" "$issuer_chain" > "$target"
  else
    cp "$issuer_cert" "$target"
  fi
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

generate_ca_request() {
  local artifacts_dir="$1"
  local basename="$2"
  local common_name="$3"
  local pathlen="$4"

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
basicConstraints = critical, CA:true, pathlen:${pathlen}
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

  openssl genrsa -out "$key_path" 2048
  openssl req -new -sha256 -key "$key_path" -config "$config_path" -out "$csr_path"
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

sign_ca_request() {
  local artifacts_dir="$1"
  local basename="$2"
  local csr_path="$3"
  local pathlen="$4"
  local serial="$5"
  local days="$6"
  local issuer_key="$7"
  local issuer_cert="$8"
  local issuer_chain="${9:-}"

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

  openssl x509 -req -sha256 -days "$days" -set_serial "$serial" \
    -in "$csr_path" \
    -CA "$issuer_cert" \
    -CAkey "$issuer_key" \
    -extfile "$ext_path" \
    -extensions v3_intermediate_ca \
    -out "$cert_path"
  write_certificate_chain "$chain_path" "$issuer_cert" "$issuer_chain"
}

sign_tls_request() {
  local artifacts_dir="$1"
  local basename="$2"
  local csr_path="$3"
  local san_spec="$4"
  local profile="$5"
  local serial="$6"
  local days="$7"
  local issuer_key="$8"
  local issuer_cert="$9"
  local issuer_chain="${10:-}"

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
  write_certificate_chain "$chain_path" "$issuer_cert" "$issuer_chain"
}
