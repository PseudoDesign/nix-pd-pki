{ pkgs }:
pkgs.writeShellApplication {
  name = "pd-pki-signing-tools";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
    pkgs.openssl
    pkgs.util-linux
  ];
  text = ''
    set -euo pipefail

    # shellcheck source=/dev/null
    source ${./pki-workflow-lib.sh}

    die() {
      printf '%s\n' "$1" >&2
      exit 1
    }

    require_file() {
      local path="$1"
      [ -f "$path" ] || die "Required file not found: $path"
    }

    require_dir() {
      local path="$1"
      [ -d "$path" ] || die "Required directory not found: $path"
    }

    certificate_basename_for_role() {
      local role="$1"
      case "$role" in
        intermediate-signing-authority) printf '%s\n' "intermediate-ca" ;;
        openvpn-server-leaf) printf '%s\n' "server" ;;
        openvpn-client-leaf) printf '%s\n' "client" ;;
        *) die "Unsupported role: $role" ;;
      esac
    }

    metadata_profile_for_import() {
      local role="$1"
      case "$role" in
        intermediate-signing-authority) printf '%s\n' "intermediate-ca-imported" ;;
        openvpn-server-leaf) printf '%s\n' "openvpn-server-imported" ;;
        openvpn-client-leaf) printf '%s\n' "openvpn-client-imported" ;;
        *) die "Unsupported role: $role" ;;
      esac
    }

    metadata_profile_for_signed_bundle() {
      local role="$1"
      case "$role" in
        intermediate-signing-authority) printf '%s\n' "intermediate-ca-signed" ;;
        openvpn-server-leaf) printf '%s\n' "openvpn-server-signed" ;;
        openvpn-client-leaf) printf '%s\n' "openvpn-client-signed" ;;
        *) die "Unsupported role: $role" ;;
      esac
    }

    csr_matches_certificate() {
      local csr_path="$1"
      local certificate_path="$2"
      local csr_pubkey
      local cert_pubkey

      csr_pubkey="$(openssl req -in "$csr_path" -pubkey -noout | openssl pkey -pubin -outform pem)"
      cert_pubkey="$(openssl x509 -in "$certificate_path" -pubkey -noout | openssl pkey -pubin -outform pem)"
      [ "$csr_pubkey" = "$cert_pubkey" ]
    }

    signer_matches_key() {
      local issuer_key="$1"
      local issuer_cert="$2"
      local key_pubkey
      local cert_pubkey

      key_pubkey="$(openssl pkey -in "$issuer_key" -pubout -outform pem)"
      cert_pubkey="$(openssl x509 -in "$issuer_cert" -pubkey -noout | openssl pkey -pubin -outform pem)"
      [ "$key_pubkey" = "$cert_pubkey" ]
    }

    current_timestamp_utc() {
      date -u +"%Y-%m-%dT%H:%M:%SZ"
    }

    canonicalize_hex_serial() {
      local serial="$1"

      serial="''${serial#0x}"
      serial="''${serial#0X}"
      serial="$(printf '%s' "$serial" | tr '[:lower:]' '[:upper:]')"
      [ -n "$serial" ] || die "Serial value is empty"
      case "$serial" in
        *[!0-9A-F]*) die "Serial value must be hexadecimal" ;;
      esac
      if [ $((''${#serial} % 2)) -ne 0 ]; then
        serial="0$serial"
      fi
      printf '%s\n' "$serial"
    }

    decimal_serial_to_hex() {
      local serial="$1"

      [ -n "$serial" ] || die "Serial value is empty"
      case "$serial" in
        *[!0-9]*) die "Serial value must be an unsigned decimal integer" ;;
      esac
      canonicalize_hex_serial "$(printf '%X' "$serial")"
    }

    validate_crl_reason() {
      local reason="$1"
      case "$reason" in
        unspecified|keyCompromise|CACompromise|affiliationChanged|superseded|cessationOfOperation|certificateHold|removeFromCRL|privilegeWithdrawn|AACompromise)
          ;;
        *)
          die "Invalid CRL reason: $reason"
          ;;
      esac
    }

    validate_unsigned_decimal() {
      local value="$1"
      local label="$2"

      [ -n "$value" ] || die "$label is empty"
      case "$value" in
        *[!0-9]*) die "$label must be an unsigned decimal integer" ;;
      esac
    }

    value_in_list() {
      local needle="$1"
      shift

      local candidate
      for candidate in "$@"; do
        if [ "$candidate" = "$needle" ]; then
          return 0
        fi
      done
      return 1
    }

    value_matches_any_pattern() {
      local value="$1"
      shift

      local pattern
      for pattern in "$@"; do
        if printf '%s\n' "$value" | grep -Eq "$pattern"; then
          return 0
        fi
      done
      return 1
    }

    crl_last_update() {
      local crl_path="$1"
      openssl crl -in "$crl_path" -noout -lastupdate | cut -d= -f2-
    }

    crl_next_update() {
      local crl_path="$1"
      openssl crl -in "$crl_path" -noout -nextupdate | cut -d= -f2-
    }

    crl_number() {
      local crl_path="$1"
      canonicalize_hex_serial "$(openssl crl -in "$crl_path" -noout -crlnumber | cut -d= -f2-)"
    }

    signer_state_init() {
      local state_dir="$1"
      mkdir -p \
        "$state_dir/crls" \
        "$state_dir/issuances" \
        "$state_dir/requests" \
        "$state_dir/revocations" \
        "$state_dir/serials/allocated"

      if [ ! -f "$state_dir/serials/next-serial" ]; then
        printf '%s\n' "1" > "$state_dir/serials/next-serial"
      fi

      if [ ! -f "$state_dir/crls/next-crl-number" ]; then
        printf '%s\n' "01" > "$state_dir/crls/next-crl-number"
      fi
    }

    signer_state_next_serial_path() {
      local state_dir="$1"
      printf '%s\n' "$state_dir/serials/next-serial"
    }

    signer_state_request_record_path() {
      local state_dir="$1"
      local request_id="$2"
      printf '%s\n' "$state_dir/requests/$request_id.json"
    }

    signer_state_serial_record_path() {
      local state_dir="$1"
      local serial="$2"
      printf '%s\n' "$state_dir/serials/allocated/$serial.json"
    }

    signer_state_issuance_dir() {
      local state_dir="$1"
      local serial="$2"
      printf '%s\n' "$state_dir/issuances/$serial"
    }

    signer_state_revocation_record_path() {
      local state_dir="$1"
      local serial="$2"
      printf '%s\n' "$state_dir/revocations/$serial.json"
    }

    signer_state_current_crl_path() {
      local state_dir="$1"
      printf '%s\n' "$state_dir/crls/current.pem"
    }

    signer_state_crl_metadata_path() {
      local state_dir="$1"
      printf '%s\n' "$state_dir/crls/metadata.json"
    }

    signer_state_next_crl_number_path() {
      local state_dir="$1"
      printf '%s\n' "$state_dir/crls/next-crl-number"
    }

    signer_state_lock_path() {
      local state_dir="$1"
      printf '%s\n' "$state_dir/.state.lock"
    }

    acquire_signer_state_lock() {
      local state_dir="$1"
      local fd_var_name="$2"
      local fd
      local lock_path

      signer_state_init "$state_dir"
      lock_path="$(signer_state_lock_path "$state_dir")"
      exec {fd}> "$lock_path"
      flock "$fd"
      printf -v "$fd_var_name" '%s' "$fd"
    }

    close_locked_fd() {
      local fd="$1"
      [ -n "$fd" ] || return 0
      eval "exec ''${fd}>&-"
    }

    signer_state_resolve_serial() {
      local state_dir="$1"
      local serial="$2"
      local candidate=""

      if [ -d "$(signer_state_issuance_dir "$state_dir" "$serial")" ] || [ -f "$(signer_state_serial_record_path "$state_dir" "$serial")" ] || [ -f "$(signer_state_revocation_record_path "$state_dir" "$serial")" ]; then
        printf '%s\n' "$serial"
        return
      fi

      [ -n "$serial" ] || die "Serial value is empty"
      case "$serial" in
        *[!0-9]* ) candidate="$(canonicalize_hex_serial "$serial")" ;;
        * ) candidate="$(decimal_serial_to_hex "$serial")" ;;
      esac

      if [ -d "$(signer_state_issuance_dir "$state_dir" "$candidate")" ] || [ -f "$(signer_state_serial_record_path "$state_dir" "$candidate")" ] || [ -f "$(signer_state_revocation_record_path "$state_dir" "$candidate")" ]; then
        printf '%s\n' "$candidate"
        return
      fi

      die "Unknown serial in signer state: $serial"
    }

    request_id_for_bundle() {
      local request_file="$1"
      local csr_path="$2"
      local normalized_request

      normalized_request="$(mktemp)"
      jq -cS . "$request_file" > "$normalized_request"
      cat "$normalized_request" "$csr_path" | sha256sum | cut -d' ' -f1
      rm -f "$normalized_request"
    }

    allocate_serial_from_state() {
      local state_dir="$1"
      local next_serial_path
      local serial

      signer_state_init "$state_dir"
      next_serial_path="$(signer_state_next_serial_path "$state_dir")"
      serial="$(tr -d '[:space:]' < "$next_serial_path")"

      validate_unsigned_decimal "$serial" "Signer state next serial"

      printf '%s\n' "$((serial + 1))" > "$next_serial_path"
      printf '%s\n' "$serial"
    }

    validate_policy_file() {
      local policy_file="$1"

      require_file "$policy_file"
      jq -e '
        (.schemaVersion // 0) == 1 and
        (.roles | type == "object")
      ' "$policy_file" >/dev/null || die "Invalid signer policy file: $policy_file"
    }

    ensure_policy_role() {
      local policy_file="$1"
      local role="$2"

      jq -e --arg role "$role" '.roles[$role] != null' "$policy_file" >/dev/null ||
        die "Signer policy does not define role: $role"
    }

    validate_request_kind_for_role() {
      local role="$1"
      local request_file="$2"
      local expected_kind
      local request_kind

      case "$role" in
        intermediate-signing-authority) expected_kind="intermediate-ca" ;;
        openvpn-server-leaf|openvpn-client-leaf) expected_kind="tls-leaf" ;;
        *) die "Unsupported role in request validation: $role" ;;
      esac

      request_kind="$(jq -r '.requestKind // empty' "$request_file")"
      [ "$request_kind" = "$expected_kind" ] ||
        die "request.json requestKind '$request_kind' does not match role '$role'"
    }

    resolve_signing_days() {
      local request_file="$1"
      local role="$2"
      local cli_days="$3"
      local policy_file="$4"
      local request_days=""
      local default_days=""
      local max_days=""
      local selected_days=""

      request_days="$(jq -r '.requestedDays // empty' "$request_file")"

      if [ -n "$cli_days" ]; then
        validate_unsigned_decimal "$cli_days" "--days"
        selected_days="$cli_days"
      elif [ -n "$policy_file" ]; then
        default_days="$(jq -r --arg role "$role" '.roles[$role].defaultDays // empty' "$policy_file")"
        [ -n "$default_days" ] || die "Signer policy is missing roles.''${role}.defaultDays"
        validate_unsigned_decimal "$default_days" "Signer policy defaultDays"
        selected_days="$default_days"
      else
        [ -n "$request_days" ] || die "--days is required when no signer policy is provided and request.json does not declare requestedDays"
        validate_unsigned_decimal "$request_days" "request.json requestedDays"
        selected_days="$request_days"
      fi

      if [ -n "$policy_file" ]; then
        max_days="$(jq -r --arg role "$role" '.roles[$role].maxDays // empty' "$policy_file")"
        if [ -n "$max_days" ]; then
          validate_unsigned_decimal "$max_days" "Signer policy maxDays"
          [ "$selected_days" -le "$max_days" ] ||
            die "Requested validity of $selected_days days exceeds signer policy maxDays $max_days for role $role"
        fi
      fi

      printf '%s\n' "$selected_days"
    }

    validate_request_against_policy() {
      local request_file="$1"
      local role="$2"
      local policy_file="$3"
      local common_name=""
      local path_len=""
      local requested_profile=""
      local san=""
      local allowed=()
      local patterns=()
      local sans=()

      [ -n "$policy_file" ] || return 0

      ensure_policy_role "$policy_file" "$role"

      common_name="$(jq -r '.commonName // empty' "$request_file")"
      [ -n "$common_name" ] || die "request.json is missing commonName"

      mapfile -t patterns < <(jq -r --arg role "$role" '(.roles[$role].commonNamePatterns // [])[]' "$policy_file")
      if [ "''${#patterns[@]}" -gt 0 ] && ! value_matches_any_pattern "$common_name" "''${patterns[@]}"; then
        die "Signer policy rejected commonName '$common_name' for role $role"
      fi

      case "$role" in
        intermediate-signing-authority)
          path_len="$(jq -r '(.pathLen // empty) | tostring' "$request_file")"
          [ -n "$path_len" ] || die "request.json is missing pathLen"
          mapfile -t allowed < <(jq -r --arg role "$role" '(.roles[$role].allowedPathLens // [])[] | tostring' "$policy_file")
          if [ "''${#allowed[@]}" -gt 0 ] && ! value_in_list "$path_len" "''${allowed[@]}"; then
            die "Signer policy rejected pathLen '$path_len' for role $role"
          fi
          ;;
        openvpn-server-leaf|openvpn-client-leaf)
          requested_profile="$(jq -r '.requestedProfile // empty' "$request_file")"
          [ -n "$requested_profile" ] || die "request.json is missing requestedProfile"
          mapfile -t allowed < <(jq -r --arg role "$role" '(.roles[$role].allowedProfiles // [])[]' "$policy_file")
          if [ "''${#allowed[@]}" -gt 0 ] && ! value_in_list "$requested_profile" "''${allowed[@]}"; then
            die "Signer policy rejected requestedProfile '$requested_profile' for role $role"
          fi

          mapfile -t patterns < <(jq -r --arg role "$role" '(.roles[$role].subjectAltNamePatterns // [])[]' "$policy_file")
          if [ "''${#patterns[@]}" -gt 0 ]; then
            mapfile -t sans < <(jq -r '(.subjectAltNames // [])[]' "$request_file")
            [ "''${#sans[@]}" -gt 0 ] || die "request.json is missing subjectAltNames"
            for san in "''${sans[@]}"; do
              if ! value_matches_any_pattern "$san" "''${patterns[@]}"; then
                die "Signer policy rejected subjectAltName '$san' for role $role"
              fi
            done
          fi
          ;;
      esac
    }

    copy_signed_bundle_from_issuance() {
      local issuance_dir="$1"
      local basename="$2"
      local out_dir="$3"

      require_dir "$issuance_dir"
      mkdir -p "$out_dir"
      cp "$issuance_dir/$basename.cert.pem" "$out_dir/$basename.cert.pem"
      cp "$issuance_dir/chain.pem" "$out_dir/chain.pem"
      cp "$issuance_dir/metadata.json" "$out_dir/metadata.json"
      cp "$issuance_dir/request.json" "$out_dir/request.json"
    }

    write_request_record() {
      local target="$1"
      local request_id="$2"
      local request_file="$3"
      local serial="$4"
      local recorded_at="$5"

      jq -n \
        --arg requestId "$request_id" \
        --arg serial "$serial" \
        --arg recordedAt "$recorded_at" \
        --argjson request "$(jq -cS . "$request_file")" \
        '{
          schemaVersion: 1,
          requestId: $requestId,
          serial: $serial,
          status: "issued",
          recordedAt: $recordedAt,
          request: $request
        }' > "$target"
    }

    write_serial_record() {
      local target="$1"
      local serial="$2"
      local request_id="$3"
      local allocated_at="$4"

      jq -n \
        --arg serial "$serial" \
        --arg requestId "$request_id" \
        --arg allocatedAt "$allocated_at" \
        '{
          schemaVersion: 1,
          serial: $serial,
          requestId: $requestId,
          allocatedAt: $allocatedAt,
          status: "issued"
        }' > "$target"
    }

    write_issuance_record() {
      local target="$1"
      local serial="$2"
      local request_id="$3"
      local request_file="$4"
      local metadata_file="$5"
      local issuer_cert="$6"
      local issued_at="$7"

      jq -n \
        --arg serial "$serial" \
        --arg requestId "$request_id" \
        --arg issuedAt "$issued_at" \
        --arg issuerSubject "$(certificate_subject "$issuer_cert")" \
        --arg issuerFingerprint "$(certificate_fingerprint "$issuer_cert")" \
        --argjson request "$(jq -cS . "$request_file")" \
        --argjson certificate "$(jq -cS . "$metadata_file")" \
        '{
          schemaVersion: 1,
          serial: $serial,
          requestId: $requestId,
          status: "issued",
          issuedAt: $issuedAt,
          issuer: {
            subject: $issuerSubject,
            sha256Fingerprint: $issuerFingerprint
          },
          request: $request,
          certificate: $certificate
        }' > "$target"
    }

    write_crl_metadata() {
      local target="$1"
      local crl_path="$2"
      local issuer_cert="$3"
      local signer_state_dir="$4"
      local revoked_serials_json

      revoked_serials_json="$(
        find "$signer_state_dir/revocations" -maxdepth 1 -name '*.json' -type f -print | sort | while IFS= read -r record_path; do
          jq -r '.serial // empty' "$record_path"
        done | jq -R . | jq -s .
      )"

      jq -n \
        --arg schemaVersion "1" \
        --arg issuerSubject "$(certificate_subject "$issuer_cert")" \
        --arg issuerFingerprint "$(certificate_fingerprint "$issuer_cert")" \
        --arg crlNumber "$(crl_number "$crl_path")" \
        --arg lastUpdate "$(crl_last_update "$crl_path")" \
        --arg nextUpdate "$(crl_next_update "$crl_path")" \
        --argjson revokedSerials "$revoked_serials_json" \
        '{
          schemaVersion: ($schemaVersion | tonumber),
          issuerSubject: $issuerSubject,
          issuerSha256Fingerprint: $issuerFingerprint,
          crlNumber: $crlNumber,
          lastUpdate: $lastUpdate,
          nextUpdate: $nextUpdate,
          revokedSerials: $revokedSerials
        }' > "$target"
    }

    usage() {
      cat <<'EOF' >&2
Usage:
  pd-pki-signing-tools export-request --role ROLE --state-dir DIR --out-dir DIR
  pd-pki-signing-tools sign-request --request-dir DIR --out-dir DIR --issuer-key PATH --issuer-cert PATH [--days DAYS] [--issuer-chain PATH] [--policy-file PATH] [--serial SERIAL | --signer-state-dir DIR]
  pd-pki-signing-tools import-signed --role ROLE --state-dir DIR --signed-dir DIR
  pd-pki-signing-tools generate-crl --signer-state-dir DIR --issuer-key PATH --issuer-cert PATH --out-dir DIR [--days DAYS]
  pd-pki-signing-tools revoke-issued --signer-state-dir DIR --serial SERIAL [--reason REASON]
EOF
    }

    export_request() {
      local role=""
      local state_dir=""
      local out_dir=""
      local basename=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --role)
            role="$2"
            shift 2
            ;;
          --state-dir)
            state_dir="$2"
            shift 2
            ;;
          --out-dir)
            out_dir="$2"
            shift 2
            ;;
          *)
            die "Unknown export-request argument: $1"
            ;;
        esac
      done

      [ -n "$role" ] || die "--role is required"
      [ -n "$state_dir" ] || die "--state-dir is required"
      [ -n "$out_dir" ] || die "--out-dir is required"

      require_dir "$state_dir"
      mkdir -p "$out_dir"
      basename="$(certificate_basename_for_role "$role")"

      case "$role" in
        intermediate-signing-authority)
          require_file "$state_dir/intermediate-ca.csr.pem"
          require_file "$state_dir/signing-request.json"
          cp "$state_dir/intermediate-ca.csr.pem" "$out_dir/$basename.csr.pem"
          cp "$state_dir/signing-request.json" "$out_dir/request.json"
          ;;
        openvpn-server-leaf)
          require_file "$state_dir/server.csr.pem"
          require_file "$state_dir/issuance-request.json"
          cp "$state_dir/server.csr.pem" "$out_dir/$basename.csr.pem"
          cp "$state_dir/issuance-request.json" "$out_dir/request.json"
          if [ -f "$state_dir/san-manifest.json" ]; then
            cp "$state_dir/san-manifest.json" "$out_dir/san-manifest.json"
          fi
          ;;
        openvpn-client-leaf)
          require_file "$state_dir/client.csr.pem"
          require_file "$state_dir/issuance-request.json"
          cp "$state_dir/client.csr.pem" "$out_dir/$basename.csr.pem"
          cp "$state_dir/issuance-request.json" "$out_dir/request.json"
          if [ -f "$state_dir/identity-manifest.json" ]; then
            cp "$state_dir/identity-manifest.json" "$out_dir/identity-manifest.json"
          fi
          ;;
        *)
          die "Unsupported role for export-request: $role"
          ;;
      esac
    }

    sign_request() {
      local request_dir=""
      local out_dir=""
      local issuer_key=""
      local issuer_cert=""
      local issuer_chain=""
      local signer_state_dir=""
      local serial=""
      local days=""
      local policy_file=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --request-dir)
            request_dir="$2"
            shift 2
            ;;
          --out-dir)
            out_dir="$2"
            shift 2
            ;;
          --issuer-key)
            issuer_key="$2"
            shift 2
            ;;
          --issuer-cert)
            issuer_cert="$2"
            shift 2
            ;;
          --issuer-chain)
            issuer_chain="$2"
            shift 2
            ;;
          --signer-state-dir)
            signer_state_dir="$2"
            shift 2
            ;;
          --serial)
            serial="$2"
            shift 2
            ;;
          --days)
            days="$2"
            shift 2
            ;;
          --policy-file)
            policy_file="$2"
            shift 2
            ;;
          *)
            die "Unknown sign-request argument: $1"
            ;;
        esac
      done

      [ -n "$request_dir" ] || die "--request-dir is required"
      [ -n "$out_dir" ] || die "--out-dir is required"
      [ -n "$issuer_key" ] || die "--issuer-key is required"
      [ -n "$issuer_cert" ] || die "--issuer-cert is required"
      if [ -n "$signer_state_dir" ] && [ -n "$serial" ]; then
        die "--serial cannot be combined with --signer-state-dir"
      fi
      if [ -z "$signer_state_dir" ] && [ -z "$serial" ]; then
        die "--serial is required unless --signer-state-dir is provided"
      fi
      if [ -n "$signer_state_dir" ] && [ -z "$policy_file" ]; then
        die "--policy-file is required when --signer-state-dir is provided"
      fi

      require_dir "$request_dir"
      require_file "$issuer_key"
      require_file "$issuer_cert"
      [ -z "$issuer_chain" ] || require_file "$issuer_chain"
      require_file "$request_dir/request.json"
      [ -z "$policy_file" ] || validate_policy_file "$policy_file"

      signer_matches_key "$issuer_key" "$issuer_cert" || die "Issuer certificate does not match issuer private key"

      local request_file="$request_dir/request.json"
      local role
      local basename
      local csr_file
      local csr_path
      local cert_serial=""
      local request_id=""
      local request_record_path=""
      local issuance_dir=""
      local bundle_profile
      local signer_lock_fd=""

      role="$(jq -r '.roleId // empty' "$request_file")"
      basename="$(jq -r '.basename // empty' "$request_file")"
      csr_file="$(jq -r '.csrFile // empty' "$request_file")"

      [ -n "$role" ] || die "request.json is missing roleId"
      [ -n "$basename" ] || die "request.json is missing basename"
      [ -n "$csr_file" ] || die "request.json is missing csrFile"
      csr_path="$request_dir/$csr_file"
      if [ ! -f "$csr_path" ] && [ -f "$request_dir/csr.pem" ]; then
        csr_path="$request_dir/csr.pem"
      fi
      require_file "$csr_path"

      validate_request_kind_for_role "$role" "$request_file"
      validate_request_against_policy "$request_file" "$role" "$policy_file"
      days="$(resolve_signing_days "$request_file" "$role" "$days" "$policy_file")"

      if [ -n "$signer_state_dir" ]; then
        acquire_signer_state_lock "$signer_state_dir" signer_lock_fd
        request_id="$(request_id_for_bundle "$request_file" "$csr_path")"
        request_record_path="$(signer_state_request_record_path "$signer_state_dir" "$request_id")"
        if [ -f "$request_record_path" ]; then
          local existing_serial
          local existing_status
          existing_serial="$(jq -r '.serial // empty' "$request_record_path")"
          [ -n "$existing_serial" ] || die "Existing request record is missing serial: $request_record_path"
          existing_status="$(jq -r '.status // empty' "$request_record_path")"
          case "$existing_status" in
            issued)
              copy_signed_bundle_from_issuance "$(signer_state_issuance_dir "$signer_state_dir" "$existing_serial")" "$basename" "$out_dir"
              close_locked_fd "$signer_lock_fd"
              return
              ;;
            revoked)
              die "Request bundle $request_id has already been issued and revoked; generate a new CSR before requesting a replacement"
              ;;
            *)
              die "Existing request record has unsupported status '$existing_status': $request_record_path"
              ;;
          esac
        fi
        serial="$(allocate_serial_from_state "$signer_state_dir")"
      fi

      mkdir -p "$out_dir"

      case "$role" in
        intermediate-signing-authority)
          local path_len
          path_len="$(jq -r '(.pathLen // empty) | tostring' "$request_file")"
          [ -n "$path_len" ] || die "request.json is missing pathLen"
          sign_ca_request \
            "$out_dir" \
            "$basename" \
            "$csr_path" \
            "$path_len" \
            "$serial" \
            "$days" \
            "$issuer_key" \
            "$issuer_cert" \
            "$issuer_chain"
          ;;
        openvpn-server-leaf|openvpn-client-leaf)
          local san_spec
          local requested_profile
          san_spec="$(jq -r '.subjectAltNames | join(",")' "$request_file")"
          requested_profile="$(jq -r '.requestedProfile // empty' "$request_file")"
          [ -n "$requested_profile" ] || die "request.json is missing requestedProfile"
          [ -n "$san_spec" ] || die "request.json is missing subjectAltNames"
          sign_tls_request \
            "$out_dir" \
            "$basename" \
            "$csr_path" \
            "$san_spec" \
            "$requested_profile" \
            "$serial" \
            "$days" \
            "$issuer_key" \
            "$issuer_cert" \
            "$issuer_chain"
          ;;
        *)
          die "Unsupported role for sign-request: $role"
          ;;
      esac

      bundle_profile="$(metadata_profile_for_signed_bundle "$role")"
      write_certificate_metadata "$out_dir/$basename.cert.pem" "$out_dir/metadata.json" "$bundle_profile"
      cert_serial="$(certificate_serial "$out_dir/$basename.cert.pem")"
      cp "$request_file" "$out_dir/request.json"
      openssl verify -CAfile "$out_dir/chain.pem" "$out_dir/$basename.cert.pem" >/dev/null

      if [ -n "$signer_state_dir" ]; then
        local issued_at
        issued_at="$(current_timestamp_utc)"
        issuance_dir="$(signer_state_issuance_dir "$signer_state_dir" "$cert_serial")"
        mkdir -p "$issuance_dir"
        cp "$request_file" "$issuance_dir/request.json"
        cp "$csr_path" "$issuance_dir/$csr_file"
        cp "$out_dir/$basename.cert.pem" "$issuance_dir/$basename.cert.pem"
        cp "$out_dir/chain.pem" "$issuance_dir/chain.pem"
        cp "$out_dir/metadata.json" "$issuance_dir/metadata.json"
        if [ -f "$request_dir/san-manifest.json" ]; then
          cp "$request_dir/san-manifest.json" "$issuance_dir/san-manifest.json"
        fi
        if [ -f "$request_dir/identity-manifest.json" ]; then
          cp "$request_dir/identity-manifest.json" "$issuance_dir/identity-manifest.json"
        fi
        write_request_record "$request_record_path" "$request_id" "$request_file" "$cert_serial" "$issued_at"
        write_serial_record "$(signer_state_serial_record_path "$signer_state_dir" "$cert_serial")" "$cert_serial" "$request_id" "$issued_at"
        write_issuance_record "$issuance_dir/issuance.json" "$cert_serial" "$request_id" "$request_file" "$out_dir/metadata.json" "$issuer_cert" "$issued_at"
        close_locked_fd "$signer_lock_fd"
      fi
    }

    import_signed() {
      local role=""
      local state_dir=""
      local signed_dir=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --role)
            role="$2"
            shift 2
            ;;
          --state-dir)
            state_dir="$2"
            shift 2
            ;;
          --signed-dir)
            signed_dir="$2"
            shift 2
            ;;
          *)
            die "Unknown import-signed argument: $1"
            ;;
        esac
      done

      [ -n "$role" ] || die "--role is required"
      [ -n "$state_dir" ] || die "--state-dir is required"
      [ -n "$signed_dir" ] || die "--signed-dir is required"

      require_dir "$state_dir"
      require_dir "$signed_dir"

      local basename
      local csr_path
      local cert_source
      local chain_source
      local metadata_source
      local cert_target
      local chain_target
      local metadata_target
      local import_profile

      basename="$(certificate_basename_for_role "$role")"
      cert_source="$signed_dir/$basename.cert.pem"
      chain_source="$signed_dir/chain.pem"
      metadata_source="$signed_dir/metadata.json"
      require_file "$cert_source"
      require_file "$chain_source"

      case "$role" in
        intermediate-signing-authority)
          csr_path="$state_dir/intermediate-ca.csr.pem"
          cert_target="$state_dir/intermediate-ca.cert.pem"
          chain_target="$state_dir/chain.pem"
          metadata_target="$state_dir/signer-metadata.json"
          ;;
        openvpn-server-leaf)
          csr_path="$state_dir/server.csr.pem"
          cert_target="$state_dir/server.cert.pem"
          chain_target="$state_dir/chain.pem"
          metadata_target="$state_dir/certificate-metadata.json"
          ;;
        openvpn-client-leaf)
          csr_path="$state_dir/client.csr.pem"
          cert_target="$state_dir/client.cert.pem"
          chain_target="$state_dir/chain.pem"
          metadata_target="$state_dir/certificate-metadata.json"
          ;;
        *)
          die "Unsupported role for import-signed: $role"
          ;;
      esac

      require_file "$csr_path"
      csr_matches_certificate "$csr_path" "$cert_source" || die "Signed certificate does not match the runtime CSR in $state_dir"
      openssl verify -CAfile "$chain_source" "$cert_source" >/dev/null

      cp "$cert_source" "$cert_target"
      chmod 644 "$cert_target"
      cp "$chain_source" "$chain_target"
      chmod 644 "$chain_target"

      if [ -f "$metadata_source" ]; then
        cp "$metadata_source" "$metadata_target"
        chmod 644 "$metadata_target"
      else
        import_profile="$(metadata_profile_for_import "$role")"
        write_certificate_metadata "$cert_target" "$metadata_target" "$import_profile"
        chmod 644 "$metadata_target"
      fi
    }

    generate_crl() {
      local signer_state_dir=""
      local issuer_key=""
      local issuer_cert=""
      local out_dir=""
      local days="7"

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --signer-state-dir)
            signer_state_dir="$2"
            shift 2
            ;;
          --issuer-key)
            issuer_key="$2"
            shift 2
            ;;
          --issuer-cert)
            issuer_cert="$2"
            shift 2
            ;;
          --out-dir)
            out_dir="$2"
            shift 2
            ;;
          --days)
            days="$2"
            shift 2
            ;;
          *)
            die "Unknown generate-crl argument: $1"
            ;;
        esac
      done

      [ -n "$signer_state_dir" ] || die "--signer-state-dir is required"
      [ -n "$issuer_key" ] || die "--issuer-key is required"
      [ -n "$issuer_cert" ] || die "--issuer-cert is required"
      [ -n "$out_dir" ] || die "--out-dir is required"
      require_dir "$signer_state_dir"
      require_file "$issuer_key"
      require_file "$issuer_cert"
      signer_matches_key "$issuer_key" "$issuer_cert" || die "Issuer certificate does not match issuer private key"

      local state_crl_path
      local state_crl_metadata_path
      local state_next_crl_number_path
      local crl_workdir
      local config_path
      local crl_number_seed
      local signer_lock_fd=""

      acquire_signer_state_lock "$signer_state_dir" signer_lock_fd

      state_crl_path="$(signer_state_current_crl_path "$signer_state_dir")"
      state_crl_metadata_path="$(signer_state_crl_metadata_path "$signer_state_dir")"
      state_next_crl_number_path="$(signer_state_next_crl_number_path "$signer_state_dir")"
      crl_workdir="$(mktemp -d)"

      mkdir -p "$out_dir"
      mkdir -p "$crl_workdir/newcerts"
      : > "$crl_workdir/index.txt"
      printf '%s\n' "unique_subject = no" > "$crl_workdir/index.txt.attr"
      printf '%s\n' "01" > "$crl_workdir/serial"
      crl_number_seed="$(tr -d '[:space:]' < "$state_next_crl_number_path")"
      printf '%s\n' "$(canonicalize_hex_serial "$crl_number_seed")" > "$crl_workdir/crlnumber"

      config_path="$crl_workdir/openssl.cnf"
      cat > "$config_path" <<EOF
