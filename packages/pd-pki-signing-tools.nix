{ pkgs }:
pkgs.writeShellApplication {
  name = "pd-pki-signing-tools";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
    pkgs.openssl
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

    usage() {
      cat <<'EOF' >&2
Usage:
  pd-pki-signing-tools export-request --role ROLE --state-dir DIR --out-dir DIR
  pd-pki-signing-tools sign-request --request-dir DIR --out-dir DIR --issuer-key PATH --issuer-cert PATH --serial SERIAL [--days DAYS] [--issuer-chain PATH]
  pd-pki-signing-tools import-signed --role ROLE --state-dir DIR --signed-dir DIR
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
      local serial=""
      local days=""

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
          --serial)
            serial="$2"
            shift 2
            ;;
          --days)
            days="$2"
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
      [ -n "$serial" ] || die "--serial is required"

      require_dir "$request_dir"
      require_file "$issuer_key"
      require_file "$issuer_cert"
      [ -z "$issuer_chain" ] || require_file "$issuer_chain"
      require_file "$request_dir/request.json"

      signer_matches_key "$issuer_key" "$issuer_cert" || die "Issuer certificate does not match issuer private key"

      local request_file="$request_dir/request.json"
      local role
      local basename
      local csr_file
      local csr_path
      local requested_days
      local bundle_profile

      role="$(jq -r '.roleId // empty' "$request_file")"
      basename="$(jq -r '.basename // empty' "$request_file")"
      csr_file="$(jq -r '.csrFile // empty' "$request_file")"
      requested_days="$(jq -r '.requestedDays // empty' "$request_file")"

      [ -n "$role" ] || die "request.json is missing roleId"
      [ -n "$basename" ] || die "request.json is missing basename"
      [ -n "$csr_file" ] || die "request.json is missing csrFile"
      csr_path="$request_dir/$csr_file"
      if [ ! -f "$csr_path" ] && [ -f "$request_dir/csr.pem" ]; then
        csr_path="$request_dir/csr.pem"
      fi
      require_file "$csr_path"

      if [ -z "$days" ]; then
        [ -n "$requested_days" ] || die "--days is required when request.json does not declare requestedDays"
        days="$requested_days"
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
      cp "$request_file" "$out_dir/request.json"
      openssl verify -CAfile "$out_dir/chain.pem" "$out_dir/$basename.cert.pem" >/dev/null
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
      -h|--help|help)
        usage
        ;;
      *)
        die "Unknown subcommand: $command"
        ;;
    esac
  '';
}
