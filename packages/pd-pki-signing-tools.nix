{ pkgs }:
pkgs.writeShellApplication {
  name = "pd-pki-signing-tools";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
    pkgs.libp11
    pkgs.opensc
    pkgs.openssl
    pkgs.yubikey-manager
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

    require_command() {
      command -v "$1" >/dev/null 2>&1 || die "Required command not found in PATH: $1"
    }

    require_executable() {
      [ -x "$1" ] || die "Required executable not found or not executable: $1"
    }

    require_ykman_command() {
      if [ -n "''${PD_PKI_YKMAN_BIN:-}" ]; then
        require_executable "$PD_PKI_YKMAN_BIN"
      else
        require_command ykman
      fi
    }

    run_ykman() {
      if [ -n "''${PD_PKI_YKMAN_BIN:-}" ]; then
        "$PD_PKI_YKMAN_BIN" "$@"
      else
        ykman "$@"
      fi
    }

    require_file() {
      local path="$1"
      [ -f "$path" ] || die "Required file not found: $path"
    }

    require_dir() {
      local path="$1"
      [ -d "$path" ] || die "Required directory not found: $path"
    }

    file_uri_for_path() {
      local path="$1"
      jq -rn --arg value "$path" '$value | @uri' | sed 's#^#file:#'
    }

    trim_whitespace() {
      printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    }

    pkcs11_uri_has_pin_directive() {
      case "$1" in
        *";pin-source="*|*";pin-value="*) return 0 ;;
        *) return 1 ;;
      esac
    }

    pkcs11_uri_attribute() {
      local uri="$1"
      local attribute_name="$2"
      local uri_body=""
      local component=""
      local key=""

      case "$uri" in
        pkcs11:*)
          uri_body="''${uri#pkcs11:}"
          ;;
        *)
          return 1
          ;;
      esac

      local IFS=';'
      for component in $uri_body; do
        key="''${component%%=*}"
        [ "$key" = "$component" ] && continue
        if [ "$key" = "$attribute_name" ]; then
          printf '%s\n' "''${component#*=}"
          return 0
        fi
      done

      return 1
    }

    pkcs11_uri_with_pin_source() {
      local issuer_key_uri="$1"
      local pin_file="$2"
      printf '%s;%s\n' "$issuer_key_uri" "pin-source=$(file_uri_for_path "$pin_file")"
    }

    prepare_signer_backend() {
      local issuer_key="$1"
      local issuer_key_uri="$2"
      local pkcs11_module="$3"
      local pkcs11_pin_file="$4"
      local backend_var_name="$5"
      local key_ref_var_name="$6"
      local selected_backend=""
      local selected_key_ref=""
      local normalized_pkcs11_pin_file=""

      if [ -n "$issuer_key" ] && [ -n "$issuer_key_uri" ]; then
        die "--issuer-key cannot be combined with --issuer-key-uri"
      fi
      if [ -z "$issuer_key" ] && [ -z "$issuer_key_uri" ]; then
        die "Either --issuer-key or --issuer-key-uri is required"
      fi

      if [ -n "$issuer_key" ]; then
        [ -z "$pkcs11_module" ] || die "--pkcs11-module can only be used with --issuer-key-uri"
        [ -z "$pkcs11_pin_file" ] || die "--pkcs11-pin-file can only be used with --issuer-key-uri"
        require_file "$issuer_key"
        unset PD_PKI_PKCS11_PROVIDER_DIR PD_PKI_PKCS11_ENGINE_DIR PD_PKI_PKCS11_MODULE_PATH PD_PKI_PKCS11_PIN_SOURCE_FILE || true
        selected_backend="file"
        selected_key_ref="$issuer_key"
      else
        case "$issuer_key_uri" in
          pkcs11:*)
            ;;
          *)
            die "--issuer-key-uri must use the pkcs11: URI scheme"
            ;;
        esac
        [ -n "$pkcs11_module" ] || die "--pkcs11-module is required with --issuer-key-uri"
        require_file "$pkcs11_module"
        if [ -n "$pkcs11_pin_file" ]; then
          require_file "$pkcs11_pin_file"
        fi
        if [ -n "$pkcs11_pin_file" ] && pkcs11_uri_has_pin_directive "$issuer_key_uri"; then
          die "--pkcs11-pin-file cannot be combined with a pin already embedded in --issuer-key-uri"
        fi
        if [ -n "$pkcs11_pin_file" ]; then
          normalized_pkcs11_pin_file="$(mktemp "''${TMPDIR:-/tmp}/pd-pki-pkcs11-pin.XXXXXX")"
          chmod 600 "$normalized_pkcs11_pin_file"
          printf '%s' "$(read_trimmed_file_value "$pkcs11_pin_file" "PKCS#11 PIN")" > "$normalized_pkcs11_pin_file"
          export PD_PKI_PKCS11_PIN_SOURCE_FILE="$normalized_pkcs11_pin_file"
          trap 'rm -f "''${PD_PKI_PKCS11_PIN_SOURCE_FILE:-}"' EXIT
          selected_key_ref="$(pkcs11_uri_with_pin_source "$issuer_key_uri" "$normalized_pkcs11_pin_file")"
        else
          selected_key_ref="$issuer_key_uri"
        fi
        export PD_PKI_PKCS11_ENGINE_DIR="${pkgs.libp11}/lib/engines"
        export PD_PKI_PKCS11_MODULE_PATH="$pkcs11_module"
        selected_backend="pkcs11"
      fi

      printf -v "$backend_var_name" '%s' "$selected_backend"
      printf -v "$key_ref_var_name" '%s' "$selected_key_ref"
    }

    read_trimmed_file_value() {
      local path="$1"
      local label="$2"
      local value=""

      require_file "$path"
      value="$(tr -d '\r\n' < "$path")"
      [ -n "$value" ] || die "$label file is empty: $path"
      printf '%s\n' "$value"
    }

    validate_length_range() {
      local value="$1"
      local label="$2"
      local minimum="$3"
      local maximum="$4"
      local length="''${#value}"

      [ "$length" -ge "$minimum" ] || die "$label must be at least $minimum characters"
      [ "$length" -le "$maximum" ] || die "$label must be at most $maximum characters"
    }

    validate_hex_value() {
      local value="$1"
      local label="$2"
      local expected_length="$3"

      [ "''${#value}" -eq "$expected_length" ] || die "$label must be exactly $expected_length hexadecimal characters"
      case "$value" in
        *[!0-9A-Fa-f]*)
          die "$label must contain only hexadecimal characters"
          ;;
      esac
    }

    require_absolute_path() {
      local path="$1"
      local label="$2"

      case "$path" in
        /*)
          ;;
        *)
          die "$label must be an absolute path: $path"
          ;;
      esac
    }

    canonicalize_path() {
      realpath -m -- "$1"
    }

    path_is_within() {
      local path=""
      local base=""

      path="$(canonicalize_path "$1")"
      base="$(canonicalize_path "$2")"

      [ "$path" = "$base" ] && return 0
      case "$path" in
        "$base"/*) return 0 ;;
        *) return 1 ;;
      esac
    }

    directory_has_entries() {
      local path="$1"
      local first_entry=""

      [ -d "$path" ] || return 1
      first_entry="$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)"
      [ -n "$first_entry" ]
    }

    root_yubikey_requires_factory_fresh_state() {
      cat >&2 <<'EOF'
Refusing to continue without --force-reset because the YubiKey does not appear factory-fresh. Re-run with --force-reset only if destroy-and-replace is approved, or use the manual YubiKey SOP to inspect and recover the token safely.
EOF
      exit 1
    }

    root_yubikey_piv_info_indicates_initialized() {
      local piv_info_path="$1"

      awk '
        /^[[:space:]]*CHUID:[[:space:]]*/ {
          if ($0 !~ /No data available[[:space:]]*$/) initialized=1
        }
        /^[[:space:]]*CCC:[[:space:]]*/ {
          if ($0 !~ /No data available[[:space:]]*$/) initialized=1
        }
        /^[[:space:]]*Slot [0-9A-Fa-f][0-9A-Fa-f]:[[:space:]]*$/ {
          initialized=1
        }
        END {
          exit initialized ? 0 : 1
        }
      ' "$piv_info_path"
    }

    validate_owner_only_file_permissions() {
      local path="$1"
      local label="$2"
      local mode=""
      local permission_bits=0

      require_file "$path"
      [ -r "$path" ] || die "$label file is not readable: $path"
      mode="$(stat -c '%a' "$path")"
      permission_bits=$((8#$mode))
      [ $((permission_bits & 0400)) -ne 0 ] || die "$label file must be owner-readable: $path"
      [ $((permission_bits & 077)) -eq 0 ] || die "$label file permissions are too broad; expected owner-only access: $path"
    }

    validate_yubikey_serial() {
      local serial="$1"

      validate_unsigned_decimal "$serial" "--yubikey-serial"
      [ "$serial" != "0" ] || die "--yubikey-serial must be greater than zero"
    }

    validate_not_factory_default() {
      local value="$1"
      local label="$2"
      local factory_default="$3"

      [ "$value" != "$factory_default" ] || die "$label must not use the factory-default value"
    }

    file_sha256() {
      sha256sum "$1" | cut -d' ' -f1
    }

    validate_root_yubikey_profile() {
      local profile_path="$1"
      local subject=""
      local slot=""
      local pkcs11_module_path=""
      local pkcs11_provider_directory=""
      local certificate_install_path=""
      local archive_base_directory=""

      require_file "$profile_path"
      jq -e '
        (.schemaVersion // 0) == 1 and
        (.profileKind // "") == "root-yubikey-initialization" and
        (.roleId // "") == "root-certificate-authority" and
        (.subject | type == "string" and startswith("/")) and
        (.validityDays | type == "number" and . > 0) and
        (.slot | type == "string" and length > 0) and
        (.algorithm | type == "string" and length > 0) and
        (.pinPolicy | type == "string" and length > 0) and
        (.touchPolicy | type == "string" and length > 0) and
        (.pkcs11ModulePath | type == "string" and length > 0) and
        (.pkcs11ProviderDirectory | type == "string" and length > 0) and
        (.certificateInstallPath | type == "string" and length > 0) and
        (.archiveBaseDirectory | type == "string" and length > 0)
      ' "$profile_path" >/dev/null || die "Invalid root YubiKey initialization profile: $profile_path"

      subject="$(jq -r '.subject' "$profile_path")"
      slot="$(jq -r '.slot' "$profile_path")"
      pkcs11_module_path="$(jq -r '.pkcs11ModulePath' "$profile_path")"
      pkcs11_provider_directory="$(jq -r '.pkcs11ProviderDirectory' "$profile_path")"
      certificate_install_path="$(jq -r '.certificateInstallPath' "$profile_path")"
      archive_base_directory="$(jq -r '.archiveBaseDirectory' "$profile_path")"

      case "$subject" in
        *$'\n'*|*$'\r'*)
          die "Root YubiKey subject must be a single-line OpenSSL slash subject"
          ;;
      esac
      root_yubikey_slot_object_id "$slot" >/dev/null
      require_absolute_path "$pkcs11_module_path" "Profile pkcs11ModulePath"
      require_absolute_path "$pkcs11_provider_directory" "Profile pkcs11ProviderDirectory"
      require_file "$pkcs11_module_path"
      require_dir "$pkcs11_provider_directory"
      require_absolute_path "$certificate_install_path" "Profile certificateInstallPath"
      require_absolute_path "$archive_base_directory" "Profile archiveBaseDirectory"
    }

    root_yubikey_slot_object_id() {
      local slot=""
      slot="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

      case "$slot" in
        9a) printf '%s\n' "%01" ;;
        9c) printf '%s\n' "%02" ;;
        9d) printf '%s\n' "%03" ;;
        9e) printf '%s\n' "%04" ;;
        82) printf '%s\n' "%05" ;;
        83) printf '%s\n' "%06" ;;
        84) printf '%s\n' "%07" ;;
        85) printf '%s\n' "%08" ;;
        86) printf '%s\n' "%09" ;;
        87) printf '%s\n' "%0A" ;;
        88) printf '%s\n' "%0B" ;;
        89) printf '%s\n' "%0C" ;;
        8a) printf '%s\n' "%0D" ;;
        8b) printf '%s\n' "%0E" ;;
        8c) printf '%s\n' "%0F" ;;
        8d) printf '%s\n' "%10" ;;
        8e) printf '%s\n' "%11" ;;
        8f) printf '%s\n' "%12" ;;
        90) printf '%s\n' "%13" ;;
        91) printf '%s\n' "%14" ;;
        92) printf '%s\n' "%15" ;;
        93) printf '%s\n' "%16" ;;
        94) printf '%s\n' "%17" ;;
        95) printf '%s\n' "%18" ;;
        *)
          die "Unsupported YubiKey PIV slot for PKCS#11 URI derivation: $1"
          ;;
      esac
    }

    root_yubikey_pkcs11_base_uri() {
      local slot="$1"
      printf 'pkcs11:token=YubiKey%%20PIV;id=%s;type=private\n' "$(root_yubikey_slot_object_id "$slot")"
    }

    pkcs11_private_key_uri_matches_root_slot() {
      local uri="$1"
      local slot="$2"
      local type=""
      local object_id=""

      type="$(pkcs11_uri_attribute "$uri" type 2>/dev/null || true)"
      [ "$type" = "private" ] || return 1

      object_id="$(pkcs11_uri_attribute "$uri" id 2>/dev/null || true)"
      [ "$object_id" = "$(root_yubikey_slot_object_id "$slot")" ]
    }

    discover_pkcs11_private_key_uri() {
      local module_path="$1"
      local pin="$2"
      local slot="$3"
      local output=""
      local line=""
      local uri=""

      require_command pkcs11-tool
      [ -f "$module_path" ] || return 1

      output="$(pkcs11-tool --module "$module_path" --login --pin "$pin" --list-objects --type privkey 2>/dev/null || true)"
      [ -n "$output" ] || return 1

      while IFS= read -r line; do
        case "$line" in
          "  uri:"*)
            uri="$(trim_whitespace "''${line#*:}")"
            if pkcs11_private_key_uri_matches_root_slot "$uri" "$slot"; then
              printf '%s\n' "$uri"
              return 0
            fi
            ;;
        esac
      done <<< "$output"

      return 1
    }

    root_yubikey_openssl_digest() {
      local algorithm=""
      algorithm="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"

      case "$algorithm" in
        ECCP384) printf '%s\n' "sha384" ;;
        *) printf '%s\n' "sha256" ;;
      esac
    }

    subject_to_rfc4514() {
      local subject="$1"
      local tmpdir=""
      local key_path=""
      local csr_path=""
      local converted=""

      case "$subject" in
        /*)
          tmpdir="$(mktemp -d "''${TMPDIR:-/tmp}/pd-pki-subject.XXXXXX")"
          key_path="$tmpdir/key.pem"
          csr_path="$tmpdir/subject.csr.pem"
          if ! openssl req -new -newkey rsa:2048 -nodes \
            -subj "$subject" \
            -keyout "$key_path" \
            -out "$csr_path" >/dev/null 2>&1; then
            rm -rf "$tmpdir"
            die "Failed to convert OpenSSL subject to RFC 4514 form: $subject"
          fi
          converted="$(openssl req -in "$csr_path" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')" ||
            {
              rm -rf "$tmpdir"
              die "Failed to read converted RFC 4514 subject for: $subject"
            }
          rm -rf "$tmpdir"
          [ -n "$converted" ] || die "Converted RFC 4514 subject is empty for: $subject"
          printf '%s\n' "$converted"
          ;;
        *)
          printf '%s\n' "$subject"
          ;;
      esac
    }

    generate_root_yubikey_certificate() {
      local yubikey_serial="$1"
      local slot="$2"
      local public_key_path="$3"
      local subject="$4"
      local valid_days="$5"
      local digest="$6"
      local pin="$7"
      local management_key="$8"
      local certificate_path="$9"

      local pythonpath="${pkgs.python3.pkgs.makePythonPath [ pkgs.yubikey-manager ]}"

      PYTHONNOUSERSITE=true \
      PYTHONPATH="$pythonpath" \
      "${pkgs.python3}/bin/python3" "${./root-yubikey-selfsign.py}" \
        --yubikey-serial "$yubikey_serial" \
        --slot "$slot" \
        --public-key "$public_key_path" \
        --subject "$(subject_to_rfc4514 "$subject")" \
        --valid-days "$valid_days" \
        --hash-algorithm "$digest" \
        --pin "$pin" \
        --management-key-hex "$management_key" \
        --out-cert "$certificate_path"
    }

    write_root_ca_openssl_config() {
      local target="$1"

      cat > "$target" <<'EOF'
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3_root_ca

[ dn ]
CN = placeholder

[ v3_root_ca ]
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
    }

    write_root_yubikey_init_plan() {
      local target="$1"
      local mode="$2"
      local profile_path="$3"
      local yubikey_serial="$4"
      local force_reset="$5"
      local pin_retries_json="$6"
      local puk_retries_json="$7"
      local subject="$8"
      local validity_days="$9"
      local slot="''${10}"
      local algorithm="''${11}"
      local pin_policy="''${12}"
      local touch_policy="''${13}"
      local pkcs11_module_path="''${14}"
      local pkcs11_provider_directory="''${15}"
      local routine_key_uri="''${16}"
      local certificate_install_path="''${17}"
      local archive_dir="''${18}"
      local work_dir="''${19}"
      local config_path="''${20}"
      local public_key_path="''${21}"
      local attestation_path="''${22}"
      local certificate_path="''${23}"
      local token_export_path="''${24}"
      local verified_public_key_path="''${25}"
      local metadata_path="''${26}"
      local key_uri_path="''${27}"
      local summary_path="''${28}"

      jq -n \
        --arg mode "$mode" \
        --arg profilePath "$profile_path" \
        --arg yubikeySerial "$yubikey_serial" \
        --arg subject "$subject" \
        --arg validityDays "$validity_days" \
        --arg slot "$slot" \
        --arg algorithm "$algorithm" \
        --arg pinPolicy "$pin_policy" \
        --arg touchPolicy "$touch_policy" \
        --arg pkcs11ModulePath "$pkcs11_module_path" \
        --arg pkcs11ProviderDirectory "$pkcs11_provider_directory" \
        --arg routineKeyUri "$routine_key_uri" \
        --arg certificateInstallPath "$certificate_install_path" \
        --arg archiveDirectory "$archive_dir" \
        --arg workDir "$work_dir" \
        --arg opensslConfig "$config_path" \
        --arg publicKey "$public_key_path" \
        --arg attestationCertificate "$attestation_path" \
        --arg certificate "$certificate_path" \
        --arg tokenExportCertificate "$token_export_path" \
        --arg verifiedPublicKey "$verified_public_key_path" \
        --arg metadata "$metadata_path" \
        --arg keyUriFile "$key_uri_path" \
        --arg summary "$summary_path" \
        --argjson forceReset "$force_reset" \
        --argjson pinRetries "$pin_retries_json" \
        --argjson pukRetries "$puk_retries_json" \
        '{
          schemaVersion: 1,
          command: "init-root-yubikey",
          mode: $mode,
          profilePath: $profilePath,
          yubikeySerial: $yubikeySerial,
          forceReset: $forceReset,
          pinRetries: $pinRetries,
          pukRetries: $pukRetries,
          subject: $subject,
          validityDays: ($validityDays | tonumber),
          slot: $slot,
          algorithm: $algorithm,
          pinPolicy: $pinPolicy,
          touchPolicy: $touchPolicy,
          pkcs11ModulePath: $pkcs11ModulePath,
          pkcs11ProviderDirectory: $pkcs11ProviderDirectory,
          routineKeyUri: $routineKeyUri,
          certificateInstallPath: $certificateInstallPath,
          archiveDirectory: $archiveDirectory,
          workDir: $workDir,
          artifacts: {
            opensslConfig: $opensslConfig,
            publicKey: $publicKey,
            attestationCertificate: $attestationCertificate,
            certificate: $certificate,
            tokenExportCertificate: $tokenExportCertificate,
            verifiedPublicKey: $verifiedPublicKey,
            metadata: $metadata,
            keyUriFile: $keyUriFile,
            summary: $summary
          }
        }' > "$target"
    }

    write_root_yubikey_init_summary() {
      local target="$1"
      local yubikey_serial="$2"
      local force_reset_applied="$3"
      local slot="$4"
      local routine_key_uri="$5"
      local certificate_path="$6"
      local attestation_path="$7"
      local certificate_install_path="$8"
      local archive_dir="$9"
      local profile_path="''${10}"
      local reviewed_plan_path="''${11}"

      jq -n \
        --arg completedAt "$(current_timestamp_utc)" \
        --arg yubikeySerial "$yubikey_serial" \
        --argjson forceResetApplied "$force_reset_applied" \
        --arg slot "$slot" \
        --arg routineKeyUri "$routine_key_uri" \
        --arg certificateInstallPath "$certificate_install_path" \
        --arg archiveDirectory "$archive_dir" \
        --arg profilePath "$profile_path" \
        --arg reviewedPlanPath "$reviewed_plan_path" \
        --arg reviewedPlanSha256 "$(file_sha256 "$reviewed_plan_path")" \
        --arg subject "$(certificate_subject "$certificate_path")" \
        --arg serial "$(certificate_serial "$certificate_path")" \
        --arg fingerprint "$(certificate_fingerprint "$certificate_path")" \
        --arg notBefore "$(certificate_not_before "$certificate_path")" \
        --arg notAfter "$(certificate_not_after "$certificate_path")" \
        --arg attestationFingerprint "$(certificate_fingerprint "$attestation_path")" \
        '{
          schemaVersion: 1,
          command: "init-root-yubikey",
          completedAt: $completedAt,
          yubikeySerial: $yubikeySerial,
          forceResetApplied: $forceResetApplied,
          slot: $slot,
          routineKeyUri: $routineKeyUri,
          profilePath: $profilePath,
          reviewedPlan: {
            path: $reviewedPlanPath,
            sha256: $reviewedPlanSha256
          },
          certificateInstallPath: $certificateInstallPath,
          archiveDirectory: $archiveDirectory,
          certificate: {
            subject: $subject,
            serial: $serial,
            sha256Fingerprint: $fingerprint,
            notBefore: $notBefore,
            notAfter: $notAfter
          },
          attestation: {
            sha256Fingerprint: $attestationFingerprint
          }
        }' > "$target"
    }

    normalize_sha256_fingerprint() {
      local value="$1"

      printf '%s' "$value" | tr -d ':' | tr '[:upper:]' '[:lower:]'
    }

    validate_root_inventory_summary() {
      local summary_path="$1"
      local certificate_path="$2"
      local attestation_path="$3"

      require_file "$summary_path"
      jq -e '
        (.schemaVersion // 0) == 1 and
        (.command // "") == "init-root-yubikey" and
        (.yubikeySerial | type == "string" and length > 0) and
        (.slot | type == "string" and length > 0) and
        (.routineKeyUri | type == "string" and length > 0) and
        (.certificate.subject | type == "string" and length > 0) and
        (.certificate.serial | type == "string" and length > 0) and
        (.certificate.sha256Fingerprint | type == "string" and length > 0) and
        (.certificate.notBefore | type == "string" and length > 0) and
        (.certificate.notAfter | type == "string" and length > 0) and
        (.attestation.sha256Fingerprint | type == "string" and length > 0)
      ' "$summary_path" >/dev/null || die "Invalid root YubiKey initialization summary: $summary_path"

      jq -e \
        --arg subject "$(certificate_subject "$certificate_path")" \
        --arg serial "$(certificate_serial "$certificate_path")" \
        --arg sha256Fingerprint "$(certificate_fingerprint "$certificate_path")" \
        --arg notBefore "$(certificate_not_before "$certificate_path")" \
        --arg notAfter "$(certificate_not_after "$certificate_path")" \
        --arg attestationFingerprint "$(certificate_fingerprint "$attestation_path")" \
        '
          .certificate.subject == $subject and
          .certificate.serial == $serial and
          .certificate.sha256Fingerprint == $sha256Fingerprint and
          .certificate.notBefore == $notBefore and
          .certificate.notAfter == $notAfter and
          .attestation.sha256Fingerprint == $attestationFingerprint
        ' "$summary_path" >/dev/null || die "Root YubiKey initialization summary does not match the provided certificate artifacts: $summary_path"

      local routine_key_uri=""
      local slot=""

      routine_key_uri="$(jq -r '.routineKeyUri' "$summary_path")"
      slot="$(jq -r '.slot' "$summary_path")"
      pkcs11_uri_has_pin_directive "$routine_key_uri" && die "Root YubiKey initialization summary must not include an embedded PIN directive: $summary_path"
      pkcs11_private_key_uri_matches_root_slot "$routine_key_uri" "$slot" ||
        die "Root YubiKey initialization summary routineKeyUri does not identify the expected private key slot: $summary_path"
    }

    write_root_inventory_manifest() {
      local target="$1"
      local certificate_path="$2"
      local verified_public_key_path="$3"
      local attestation_path="$4"
      local metadata_path="$5"
      local summary_path="$6"
      local key_uri_path="$7"

      jq -n \
        --arg rootId "$(normalize_sha256_fingerprint "$(certificate_fingerprint "$certificate_path")")" \
        --arg serial "$(jq -r '.yubikeySerial' "$summary_path")" \
        --arg slot "$(jq -r '.slot' "$summary_path")" \
        --arg routineKeyUri "$(tr -d '\r\n' < "$key_uri_path")" \
        --arg certificatePath "$(basename "$certificate_path")" \
        --arg subject "$(certificate_subject "$certificate_path")" \
        --arg certificateSerial "$(certificate_serial "$certificate_path")" \
        --arg certificateFingerprint "$(certificate_fingerprint "$certificate_path")" \
        --arg notBefore "$(certificate_not_before "$certificate_path")" \
        --arg notAfter "$(certificate_not_after "$certificate_path")" \
        --arg verifiedPublicKeyPath "$(basename "$verified_public_key_path")" \
        --arg verifiedPublicKeySha256 "$(file_sha256 "$verified_public_key_path")" \
        --arg attestationPath "$(basename "$attestation_path")" \
        --arg attestationFingerprint "$(certificate_fingerprint "$attestation_path")" \
        --arg metadataPath "$(basename "$metadata_path")" \
        --arg metadataProfile "$(jq -r '.profile' "$metadata_path")" \
        --arg summaryPath "$(basename "$summary_path")" \
        '{
          schemaVersion: 1,
          contractKind: "root-ca-inventory",
          rootId: $rootId,
          source: {
            command: "init-root-yubikey",
            profileKind: "root-yubikey-initialization"
          },
          yubiKey: {
            serial: $serial,
            slot: $slot,
            routineKeyUri: $routineKeyUri
          },
          certificate: {
            path: $certificatePath,
            subject: $subject,
            serial: $certificateSerial,
            sha256Fingerprint: $certificateFingerprint,
            notBefore: $notBefore,
            notAfter: $notAfter
          },
          verifiedPublicKey: {
            path: $verifiedPublicKeyPath,
            sha256: $verifiedPublicKeySha256
          },
          attestation: {
            path: $attestationPath,
            sha256Fingerprint: $attestationFingerprint
          },
          metadata: {
            path: $metadataPath,
            profile: $metadataProfile
          },
          ceremony: {
            summaryPath: $summaryPath
          }
        }' > "$target"
    }

    validate_root_inventory_manifest() {
      local manifest_path="$1"
      local certificate_path="$2"
      local verified_public_key_path="$3"
      local attestation_path="$4"
      local metadata_path="$5"
      local summary_path="$6"
      local key_uri_path="$7"
      local root_id=""
      local normalized_fingerprint=""
      local routine_key_uri=""

      require_file "$manifest_path"
      jq -e '
        (.schemaVersion // 0) == 1 and
        (.contractKind // "") == "root-ca-inventory" and
        (.rootId | type == "string" and length > 0) and
        (.source.command // "") == "init-root-yubikey" and
        (.source.profileKind // "") == "root-yubikey-initialization" and
        (.yubiKey.serial | type == "string" and length > 0) and
        (.yubiKey.slot | type == "string" and length > 0) and
        (.yubiKey.routineKeyUri | type == "string" and length > 0) and
        (.certificate.path // "") == "root-ca.cert.pem" and
        (.verifiedPublicKey.path // "") == "root-ca.pub.verified.pem" and
        (.attestation.path // "") == "root-ca.attestation.cert.pem" and
        (.metadata.path // "") == "root-ca.metadata.json" and
        (.metadata.profile // "") == "root-ca-yubikey-initialized" and
        (.ceremony.summaryPath // "") == "root-yubikey-init-summary.json"
      ' "$manifest_path" >/dev/null || die "Invalid root inventory manifest: $manifest_path"

      root_id="$(jq -r '.rootId' "$manifest_path")"
      normalized_fingerprint="$(normalize_sha256_fingerprint "$(certificate_fingerprint "$certificate_path")")"
      [ "$root_id" = "$normalized_fingerprint" ] ||
        die "Root inventory manifest rootId does not match the root certificate fingerprint: $manifest_path"

      jq -e \
        --arg subject "$(certificate_subject "$certificate_path")" \
        --arg serial "$(certificate_serial "$certificate_path")" \
        --arg sha256Fingerprint "$(certificate_fingerprint "$certificate_path")" \
        --arg notBefore "$(certificate_not_before "$certificate_path")" \
        --arg notAfter "$(certificate_not_after "$certificate_path")" \
        --arg verifiedPublicKeySha256 "$(file_sha256 "$verified_public_key_path")" \
        --arg attestationFingerprint "$(certificate_fingerprint "$attestation_path")" \
        '
          .certificate.subject == $subject and
          .certificate.serial == $serial and
          .certificate.sha256Fingerprint == $sha256Fingerprint and
          .certificate.notBefore == $notBefore and
          .certificate.notAfter == $notAfter and
          .verifiedPublicKey.sha256 == $verifiedPublicKeySha256 and
          .attestation.sha256Fingerprint == $attestationFingerprint
        ' "$manifest_path" >/dev/null || die "Root inventory manifest does not match the provided root inventory artifacts: $manifest_path"

      validate_certificate_metadata "$metadata_path" "$certificate_path" || die "Root inventory metadata does not match the root certificate: $metadata_path"
      validate_root_inventory_summary "$summary_path" "$certificate_path" "$attestation_path"

      routine_key_uri="$(tr -d '\r\n' < "$key_uri_path")"
      [ -n "$routine_key_uri" ] || die "Root inventory key URI file is empty: $key_uri_path"
      pkcs11_uri_has_pin_directive "$routine_key_uri" && die "Root inventory key URI must not include an embedded PIN directive: $key_uri_path"
      [ "$(jq -r '.yubiKey.serial' "$manifest_path")" = "$(jq -r '.yubikeySerial' "$summary_path")" ] ||
        die "Root inventory manifest YubiKey serial does not match the initialization summary: $manifest_path"
      [ "$(jq -r '.yubiKey.slot' "$manifest_path")" = "$(jq -r '.slot' "$summary_path")" ] ||
        die "Root inventory manifest slot does not match the initialization summary: $manifest_path"
      [ "$routine_key_uri" = "$(jq -r '.yubiKey.routineKeyUri' "$manifest_path")" ] ||
        die "Root inventory key URI file does not match manifest metadata: $key_uri_path"
      pkcs11_private_key_uri_matches_root_slot "$routine_key_uri" "$(jq -r '.yubiKey.slot' "$manifest_path")" ||
        die "Root inventory key URI file does not identify the manifest's root private key slot: $key_uri_path"
      [ "$routine_key_uri" = "$(jq -r '.routineKeyUri' "$summary_path")" ] ||
        die "Root inventory key URI file does not match the initialization summary: $key_uri_path"
    }

    root_inventory_id_for_certificate() {
      local certificate_path="$1"

      normalize_sha256_fingerprint "$(certificate_fingerprint "$certificate_path")"
    }

    validate_root_inventory_source_artifacts() {
      local source_dir="$1"
      local certificate_path="$source_dir/root-ca.cert.pem"
      local verified_public_key_path="$source_dir/root-ca.pub.verified.pem"
      local attestation_path="$source_dir/root-ca.attestation.cert.pem"
      local metadata_path="$source_dir/root-ca.metadata.json"
      local summary_path="$source_dir/root-yubikey-init-summary.json"
      local key_uri_path="$source_dir/root-key-uri.txt"
      local manifest_path="$source_dir/manifest.json"
      local routine_key_uri=""
      local expected_routine_key_uri=""
      local certificate_pubkey=""
      local verified_public_key_pem=""

      require_file "$certificate_path"
      require_file "$verified_public_key_path"
      require_file "$attestation_path"
      require_file "$metadata_path"
      require_file "$summary_path"
      require_file "$key_uri_path"

      certificate_is_ca "$certificate_path" || die "Root inventory certificate must be a CA certificate: $certificate_path"
      validate_certificate_metadata "$metadata_path" "$certificate_path" || die "Root inventory metadata does not match the certificate: $metadata_path"
      [ "$(jq -r '.profile // empty' "$metadata_path")" = "root-ca-yubikey-initialized" ] ||
        die "Root inventory metadata profile must be root-ca-yubikey-initialized: $metadata_path"

      openssl x509 -in "$attestation_path" -noout >/dev/null 2>&1 || die "Failed to parse root attestation certificate: $attestation_path"
      validate_root_inventory_summary "$summary_path" "$certificate_path" "$attestation_path"

      routine_key_uri="$(tr -d '\r\n' < "$key_uri_path")"
      [ -n "$routine_key_uri" ] || die "Root inventory key URI file is empty: $key_uri_path"
      pkcs11_uri_has_pin_directive "$routine_key_uri" && die "Root inventory key URI must not include an embedded PIN directive: $key_uri_path"
      expected_routine_key_uri="$(jq -r '.slot' "$summary_path")"
      pkcs11_private_key_uri_matches_root_slot "$routine_key_uri" "$expected_routine_key_uri" ||
        die "Root inventory key URI does not identify the expected private key slot: $key_uri_path"
      [ "$routine_key_uri" = "$(jq -r '.routineKeyUri' "$summary_path")" ] || die "Root inventory key URI does not match the initialization summary: $key_uri_path"

      certificate_pubkey="$(certificate_public_key "$certificate_path")"
      verified_public_key_pem="$(openssl pkey -pubin -in "$verified_public_key_path" -outform pem 2>/dev/null)" ||
        die "Failed to parse verified root public key: $verified_public_key_path"
      [ "$certificate_pubkey" = "$verified_public_key_pem" ] ||
        die "Verified root public key does not match the root certificate: $verified_public_key_path"

      if [ -f "$manifest_path" ]; then
        validate_root_inventory_manifest \
          "$manifest_path" \
          "$certificate_path" \
          "$verified_public_key_path" \
          "$attestation_path" \
          "$metadata_path" \
          "$summary_path" \
          "$key_uri_path"
      fi
    }

    write_root_inventory_contract_dir() {
      local source_dir="$1"
      local target_dir="$2"
      local target_certificate_path="$target_dir/root-ca.cert.pem"
      local target_verified_public_key_path="$target_dir/root-ca.pub.verified.pem"
      local target_attestation_path="$target_dir/root-ca.attestation.cert.pem"
      local target_metadata_path="$target_dir/root-ca.metadata.json"
      local target_summary_path="$target_dir/root-yubikey-init-summary.json"
      local target_key_uri_path="$target_dir/root-key-uri.txt"
      local target_manifest_path="$target_dir/manifest.json"

      if directory_has_entries "$target_dir"; then
        die "Root inventory destination already exists and is not empty: $target_dir"
      fi

      install -d -m 755 "$target_dir"
      install -m 644 "$source_dir/root-ca.cert.pem" "$target_certificate_path"
      install -m 644 "$source_dir/root-ca.pub.verified.pem" "$target_verified_public_key_path"
      install -m 644 "$source_dir/root-ca.attestation.cert.pem" "$target_attestation_path"
      install -m 644 "$source_dir/root-ca.metadata.json" "$target_metadata_path"
      install -m 644 "$source_dir/root-yubikey-init-summary.json" "$target_summary_path"
      install -m 644 "$source_dir/root-key-uri.txt" "$target_key_uri_path"
      write_root_inventory_manifest \
        "$target_manifest_path" \
        "$target_certificate_path" \
        "$target_verified_public_key_path" \
        "$target_attestation_path" \
        "$target_metadata_path" \
        "$target_summary_path" \
        "$target_key_uri_path"

      validate_root_inventory_manifest \
        "$target_manifest_path" \
        "$target_certificate_path" \
        "$target_verified_public_key_path" \
        "$target_attestation_path" \
        "$target_metadata_path" \
        "$target_summary_path" \
        "$target_key_uri_path"
    }

    write_root_yubikey_identity_summary() {
      local target="$1"
      local inventory_dir="$2"
      local inventory_manifest_path="$3"
      local inventory_serial="$4"
      local yubikey_serial="$5"
      local slot="$6"
      local routine_key_uri="$7"
      local token_certificate_path="$8"
      local token_public_key_path="$9"

      jq -n \
        --arg verifiedAt "$(current_timestamp_utc)" \
        --arg inventoryDir "$inventory_dir" \
        --arg manifestPath "$inventory_manifest_path" \
        --arg rootId "$(jq -r '.rootId' "$inventory_manifest_path")" \
        --arg inventorySerial "$inventory_serial" \
        --arg yubikeySerial "$yubikey_serial" \
        --arg slot "$slot" \
        --arg routineKeyUri "$routine_key_uri" \
        --arg expectedCertificateFingerprint "$(jq -r '.certificate.sha256Fingerprint' "$inventory_manifest_path")" \
        --arg observedCertificateFingerprint "$(certificate_fingerprint "$token_certificate_path")" \
        --arg expectedVerifiedPublicKeySha256 "$(jq -r '.verifiedPublicKey.sha256' "$inventory_manifest_path")" \
        --arg observedVerifiedPublicKeySha256 "$(file_sha256 "$token_public_key_path")" \
        '{
          schemaVersion: 1,
          command: "verify-root-yubikey-identity",
          verifiedAt: $verifiedAt,
          inventoryDirectory: $inventoryDir,
          manifestPath: $manifestPath,
          rootId: $rootId,
          inventorySerial: $inventorySerial,
          yubikeySerial: $yubikeySerial,
          serialMatches: ($inventorySerial == $yubikeySerial),
          slot: $slot,
          routineKeyUri: $routineKeyUri,
          certificate: {
            expectedSha256Fingerprint: $expectedCertificateFingerprint,
            observedSha256Fingerprint: $observedCertificateFingerprint,
            match: ($expectedCertificateFingerprint == $observedCertificateFingerprint)
          },
          verifiedPublicKey: {
            expectedSha256: $expectedVerifiedPublicKeySha256,
            observedSha256: $observedVerifiedPublicKeySha256,
            match: ($expectedVerifiedPublicKeySha256 == $observedVerifiedPublicKeySha256)
          }
        }' > "$target"
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

    signer_public_key_pem() {
      local signer_backend="$1"
      local issuer_key_ref="$2"

      case "$signer_backend" in
        file)
          openssl pkey -in "$issuer_key_ref" -pubout -outform pem
          ;;
        pkcs11)
          openssl_with_signer_backend "$signer_backend" pkey -in "$issuer_key_ref" -pubout -outform pem 2>/dev/null |
            sed -n '/^-----BEGIN PUBLIC KEY-----$/,$p'
          ;;
        *)
          die "Unsupported signer backend for public key extraction: $signer_backend"
          ;;
      esac
    }

    signer_matches_key() {
      local signer_backend="$1"
      local issuer_key_ref="$2"
      local issuer_cert="$3"
      local key_pubkey
      local cert_pubkey

      key_pubkey="$(signer_public_key_pem "$signer_backend" "$issuer_key_ref")"
      cert_pubkey="$(openssl x509 -in "$issuer_cert" -pubkey -noout | openssl pkey -pubin -outform pem)"
      [ "$key_pubkey" = "$cert_pubkey" ]
    }

    current_timestamp_utc() {
      date -u +"%Y-%m-%dT%H:%M:%SZ"
    }

    current_timestamp_compact_utc() {
      date -u +"%Y%m%dT%H%M%SZ"
    }

    csr_public_key_algorithm() {
      local csr_path="$1"
      openssl req -in "$csr_path" -noout -text |
        sed -n 's/^[[:space:]]*Public Key Algorithm: //p' |
        head -n1
    }

    csr_rsa_bits() {
      local csr_path="$1"
      openssl req -in "$csr_path" -noout -text |
        sed -n 's/.*Public-Key: (\([0-9][0-9]*\) bit).*/\1/p' |
        head -n1
    }

    csr_key_type() {
      local csr_path="$1"
      local algorithm=""

      algorithm="$(csr_public_key_algorithm "$csr_path")"
      case "$algorithm" in
        rsaEncryption) printf '%s\n' "RSA" ;;
        id-ecPublicKey) printf '%s\n' "EC" ;;
        *)
          [ -n "$algorithm" ] || die "Unable to determine CSR public key algorithm: $csr_path"
          printf '%s\n' "$algorithm"
          ;;
      esac
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
        "$state_dir/audit" \
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

    signer_state_audit_dir() {
      local state_dir="$1"
      printf '%s\n' "$state_dir/audit"
    }

    signer_state_audit_event_path() {
      local state_dir="$1"
      local timestamp="$2"
      local event_type="$3"
      local identifier="$4"
      printf '%s\n' "$(signer_state_audit_dir "$state_dir")/''${timestamp}-''${event_type}-''${identifier}.json"
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

    validate_csr_against_policy() {
      local csr_path="$1"
      local role="$2"
      local policy_file="$3"
      local actual_key_type=""
      local minimum_rsa_bits=""
      local actual_rsa_bits=""
      local allowed_key_types=()

      [ -n "$policy_file" ] || return 0

      actual_key_type="$(csr_key_type "$csr_path")"
      mapfile -t allowed_key_types < <(jq -r --arg role "$role" '(.roles[$role].allowedKeyAlgorithms // [])[]' "$policy_file")
      if [ "''${#allowed_key_types[@]}" -gt 0 ] && ! value_in_list "$actual_key_type" "''${allowed_key_types[@]}"; then
        die "Signer policy rejected CSR key algorithm '$actual_key_type' for role $role"
      fi

      minimum_rsa_bits="$(jq -r --arg role "$role" '.roles[$role].minimumRsaBits // empty' "$policy_file")"
      if [ -n "$minimum_rsa_bits" ]; then
        validate_unsigned_decimal "$minimum_rsa_bits" "Signer policy minimumRsaBits"
        [ "$actual_key_type" = "RSA" ] || die "Signer policy minimumRsaBits requires an RSA CSR for role $role"
        actual_rsa_bits="$(csr_rsa_bits "$csr_path")"
        validate_unsigned_decimal "$actual_rsa_bits" "CSR RSA bit length"
        [ "$actual_rsa_bits" -ge "$minimum_rsa_bits" ] ||
          die "CSR RSA bit length of $actual_rsa_bits is below signer policy minimumRsaBits $minimum_rsa_bits for role $role"
      fi
    }

    validate_request_matches_csr() {
      local request_file="$1"
      local csr_path="$2"
      local role="$3"

      case "$role" in
        intermediate-signing-authority)
          validate_intermediate_csr_matches_request "$csr_path" "$request_file" ||
            die "CSR subject or CA constraints do not match request.json for role $role"
          ;;
        openvpn-server-leaf|openvpn-client-leaf)
          validate_tls_csr_matches_request "$csr_path" "$request_file" ||
            die "CSR subject, SANs, or profile do not match request.json for role $role"
          ;;
        *)
          die "Unsupported role in CSR request validation: $role"
          ;;
      esac
    }

    resolve_crl_distribution_points() {
      local role="$1"
      local policy_file="$2"

      [ -n "$policy_file" ] || return 0

      jq -r --arg role "$role" '
        (.roles[$role].crlDistributionPoints // [])
        | map(select(type == "string" and length > 0) | "URI:" + .)
        | join(",")
      ' "$policy_file"
    }

    build_approval_json() {
      local approved_by="$1"
      local approved_at="$2"
      local approval_ticket="$3"
      local approval_note="$4"

      jq -nc \
        --arg approvedBy "$approved_by" \
        --arg approvedAt "$approved_at" \
        --arg approvalTicket "$approval_ticket" \
        --arg approvalNote "$approval_note" \
        '
          {
            approvedBy: $approvedBy,
            approvedAt: $approvedAt
          }
          + (if $approvalTicket != "" then { approvalTicket: $approvalTicket } else {} end)
          + (if $approvalNote != "" then { approvalNote: $approvalNote } else {} end)
        '
    }

    build_revocation_json() {
      local revoked_by="$1"
      local revoked_at="$2"
      local reason="$3"
      local revocation_ticket="$4"
      local revocation_note="$5"

      jq -nc \
        --arg revokedBy "$revoked_by" \
        --arg revokedAt "$revoked_at" \
        --arg reason "$reason" \
        --arg revocationTicket "$revocation_ticket" \
        --arg revocationNote "$revocation_note" \
        '
          {
            revokedBy: $revokedBy,
            revokedAt: $revokedAt,
            reason: $reason
          }
          + (if $revocationTicket != "" then { revocationTicket: $revocationTicket } else {} end)
          + (if $revocationNote != "" then { revocationNote: $revocationNote } else {} end)
        '
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
      local approval_json="$6"

      jq -n \
        --arg requestId "$request_id" \
        --arg serial "$serial" \
        --arg recordedAt "$recorded_at" \
        --argjson approval "$approval_json" \
        --argjson request "$(jq -cS . "$request_file")" \
        '{
          schemaVersion: 1,
          requestId: $requestId,
          serial: $serial,
          status: "issued",
          recordedAt: $recordedAt,
          approval: $approval,
          request: $request
        }' > "$target"
    }

    write_serial_record() {
      local target="$1"
      local serial="$2"
      local request_id="$3"
      local allocated_at="$4"
      local approval_json="$5"

      jq -n \
        --arg serial "$serial" \
        --arg requestId "$request_id" \
        --arg allocatedAt "$allocated_at" \
        --argjson approval "$approval_json" \
        '{
          schemaVersion: 1,
          serial: $serial,
          requestId: $requestId,
          allocatedAt: $allocatedAt,
          approval: $approval,
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
      local approval_json="$8"

      jq -n \
        --arg serial "$serial" \
        --arg requestId "$request_id" \
        --arg issuedAt "$issued_at" \
        --arg issuerSubject "$(certificate_subject "$issuer_cert")" \
        --arg issuerFingerprint "$(certificate_fingerprint "$issuer_cert")" \
        --argjson approval "$approval_json" \
        --argjson request "$(jq -cS . "$request_file")" \
        --argjson certificate "$(jq -cS . "$metadata_file")" \
        '{
          schemaVersion: 1,
          serial: $serial,
          requestId: $requestId,
          status: "issued",
          issuedAt: $issuedAt,
          approval: $approval,
          issuer: {
            subject: $issuerSubject,
            sha256Fingerprint: $issuerFingerprint
          },
          request: $request,
          certificate: $certificate
        }' > "$target"
    }

    write_issuance_audit_event() {
      local target="$1"
      local serial="$2"
      local request_id="$3"
      local request_file="$4"
      local metadata_file="$5"
      local issuer_cert="$6"
      local recorded_at="$7"
      local approval_json="$8"

      jq -n \
        --arg eventType "issued" \
        --arg recordedAt "$recorded_at" \
        --arg serial "$serial" \
        --arg requestId "$request_id" \
        --arg issuerSubject "$(certificate_subject "$issuer_cert")" \
        --arg issuerFingerprint "$(certificate_fingerprint "$issuer_cert")" \
        --argjson approval "$approval_json" \
        --argjson request "$(jq -cS . "$request_file")" \
        --argjson certificate "$(jq -cS . "$metadata_file")" \
        '{
          schemaVersion: 1,
          eventType: $eventType,
          recordedAt: $recordedAt,
          serial: $serial,
          requestId: $requestId,
          approval: $approval,
          issuer: {
            subject: $issuerSubject,
            sha256Fingerprint: $issuerFingerprint
          },
          request: $request,
          certificate: $certificate
        }' > "$target"
    }

    write_revocation_audit_event() {
      local target="$1"
      local serial="$2"
      local request_id="$3"
      local issuance_record_path="$4"
      local revocation_json="$5"
      local recorded_at="$6"

      jq -n \
        --arg eventType "revoked" \
        --arg recordedAt "$recorded_at" \
        --arg serial "$serial" \
        --arg requestId "$request_id" \
        --argjson revocation "$revocation_json" \
        --arg roleId "$(jq -r '.request.roleId // empty' "$issuance_record_path")" \
        --arg subject "$(jq -r '.certificate.subject // empty' "$issuance_record_path")" \
        '{
          schemaVersion: 1,
          eventType: $eventType,
          recordedAt: $recordedAt,
          serial: $serial,
          requestId: $requestId,
          roleId: $roleId,
          subject: $subject,
          revocation: $revocation
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
  pd-pki-signing-tools init-root-yubikey [--profile FILE] --yubikey-serial SERIAL --work-dir DIR [--certificate-install-path PATH] [--archive-dir PATH] [--pin-retries N --puk-retries N] [--pin-file FILE --puk-file FILE --management-key-file FILE [--force-reset]] [--dry-run]
  pd-pki-signing-tools export-root-inventory --source-dir DIR --out-dir DIR
  pd-pki-signing-tools normalize-root-inventory --source-dir DIR --inventory-root DIR
  pd-pki-signing-tools verify-root-yubikey-identity --inventory-dir DIR --yubikey-serial SERIAL --pin-file FILE --work-dir DIR
  pd-pki-signing-tools export-request --role ROLE --state-dir DIR --out-dir DIR
  pd-pki-signing-tools sign-request --request-dir DIR --out-dir DIR (--issuer-key PATH | --issuer-key-uri URI --pkcs11-module PATH [--pkcs11-pin-file PATH]) --issuer-cert PATH [--days DAYS] [--issuer-chain PATH] [--policy-file PATH] [--approved-by ID] [--approval-ticket ID] [--approval-note TEXT] [--serial SERIAL | --signer-state-dir DIR]
  pd-pki-signing-tools import-signed --role ROLE --state-dir DIR --signed-dir DIR
  pd-pki-signing-tools generate-crl --signer-state-dir DIR (--issuer-key PATH | --issuer-key-uri URI --pkcs11-module PATH [--pkcs11-pin-file PATH]) --issuer-cert PATH --out-dir DIR [--days DAYS]
  pd-pki-signing-tools revoke-issued --signer-state-dir DIR --serial SERIAL [--reason REASON] [--revoked-by ID] [--revocation-ticket ID] [--revocation-note TEXT]
EOF
    }

    init_root_yubikey() {
      local profile_path="/etc/pd-pki/root-yubikey-init-profile.json"
      local yubikey_serial=""
      local work_dir=""
      local certificate_install_path=""
      local archive_dir=""
      local pin_file=""
      local puk_file=""
      local management_key_file=""
      local pin_retries=""
      local puk_retries=""
      local dry_run=0
      local force_reset=0

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --profile)
            profile_path="$2"
            shift 2
            ;;
          --yubikey-serial)
            yubikey_serial="$2"
            shift 2
            ;;
          --work-dir)
            work_dir="$2"
            shift 2
            ;;
          --certificate-install-path)
            certificate_install_path="$2"
            shift 2
            ;;
          --archive-dir)
            archive_dir="$2"
            shift 2
            ;;
          --pin-file)
            pin_file="$2"
            shift 2
            ;;
          --puk-file)
            puk_file="$2"
            shift 2
            ;;
          --management-key-file)
            management_key_file="$2"
            shift 2
            ;;
          --pin-retries)
            pin_retries="$2"
            shift 2
            ;;
          --puk-retries)
            puk_retries="$2"
            shift 2
            ;;
          --dry-run)
            dry_run=1
            shift
            ;;
          --force-reset)
            force_reset=1
            shift
            ;;
          *)
            die "Unknown init-root-yubikey argument: $1"
            ;;
        esac
      done

      [ -n "$yubikey_serial" ] || die "--yubikey-serial is required"
      [ -n "$work_dir" ] || die "--work-dir is required"
      validate_yubikey_serial "$yubikey_serial"
      validate_root_yubikey_profile "$profile_path"

      if { [ -n "$pin_retries" ] || [ -n "$puk_retries" ]; } && { [ -z "$pin_retries" ] || [ -z "$puk_retries" ]; }; then
        die "--pin-retries and --puk-retries must be provided together"
      fi
      [ -z "$pin_retries" ] || validate_unsigned_decimal "$pin_retries" "--pin-retries"
      [ -z "$puk_retries" ] || validate_unsigned_decimal "$puk_retries" "--puk-retries"
      if [ "$dry_run" = "1" ]; then
        [ "$force_reset" = "0" ] || die "--force-reset cannot be combined with --dry-run"
        [ -z "$pin_file" ] || die "--pin-file cannot be combined with --dry-run"
        [ -z "$puk_file" ] || die "--puk-file cannot be combined with --dry-run"
        [ -z "$management_key_file" ] || die "--management-key-file cannot be combined with --dry-run"
      fi

      local subject=""
      local validity_days=""
      local slot=""
      local algorithm=""
      local pin_policy=""
      local touch_policy=""
      local pkcs11_module_path=""
      local pkcs11_provider_directory=""
      local default_certificate_install_path=""
      local default_archive_base_directory=""
      local routine_key_uri=""
      local pin_retries_json="null"
      local puk_retries_json="null"
      local openssl_config_path=""
      local public_key_path=""
      local attestation_path=""
      local certificate_path=""
      local token_export_path=""
      local verified_public_key_path=""
      local metadata_path=""
      local key_uri_path=""
      local plan_path=""
      local summary_path=""
      local profile_copy_path=""
      local device_info_before_path=""
      local piv_info_before_path=""
      local device_info_after_path=""
      local piv_info_after_path=""
      local digest=""
      local expected_plan_path=""
      local reviewed_plan_hash_before=""

      subject="$(jq -r '.subject' "$profile_path")"
      validity_days="$(jq -r '.validityDays | tostring' "$profile_path")"
      slot="$(jq -r '.slot' "$profile_path")"
      algorithm="$(jq -r '.algorithm' "$profile_path")"
      pin_policy="$(jq -r '.pinPolicy' "$profile_path")"
      touch_policy="$(jq -r '.touchPolicy' "$profile_path")"
      pkcs11_module_path="$(jq -r '.pkcs11ModulePath' "$profile_path")"
      pkcs11_provider_directory="$(jq -r '.pkcs11ProviderDirectory' "$profile_path")"
      default_certificate_install_path="$(jq -r '.certificateInstallPath' "$profile_path")"
      default_archive_base_directory="$(jq -r '.archiveBaseDirectory' "$profile_path")"

      if [ -z "$certificate_install_path" ]; then
        certificate_install_path="$default_certificate_install_path"
      fi
      if [ -z "$archive_dir" ]; then
        archive_dir="$default_archive_base_directory/root-$yubikey_serial"
      fi
      if [ -n "$pin_retries" ]; then
        pin_retries_json="$pin_retries"
        puk_retries_json="$puk_retries"
      fi

      require_absolute_path "$profile_path" "--profile"
      require_absolute_path "$work_dir" "--work-dir"
      require_absolute_path "$certificate_install_path" "Certificate install path"
      require_absolute_path "$archive_dir" "Archive directory"
      [ "$(canonicalize_path "$work_dir")" != "/" ] || die "--work-dir cannot be /"
      path_is_within "$archive_dir" "$work_dir" && die "Archive directory must not live under --work-dir"
      path_is_within "$certificate_install_path" "$work_dir" && die "Certificate install path must not live under --work-dir"

      routine_key_uri="$(root_yubikey_pkcs11_base_uri "$slot")"
      digest="$(root_yubikey_openssl_digest "$algorithm")"
      openssl_config_path="$work_dir/root-ca-openssl.cnf"
      public_key_path="$work_dir/root-ca.pub.pem"
      attestation_path="$work_dir/root-ca.attestation.cert.pem"
      certificate_path="$work_dir/root-ca.cert.pem"
      token_export_path="$work_dir/root-ca.token-export.cert.pem"
      verified_public_key_path="$work_dir/root-ca.pub.verified.pem"
      metadata_path="$work_dir/root-ca.metadata.json"
      key_uri_path="$work_dir/root-key-uri.txt"
      plan_path="$work_dir/root-yubikey-init-plan.json"
      summary_path="$work_dir/root-yubikey-init-summary.json"
      profile_copy_path="$work_dir/root-yubikey-profile.json"
      device_info_before_path="$work_dir/yubikey-device-info.before.txt"
      piv_info_before_path="$work_dir/yubikey-piv-info.before.txt"
      device_info_after_path="$work_dir/yubikey-device-info.after.txt"
      piv_info_after_path="$work_dir/yubikey-piv-info.after.txt"

      install -d -m 700 "$work_dir"
      cp "$profile_path" "$profile_copy_path"
      write_root_ca_openssl_config "$openssl_config_path"
      printf '%s\n' "$routine_key_uri" > "$key_uri_path"

      if [ "$dry_run" = "1" ]; then
        write_root_yubikey_init_plan \
          "$plan_path" \
          "dry-run" \
          "$profile_path" \
          "$yubikey_serial" \
          "false" \
          "$pin_retries_json" \
          "$puk_retries_json" \
          "$subject" \
          "$validity_days" \
          "$slot" \
          "$algorithm" \
          "$pin_policy" \
          "$touch_policy" \
          "$pkcs11_module_path" \
          "$pkcs11_provider_directory" \
          "$routine_key_uri" \
          "$certificate_install_path" \
          "$archive_dir" \
          "$work_dir" \
          "$openssl_config_path" \
          "$public_key_path" \
          "$attestation_path" \
          "$certificate_path" \
          "$token_export_path" \
          "$verified_public_key_path" \
          "$metadata_path" \
          "$key_uri_path" \
          "$summary_path"
        printf '%s\n' "Dry-run root YubiKey initialization plan written to: $plan_path"
        return
      fi

      [ -n "$pin_file" ] || die "--pin-file is required unless --dry-run is used"
      [ -n "$puk_file" ] || die "--puk-file is required unless --dry-run is used"
      [ -n "$management_key_file" ] || die "--management-key-file is required unless --dry-run is used"

      local root_pin=""
      local root_puk=""
      local root_management_key=""
      local default_management_key="010203040506070801020304050607080102030405060708"
      local ykman_algorithm=""
      local active_routine_key_uri=""

      validate_owner_only_file_permissions "$pin_file" "PIN"
      validate_owner_only_file_permissions "$puk_file" "PUK"
      validate_owner_only_file_permissions "$management_key_file" "Management key"
      path_is_within "$pin_file" "$work_dir" && die "PIN file must not live under --work-dir"
      path_is_within "$puk_file" "$work_dir" && die "PUK file must not live under --work-dir"
      path_is_within "$management_key_file" "$work_dir" && die "Management key file must not live under --work-dir"
      [ ! -e "$summary_path" ] || die "Refusing to reuse a work directory that already contains a root YubiKey initialization summary: $summary_path"
      if directory_has_entries "$archive_dir"; then
        die "Archive directory already contains files; choose a fresh archive directory: $archive_dir"
      fi
      [ ! -e "$certificate_install_path" ] || die "Certificate install path already exists; choose a fresh path or move the existing file aside first: $certificate_install_path"
      require_command cmp
      expected_plan_path="$(mktemp "$work_dir/.root-yubikey-plan.expected.XXXXXX")"
      write_root_yubikey_init_plan \
        "$expected_plan_path" \
        "dry-run" \
        "$profile_path" \
        "$yubikey_serial" \
        "false" \
        "$pin_retries_json" \
        "$puk_retries_json" \
        "$subject" \
        "$validity_days" \
        "$slot" \
        "$algorithm" \
        "$pin_policy" \
        "$touch_policy" \
        "$pkcs11_module_path" \
        "$pkcs11_provider_directory" \
        "$routine_key_uri" \
        "$certificate_install_path" \
        "$archive_dir" \
        "$work_dir" \
        "$openssl_config_path" \
        "$public_key_path" \
        "$attestation_path" \
        "$certificate_path" \
        "$token_export_path" \
        "$verified_public_key_path" \
        "$metadata_path" \
        "$key_uri_path" \
        "$summary_path"
      [ -f "$plan_path" ] || die "Reviewed dry-run plan not found in --work-dir; run the same command with --dry-run first and review the generated plan before applying"
      if ! cmp -s "$plan_path" "$expected_plan_path"; then
        rm -f "$expected_plan_path"
        die "Reviewed dry-run plan does not match the current apply invocation; rerun --dry-run in the same --work-dir and review the new plan before applying"
      fi
      reviewed_plan_hash_before="$(file_sha256 "$plan_path")"
      rm -f "$expected_plan_path"

      root_pin="$(read_trimmed_file_value "$pin_file" "PIN")"
      validate_length_range "$root_pin" "PIN" 6 8
      root_puk="$(read_trimmed_file_value "$puk_file" "PUK")"
      validate_length_range "$root_puk" "PUK" 6 8
      root_management_key="$(read_trimmed_file_value "$management_key_file" "Management key")"
      validate_hex_value "$root_management_key" "Management key" 64
      validate_not_factory_default "$root_pin" "PIN" "123456"
      validate_not_factory_default "$root_puk" "PUK" "12345678"
      validate_not_factory_default "$root_management_key" "Management key" "$default_management_key"
      [ "$root_pin" != "$root_puk" ] || die "PIN and PUK must not be identical"
      ykman_algorithm="$(printf '%s' "$algorithm" | tr '[:upper:]' '[:lower:]')"

      require_file "$pkcs11_module_path"
      [ -d "$pkcs11_provider_directory" ] || die "PKCS#11 provider directory not found: $pkcs11_provider_directory"
      require_ykman_command
      run_ykman --device "$yubikey_serial" info > "$device_info_before_path"
      run_ykman --device "$yubikey_serial" piv info > "$piv_info_before_path"
      if [ "$force_reset" = "0" ] && root_yubikey_piv_info_indicates_initialized "$piv_info_before_path"; then
        root_yubikey_requires_factory_fresh_state
      fi

      if [ "$force_reset" = "1" ]; then
        run_ykman --device "$yubikey_serial" piv reset --force
      fi
      if [ -n "$pin_retries" ]; then
        if ! run_ykman --device "$yubikey_serial" piv access set-retries "$pin_retries" "$puk_retries" \
          --management-key "$default_management_key" \
          --force; then
          [ "$force_reset" = "1" ] || root_yubikey_requires_factory_fresh_state
          die "Failed to set PIN and PUK retry counters on the YubiKey PIV application"
        fi
      fi
      if ! run_ykman --device "$yubikey_serial" piv access change-pin \
        --pin 123456 \
        --new-pin "$root_pin"; then
        [ "$force_reset" = "1" ] || root_yubikey_requires_factory_fresh_state
        die "Failed to change the YubiKey PIN from the factory default"
      fi
      if ! run_ykman --device "$yubikey_serial" piv access change-puk \
        --puk 12345678 \
        --new-puk "$root_puk"; then
        [ "$force_reset" = "1" ] || root_yubikey_requires_factory_fresh_state
        die "Failed to change the YubiKey PUK from the factory default"
      fi
      if ! run_ykman --device "$yubikey_serial" piv access change-management-key \
        --algorithm aes256 \
        --management-key "$default_management_key" \
        --new-management-key "$root_management_key" \
        --force; then
        [ "$force_reset" = "1" ] || root_yubikey_requires_factory_fresh_state
        die "Failed to change the YubiKey management key from the factory default"
      fi

      if ! run_ykman --device "$yubikey_serial" piv keys generate "$slot" "$public_key_path" \
        --management-key "$root_management_key" \
        --algorithm "$ykman_algorithm" \
        --pin-policy "$pin_policy" \
        --touch-policy "$touch_policy"; then
        [ "$force_reset" = "1" ] || root_yubikey_requires_factory_fresh_state
        die "Failed to generate the root signing key on the YubiKey"
      fi
      run_ykman --device "$yubikey_serial" piv keys attest "$slot" "$attestation_path"

      # Older libp11 releases treat the PIV token as uninitialized until
      # standard metadata objects exist, so create them before the PKCS#11
      # self-sign step.
      run_ykman --device "$yubikey_serial" piv objects generate CHUID \
        --management-key "$root_management_key" \
        --pin "$root_pin"
      run_ykman --device "$yubikey_serial" piv objects generate CCC \
        --management-key "$root_management_key" \
        --pin "$root_pin"

      active_routine_key_uri="$(discover_pkcs11_private_key_uri "$pkcs11_module_path" "$root_pin" "$slot" || true)"
      if [ -z "$active_routine_key_uri" ]; then
        active_routine_key_uri="$routine_key_uri"
      fi
      printf '%s\n' "$active_routine_key_uri" > "$key_uri_path"

      if ! generate_root_yubikey_certificate \
        "$yubikey_serial" \
        "$slot" \
        "$public_key_path" \
        "$subject" \
        "$validity_days" \
        "$digest" \
        "$root_pin" \
        "$root_management_key" \
        "$certificate_path"; then
        die "Failed to generate and store the self-signed root certificate on the YubiKey"
      fi

      run_ykman --device "$yubikey_serial" piv certificates export "$slot" "$token_export_path"
      cmp -s "$certificate_path" "$token_export_path" || die "The certificate exported from the YubiKey does not match the locally generated copy"
      run_ykman --device "$yubikey_serial" piv keys export "$slot" "$verified_public_key_path" \
        --verify \
        --pin "$root_pin"

      openssl verify -CAfile "$certificate_path" "$certificate_path" >/dev/null
      write_certificate_metadata "$certificate_path" "$metadata_path" "root-ca-yubikey-initialized"
      install -D -m 644 "$certificate_path" "$certificate_install_path"

      run_ykman --device "$yubikey_serial" info > "$device_info_after_path"
      run_ykman --device "$yubikey_serial" piv info > "$piv_info_after_path"

      write_root_yubikey_init_summary \
        "$summary_path" \
        "$yubikey_serial" \
        "$force_reset" \
        "$slot" \
        "$active_routine_key_uri" \
        "$certificate_path" \
        "$attestation_path" \
        "$certificate_install_path" \
        "$archive_dir" \
        "$profile_path" \
        "$plan_path"

      chmod 644 \
        "$certificate_path" \
        "$token_export_path" \
        "$public_key_path" \
        "$verified_public_key_path" \
        "$attestation_path" \
        "$metadata_path" \
        "$summary_path" \
        "$openssl_config_path" \
        "$key_uri_path" \
        "$profile_copy_path" \
        "$device_info_before_path" \
        "$piv_info_before_path" \
        "$device_info_after_path" \
        "$piv_info_after_path"

      install -d -m 700 "$archive_dir"
      install -m 644 "$certificate_path" "$archive_dir/root-ca.cert.pem"
      install -m 644 "$token_export_path" "$archive_dir/root-ca.token-export.cert.pem"
      install -m 644 "$public_key_path" "$archive_dir/root-ca.pub.pem"
      install -m 644 "$verified_public_key_path" "$archive_dir/root-ca.pub.verified.pem"
      install -m 644 "$attestation_path" "$archive_dir/root-ca.attestation.cert.pem"
      install -m 644 "$metadata_path" "$archive_dir/root-ca.metadata.json"
      install -m 644 "$plan_path" "$archive_dir/root-yubikey-init-plan.json"
      install -m 644 "$summary_path" "$archive_dir/root-yubikey-init-summary.json"
      install -m 644 "$openssl_config_path" "$archive_dir/root-ca-openssl.cnf"
      install -m 644 "$key_uri_path" "$archive_dir/root-key-uri.txt"
      install -m 644 "$profile_copy_path" "$archive_dir/root-yubikey-profile.json"
      install -m 644 "$device_info_before_path" "$archive_dir/yubikey-device-info.before.txt"
      install -m 644 "$piv_info_before_path" "$archive_dir/yubikey-piv-info.before.txt"
      install -m 644 "$device_info_after_path" "$archive_dir/yubikey-device-info.after.txt"
      install -m 644 "$piv_info_after_path" "$archive_dir/yubikey-piv-info.after.txt"
      [ "$reviewed_plan_hash_before" = "$(file_sha256 "$plan_path")" ] || die "Reviewed dry-run plan was modified during apply; aborting because the ceremony record is no longer stable"

      unset root_pin root_puk root_management_key default_management_key
      printf '%s\n' "Initialized root YubiKey $yubikey_serial using profile: $profile_path"
      printf '%s\n' "Installed certificate to: $certificate_install_path"
      printf '%s\n' "Archived public artifacts to: $archive_dir"
    }

    export_root_inventory() {
      local source_dir=""
      local out_dir=""
      local root_id=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --source-dir)
            source_dir="$2"
            shift 2
            ;;
          --out-dir)
            out_dir="$2"
            shift 2
            ;;
          *)
            die "Unknown export-root-inventory argument: $1"
            ;;
        esac
      done

      [ -n "$source_dir" ] || die "--source-dir is required"
      [ -n "$out_dir" ] || die "--out-dir is required"

      require_dir "$source_dir"

      source_dir="$(canonicalize_path "$source_dir")"
      out_dir="$(canonicalize_path "$out_dir")"
      [ "$source_dir" != "$out_dir" ] || die "--out-dir must differ from --source-dir"
      path_is_within "$out_dir" "$source_dir" && die "--out-dir must not live under --source-dir"
      path_is_within "$source_dir" "$out_dir" && die "--source-dir must not live under --out-dir"

      validate_root_inventory_source_artifacts "$source_dir"
      write_root_inventory_contract_dir "$source_dir" "$out_dir"

      root_id="$(root_inventory_id_for_certificate "$source_dir/root-ca.cert.pem")"
      printf '%s\n' "Exported root inventory bundle to: $out_dir"
      printf '%s\n' "Root inventory id: $root_id"
    }

    normalize_root_inventory() {
      local source_dir=""
      local inventory_root=""
      local root_id=""
      local inventory_dir=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --source-dir)
            source_dir="$2"
            shift 2
            ;;
          --inventory-root)
            inventory_root="$2"
            shift 2
            ;;
          *)
            die "Unknown normalize-root-inventory argument: $1"
            ;;
        esac
      done

      [ -n "$source_dir" ] || die "--source-dir is required"
      [ -n "$inventory_root" ] || die "--inventory-root is required"

      require_dir "$source_dir"
      mkdir -p "$inventory_root"

      source_dir="$(canonicalize_path "$source_dir")"
      inventory_root="$(canonicalize_path "$inventory_root")"

      validate_root_inventory_source_artifacts "$source_dir"
      root_id="$(root_inventory_id_for_certificate "$source_dir/root-ca.cert.pem")"
      inventory_dir="$inventory_root/$root_id"
      write_root_inventory_contract_dir "$source_dir" "$inventory_dir"

      printf '%s\n' "Normalized root inventory into: $inventory_dir"
      printf '%s\n' "Root inventory id: $root_id"
    }

    verify_root_yubikey_identity() {
      local inventory_dir=""
      local yubikey_serial=""
      local pin_file=""
      local work_dir=""
      local manifest_path=""
      local certificate_path=""
      local verified_public_key_path=""
      local attestation_path=""
      local metadata_path=""
      local summary_path=""
      local key_uri_path=""
      local inventory_serial=""
      local slot=""
      local routine_key_uri=""
      local token_certificate_path=""
      local token_public_key_path=""
      local token_certificate_fingerprint=""
      local token_public_key_sha256=""
      local summary_output_path=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --inventory-dir)
            inventory_dir="$2"
            shift 2
            ;;
          --yubikey-serial)
            yubikey_serial="$2"
            shift 2
            ;;
          --pin-file)
            pin_file="$2"
            shift 2
            ;;
          --work-dir)
            work_dir="$2"
            shift 2
            ;;
          *)
            die "Unknown verify-root-yubikey-identity argument: $1"
            ;;
        esac
      done

      [ -n "$inventory_dir" ] || die "--inventory-dir is required"
      [ -n "$yubikey_serial" ] || die "--yubikey-serial is required"
      [ -n "$pin_file" ] || die "--pin-file is required"
      [ -n "$work_dir" ] || die "--work-dir is required"

      validate_yubikey_serial "$yubikey_serial"
      validate_owner_only_file_permissions "$pin_file" "PIN"
      require_dir "$inventory_dir"

      inventory_dir="$(canonicalize_path "$inventory_dir")"
      work_dir="$(canonicalize_path "$work_dir")"
      require_absolute_path "$inventory_dir" "--inventory-dir"
      require_absolute_path "$work_dir" "--work-dir"
      path_is_within "$pin_file" "$work_dir" && die "PIN file must not live under --work-dir"

      manifest_path="$inventory_dir/manifest.json"
      certificate_path="$inventory_dir/root-ca.cert.pem"
      verified_public_key_path="$inventory_dir/root-ca.pub.verified.pem"
      attestation_path="$inventory_dir/root-ca.attestation.cert.pem"
      metadata_path="$inventory_dir/root-ca.metadata.json"
      summary_path="$inventory_dir/root-yubikey-init-summary.json"
      key_uri_path="$inventory_dir/root-key-uri.txt"

      validate_root_inventory_manifest \
        "$manifest_path" \
        "$certificate_path" \
        "$verified_public_key_path" \
        "$attestation_path" \
        "$metadata_path" \
        "$summary_path" \
        "$key_uri_path"

      inventory_serial="$(jq -r '.yubiKey.serial' "$manifest_path")"
      slot="$(jq -r '.yubiKey.slot' "$manifest_path")"
      routine_key_uri="$(jq -r '.yubiKey.routineKeyUri' "$manifest_path")"

      install -d -m 700 "$work_dir"
      token_certificate_path="$work_dir/token-root-ca.cert.pem"
      token_public_key_path="$work_dir/token-root-ca.pub.verified.pem"
      summary_output_path="$work_dir/root-yubikey-identity-summary.json"

      require_ykman_command
      run_ykman --device "$yubikey_serial" info > "$work_dir/yubikey-device-info.txt"
      run_ykman --device "$yubikey_serial" piv info > "$work_dir/yubikey-piv-info.txt"
      run_ykman --device "$yubikey_serial" piv certificates export "$slot" "$token_certificate_path"
      run_ykman --device "$yubikey_serial" piv keys export "$slot" "$token_public_key_path" \
        --verify \
        --pin "$(tr -d '\r\n' < "$pin_file")"

      openssl x509 -in "$token_certificate_path" -noout >/dev/null 2>&1 || die "Failed to parse the exported root certificate from the YubiKey"
      openssl pkey -pubin -in "$token_public_key_path" -outform pem >/dev/null 2>&1 || die "Failed to parse the exported root public key from the YubiKey"

      write_root_yubikey_identity_summary \
        "$summary_output_path" \
        "$inventory_dir" \
        "$manifest_path" \
        "$inventory_serial" \
        "$yubikey_serial" \
        "$slot" \
        "$routine_key_uri" \
        "$token_certificate_path" \
        "$token_public_key_path"

      token_certificate_fingerprint="$(certificate_fingerprint "$token_certificate_path")"
      [ "$token_certificate_fingerprint" = "$(jq -r '.certificate.sha256Fingerprint' "$manifest_path")" ] ||
        die "Inserted YubiKey certificate does not match the committed root inventory: $summary_output_path"

      token_public_key_sha256="$(file_sha256 "$token_public_key_path")"
      [ "$token_public_key_sha256" = "$(jq -r '.verifiedPublicKey.sha256' "$manifest_path")" ] ||
        die "Inserted YubiKey verified public key does not match the committed root inventory: $summary_output_path"

      if [ "$inventory_serial" != "$yubikey_serial" ]; then
        printf '%s\n' "Warning: inserted YubiKey serial $yubikey_serial differs from inventory metadata $inventory_serial" >&2
      fi

      printf '%s\n' "Verified root YubiKey identity against inventory: $inventory_dir"
      printf '%s\n' "Verification summary written to: $summary_output_path"
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
      local issuer_key_uri=""
      local pkcs11_module=""
      local pkcs11_pin_file=""
      local issuer_cert=""
      local issuer_chain=""
      local signer_state_dir=""
      local serial=""
      local days=""
      local policy_file=""
      local approved_by=""
      local approval_ticket=""
      local approval_note=""

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
          --issuer-key-uri)
            issuer_key_uri="$2"
            shift 2
            ;;
          --pkcs11-module)
            pkcs11_module="$2"
            shift 2
            ;;
          --pkcs11-pin-file)
            pkcs11_pin_file="$2"
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
          --approved-by)
            approved_by="$2"
            shift 2
            ;;
          --approval-ticket)
            approval_ticket="$2"
            shift 2
            ;;
          --approval-note)
            approval_note="$2"
            shift 2
            ;;
          *)
            die "Unknown sign-request argument: $1"
            ;;
        esac
      done

      [ -n "$request_dir" ] || die "--request-dir is required"
      [ -n "$out_dir" ] || die "--out-dir is required"
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
      if [ -n "$signer_state_dir" ] && [ -z "$approved_by" ]; then
        die "--approved-by is required when --signer-state-dir is provided"
      fi

      require_dir "$request_dir"
      require_file "$issuer_cert"
      [ -z "$issuer_chain" ] || require_file "$issuer_chain"
      require_file "$request_dir/request.json"
      [ -z "$policy_file" ] || validate_policy_file "$policy_file"

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
      local approval_recorded_at=""
      local approval_json=""
      local crl_distribution_points=""
      local signer_backend=""
      local issuer_key_ref=""

      prepare_signer_backend \
        "$issuer_key" \
        "$issuer_key_uri" \
        "$pkcs11_module" \
        "$pkcs11_pin_file" \
        signer_backend \
        issuer_key_ref

      signer_matches_key "$signer_backend" "$issuer_key_ref" "$issuer_cert" || die "Issuer certificate does not match issuer signing key"

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
      validate_csr_against_policy "$csr_path" "$role" "$policy_file"
      validate_request_matches_csr "$request_file" "$csr_path" "$role"
      days="$(resolve_signing_days "$request_file" "$role" "$days" "$policy_file")"
      crl_distribution_points="$(resolve_crl_distribution_points "$role" "$policy_file")"

      if [ -n "$signer_state_dir" ]; then
        acquire_signer_state_lock "$signer_state_dir" signer_lock_fd
        approval_recorded_at="$(current_timestamp_utc)"
        approval_json="$(build_approval_json "$approved_by" "$approval_recorded_at" "$approval_ticket" "$approval_note")"
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
            "$signer_backend" \
            "$issuer_key_ref" \
            "$issuer_cert" \
            "$issuer_chain" \
            "$crl_distribution_points"
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
            "$signer_backend" \
            "$issuer_key_ref" \
            "$issuer_cert" \
            "$issuer_chain" \
            "$crl_distribution_points"
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
        write_request_record "$request_record_path" "$request_id" "$request_file" "$cert_serial" "$issued_at" "$approval_json"
        write_serial_record "$(signer_state_serial_record_path "$signer_state_dir" "$cert_serial")" "$cert_serial" "$request_id" "$issued_at" "$approval_json"
        write_issuance_record "$issuance_dir/issuance.json" "$cert_serial" "$request_id" "$request_file" "$out_dir/metadata.json" "$issuer_cert" "$issued_at" "$approval_json"
        write_issuance_audit_event \
          "$(signer_state_audit_event_path "$signer_state_dir" "$(current_timestamp_compact_utc)" "issued" "$cert_serial")" \
          "$cert_serial" \
          "$request_id" \
          "$request_file" \
          "$out_dir/metadata.json" \
          "$issuer_cert" \
          "$issued_at" \
          "$approval_json"
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
      local issuer_key_uri=""
      local pkcs11_module=""
      local pkcs11_pin_file=""
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
          --issuer-key-uri)
            issuer_key_uri="$2"
            shift 2
            ;;
          --pkcs11-module)
            pkcs11_module="$2"
            shift 2
            ;;
          --pkcs11-pin-file)
            pkcs11_pin_file="$2"
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
      [ -n "$issuer_cert" ] || die "--issuer-cert is required"
      [ -n "$out_dir" ] || die "--out-dir is required"
      require_dir "$signer_state_dir"
      require_file "$issuer_cert"

      local state_crl_path
      local state_crl_metadata_path
      local state_next_crl_number_path
      local crl_workdir
      local config_path
      local crl_number_seed
      local signer_lock_fd=""
      local signer_backend=""
      local issuer_key_ref=""

      prepare_signer_backend \
        "$issuer_key" \
        "$issuer_key_uri" \
        "$pkcs11_module" \
        "$pkcs11_pin_file" \
        signer_backend \
        issuer_key_ref

      signer_matches_key "$signer_backend" "$issuer_key_ref" "$issuer_cert" || die "Issuer certificate does not match issuer signing key"

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
private_key = $issuer_key_ref
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
          openssl_with_signer_backend "$signer_backend" ca -config "$config_path" -batch -valid "$cert_path" >/dev/null 2>&1
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
          openssl_with_signer_backend "$signer_backend" ca -config "$config_path" -batch -revoke "$cert_path" -crl_reason "$reason" >/dev/null 2>&1
        done
      fi

      openssl_with_signer_backend "$signer_backend" ca -config "$config_path" -batch -gencrl -out "$state_crl_path" -crldays "$days" >/dev/null 2>&1
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
      local revoked_by=""
      local revocation_ticket=""
      local revocation_note=""

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
          --revoked-by)
            revoked_by="$2"
            shift 2
            ;;
          --revocation-ticket)
            revocation_ticket="$2"
            shift 2
            ;;
          --revocation-note)
            revocation_note="$2"
            shift 2
            ;;
          *)
            die "Unknown revoke-issued argument: $1"
            ;;
        esac
      done

      [ -n "$signer_state_dir" ] || die "--signer-state-dir is required"
      [ -n "$serial" ] || die "--serial is required"
      [ -n "$revoked_by" ] || die "--revoked-by is required"
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
      local revocation_json=""

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
      revocation_json="$(build_revocation_json "$revoked_by" "$revoked_at" "$reason" "$revocation_ticket" "$revocation_note")"

      jq -n \
        --arg serial "$serial" \
        --arg requestId "$request_id" \
        --arg roleId "$(jq -r '.request.roleId // empty' "$issuance_record_path")" \
        --arg subject "$(jq -r '.certificate.subject // empty' "$issuance_record_path")" \
        --argjson revocation "$revocation_json" \
        '{
          schemaVersion: 1,
          serial: $serial,
          requestId: $requestId,
          roleId: $roleId,
          subject: $subject,
          reason: $revocation.reason,
          revokedAt: $revocation.revokedAt,
          revocation: $revocation,
          status: "revoked"
        }' > "$revocation_record_path"

      update_tmp="$(mktemp)"
      jq \
        --argjson revocation "$revocation_json" \
        '.status = "revoked" | .revocation = $revocation' \
        "$issuance_record_path" > "$update_tmp"
      mv "$update_tmp" "$issuance_record_path"

      update_tmp="$(mktemp)"
      jq \
        --argjson revocation "$revocation_json" \
        '.status = "revoked" | .revocation = $revocation' \
        "$request_record_path" > "$update_tmp"
      mv "$update_tmp" "$request_record_path"

      update_tmp="$(mktemp)"
      jq \
        --argjson revocation "$revocation_json" \
        '.status = "revoked" | .revocation = $revocation' \
        "$serial_record_path" > "$update_tmp"
      mv "$update_tmp" "$serial_record_path"

      write_revocation_audit_event \
        "$(signer_state_audit_event_path "$signer_state_dir" "$(current_timestamp_compact_utc)" "revoked" "$serial")" \
        "$serial" \
        "$request_id" \
        "$issuance_record_path" \
        "$revocation_json" \
        "$revoked_at"
      close_locked_fd "$signer_lock_fd"
    }

    [ "$#" -gt 0 ] || {
      usage
      exit 2
    }

    command="$1"
    shift

    case "$command" in
      init-root-yubikey)
        init_root_yubikey "$@"
        ;;
      export-root-inventory)
        export_root_inventory "$@"
        ;;
      normalize-root-inventory)
        normalize_root_inventory "$@"
        ;;
      verify-root-yubikey-identity)
        verify_root_yubikey_identity "$@"
        ;;
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