[ ca ]
default_ca = crl_ca

[ crl_ca ]
database = $crl_workdir/index.txt
new_certs_dir = $crl_workdir/newcerts
certificate = $issuer_cert
private_key = $issuer_key
serial = $crl_workdir/serial
crlnumber = $crl_workdir/crlnumber
default_md = sha256
default_days = 365
default_crl_days = $days
unique_subject = no
policy = policy_any
copy_extensions = copy
crl_extensions = crl_ext

[ policy_any ]
commonName = supplied
stateOrProvinceName = optional
countryName = optional
organizationName = optional
organizationalUnitName = optional
emailAddress = optional

[ crl_ext ]
authorityKeyIdentifier = keyid:always
EOF

      if [ -d "$signer_state_dir/issuances" ]; then
        local issuance_dir
        for issuance_dir in "$signer_state_dir"/issuances/*; do
          [ -d "$issuance_dir" ] || continue
          local issuance_record
          local serial
          local basename
          local cert_path

          issuance_record="$issuance_dir/issuance.json"
          require_file "$issuance_record"
          serial="$(jq -r '.serial // empty' "$issuance_record")"
          basename="$(jq -r '.request.basename // empty' "$issuance_record")"
          [ -n "$serial" ] || die "Issuance record is missing serial: $issuance_record"
          [ -n "$basename" ] || die "Issuance record is missing request.basename: $issuance_record"
          cert_path="$issuance_dir/$basename.cert.pem"
          require_file "$cert_path"
          cp "$cert_path" "$crl_workdir/newcerts/$serial.pem"
          openssl ca -config "$config_path" -batch -valid "$cert_path" >/dev/null 2>&1
        done
      fi

      if [ -d "$signer_state_dir/revocations" ]; then
        local revocation_path
        for revocation_path in "$signer_state_dir"/revocations/*.json; do
          [ -f "$revocation_path" ] || continue
          local serial
          local reason
          local issuance_dir
          local issuance_record
          local basename
          local cert_path

          serial="$(jq -r '.serial // empty' "$revocation_path")"
          reason="$(jq -r '.reason // "unspecified"' "$revocation_path")"
          [ -n "$serial" ] || die "Revocation record is missing serial: $revocation_path"
          validate_crl_reason "$reason"
          issuance_dir="$(signer_state_issuance_dir "$signer_state_dir" "$serial")"
          issuance_record="$issuance_dir/issuance.json"
          require_file "$issuance_record"
          basename="$(jq -r '.request.basename // empty' "$issuance_record")"
          [ -n "$basename" ] || die "Issuance record is missing request.basename: $issuance_record"
          cert_path="$issuance_dir/$basename.cert.pem"
          require_file "$cert_path"
          openssl ca -config "$config_path" -batch -revoke "$cert_path" -crl_reason "$reason" >/dev/null 2>&1
        done
      fi

      openssl ca -config "$config_path" -batch -gencrl -out "$state_crl_path" -crldays "$days" >/dev/null 2>&1
      chmod 644 "$state_crl_path"
      cp "$crl_workdir/crlnumber" "$state_next_crl_number_path"
      write_crl_metadata "$state_crl_metadata_path" "$state_crl_path" "$issuer_cert" "$signer_state_dir"
      chmod 644 "$state_crl_metadata_path"
      cp "$state_crl_path" "$out_dir/crl.pem"
      chmod 644 "$out_dir/crl.pem"
      cp "$state_crl_metadata_path" "$out_dir/metadata.json"
      chmod 644 "$out_dir/metadata.json"
      rm -rf "$crl_workdir"
      close_locked_fd "$signer_lock_fd"
    }

    revoke_issued() {
      local signer_state_dir=""
      local serial=""
      local reason="unspecified"

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --signer-state-dir)
            signer_state_dir="$2"
            shift 2
            ;;
          --serial)
            serial="$2"
            shift 2
            ;;
          --reason)
            reason="$2"
            shift 2
            ;;
          *)
            die "Unknown revoke-issued argument: $1"
            ;;
        esac
      done

      [ -n "$signer_state_dir" ] || die "--signer-state-dir is required"
      [ -n "$serial" ] || die "--serial is required"
      require_dir "$signer_state_dir"
      validate_crl_reason "$reason"

      local issuance_dir
      local issuance_record_path
      local request_record_path
      local serial_record_path
      local revocation_record_path
      local request_id
      local revoked_at
      local update_tmp
      local signer_lock_fd=""

      acquire_signer_state_lock "$signer_state_dir" signer_lock_fd
      serial="$(signer_state_resolve_serial "$signer_state_dir" "$serial")"

      issuance_dir="$(signer_state_issuance_dir "$signer_state_dir" "$serial")"
      issuance_record_path="$issuance_dir/issuance.json"
      serial_record_path="$(signer_state_serial_record_path "$signer_state_dir" "$serial")"
      revocation_record_path="$(signer_state_revocation_record_path "$signer_state_dir" "$serial")"

      require_dir "$issuance_dir"
      require_file "$issuance_record_path"
      require_file "$serial_record_path"

      if [ -f "$revocation_record_path" ]; then
        die "Serial $serial has already been revoked"
      fi

      request_id="$(jq -r '.requestId // empty' "$issuance_record_path")"
      [ -n "$request_id" ] || die "Issuance record is missing requestId: $issuance_record_path"
      request_record_path="$(signer_state_request_record_path "$signer_state_dir" "$request_id")"
      require_file "$request_record_path"

      revoked_at="$(current_timestamp_utc)"

      jq -n \
        --arg serial "$serial" \
        --arg requestId "$request_id" \
        --arg reason "$reason" \
        --arg revokedAt "$revoked_at" \
        --arg roleId "$(jq -r '.request.roleId // empty' "$issuance_record_path")" \
        --arg subject "$(jq -r '.certificate.subject // empty' "$issuance_record_path")" \
        '{
          schemaVersion: 1,
          serial: $serial,
          requestId: $requestId,
          roleId: $roleId,
          subject: $subject,
          reason: $reason,
          revokedAt: $revokedAt,
          status: "revoked"
        }' > "$revocation_record_path"

      update_tmp="$(mktemp)"
      jq \
        --arg reason "$reason" \
        --arg revokedAt "$revoked_at" \
        '.status = "revoked" | .revocation = { reason: $reason, revokedAt: $revokedAt }' \
        "$issuance_record_path" > "$update_tmp"
      mv "$update_tmp" "$issuance_record_path"

      update_tmp="$(mktemp)"
      jq \
        --arg reason "$reason" \
        --arg revokedAt "$revoked_at" \
        '.status = "revoked" | .revocation = { reason: $reason, revokedAt: $revokedAt }' \
        "$request_record_path" > "$update_tmp"
      mv "$update_tmp" "$request_record_path"

      update_tmp="$(mktemp)"
      jq \
        --arg reason "$reason" \
        --arg revokedAt "$revoked_at" \
        '.status = "revoked" | .revocation = { reason: $reason, revokedAt: $revokedAt }' \
        "$serial_record_path" > "$update_tmp"
      mv "$update_tmp" "$serial_record_path"
      close_locked_fd "$signer_lock_fd"
    }

    [ "$#" -gt 0 ] || {
      usage
      exit 2
    }

    command="$1"
    shift

    case "$command" in
      export-request)
        export_request "$@"
        ;;
      sign-request)
        sign_request "$@"
        ;;
      import-signed)
        import_signed "$@"
        ;;
      generate-crl)
        generate_crl "$@"
        ;;
      revoke-issued)
        revoke_issued "$@"
        ;;
      -h|--help|help)
        usage
        ;;
      *)
        die "Unknown subcommand: $command"
        ;;
    esac
  '';
}
