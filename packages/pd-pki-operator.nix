{ pkgs }:
pkgs.writeShellApplication {
  name = "pd-pki-operator";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.dosfstools
    pkgs.dialog
    pkgs.findutils
    pkgs.gnugrep
    pkgs.jq
    pkgs.opensc
    pkgs.openssl
    pkgs.parted
    pkgs.systemd
    pkgs.util-linux
    pkgs.yubico-piv-tool
    pkgs.yubikey-manager
  ];
  text = ''
    set -euo pipefail

    poll_seconds="2"
    workflow_mode="main-menu"
    temp_root=""
    readonly sudo_bin="/run/wrappers/bin/sudo"

    cleanup() {
      if [ -n "$temp_root" ] && [ -d "$temp_root" ]; then
        rm -rf "$temp_root"
      fi
    }

    trap cleanup EXIT INT TERM

    usage() {
      printf '%s\n' "Usage: pd-pki-operator [--poll-seconds SECONDS] [--workflow WORKFLOW] [--help]"
      printf '\n'
      printf '%s\n' "Interactive operator TUI for exporting root inventory and request bundles"
      printf '%s\n' "to removable media, signing request bundles from removable media, importing"
      printf '%s\n' "signed bundles back into runtime state, and exporting CRLs."
      printf '\n'
      printf '%s\n' "The root PKCS#11 signing path for intermediate requests requires the"
      printf '%s\n' "inserted token to pass root identity verification against committed root"
      printf '%s\n' "inventory before signing continues."
      printf '\n'
      printf '%s\n' "Signing supports either PEM issuer key paths or PKCS#11-backed keys such as"
      printf '%s\n' "YubiKey PIV slots. The wizard can discover token certificate objects and"
      printf '%s\n' "guide the operator through entering a token PIN."
      printf '\n'
      printf '%s\n' "In an interactive terminal the app uses a full-screen dialog interface."
      printf '%s\n' "Set PD_PKI_OPERATOR_PLAIN=1 to force the line-oriented fallback."
      printf '\n'
      printf '%s\n' "Workflows:"
      printf '%s\n' "  main-menu                 Launch the general operator menu (default)"
      printf '%s\n' "  root-intermediate-signer  Run the dedicated root intermediate signing wizard"
    }

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --poll-seconds)
          poll_seconds="$2"
          shift 2
          ;;
        --workflow)
          workflow_mode="$2"
          shift 2
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        *)
          printf '%s\n' "Unknown argument: $1" >&2
          usage >&2
          exit 2
          ;;
      esac
    done

    case "$poll_seconds" in
      *[!0-9]*|"")
        printf '%s\n' "--poll-seconds must be an unsigned integer" >&2
        exit 2
        ;;
    esac

    case "$workflow_mode" in
      main-menu|root-intermediate-signer)
        ;;
      *)
        printf '%s\n' "Unknown workflow: $workflow_mode" >&2
        usage >&2
        exit 2
        ;;
    esac

    temp_root="$(mktemp -d)"
    ui_backend="plain"

    if [ -t 0 ] && [ -t 1 ] && command -v dialog >/dev/null 2>&1 && [ -z "''${PD_PKI_OPERATOR_PLAIN:-}" ]; then
      ui_backend="dialog"
    fi

    current_timestamp_utc() {
      date -u +"%Y%m%dT%H%M%SZ"
    }

    divider() {
      printf '%s\n' "------------------------------------------------------------"
    }

    sanitize_label() {
      printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-'
    }

    default_operator_id() {
      if [ -n "''${USER:-}" ]; then
        printf '%s\n' "$USER"
      else
        printf '%s\n' "pdpki"
      fi
    }

    role_title_for_id() {
      case "$1" in
        intermediate-signing-authority) printf '%s\n' "Intermediate Signing Authority" ;;
        openvpn-server-leaf) printf '%s\n' "OpenVPN Server Leaf" ;;
        openvpn-client-leaf) printf '%s\n' "OpenVPN Client Leaf" ;;
        *) printf '%s\n' "$1" ;;
      esac
    }

    role_default_state_dir() {
      case "$1" in
        intermediate-signing-authority) printf '%s\n' "/var/lib/pd-pki/authorities/intermediate" ;;
        openvpn-server-leaf) printf '%s\n' "/var/lib/pd-pki/openvpn-server-leaf" ;;
        openvpn-client-leaf) printf '%s\n' "/var/lib/pd-pki/openvpn-client-leaf" ;;
        *) printf '%s\n' "" ;;
      esac
    }

    issuer_profile_title() {
      case "$1" in
        root) printf '%s\n' "Root CA" ;;
        intermediate) printf '%s\n' "Intermediate CA" ;;
        custom) printf '%s\n' "Custom issuer" ;;
        *) printf '%s\n' "$1" ;;
      esac
    }

    issuer_default_key_path() {
      case "$1" in
        root) printf '%s\n' "/var/lib/pd-pki/authorities/root/root-ca.key.pem" ;;
        intermediate) printf '%s\n' "/var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem" ;;
        *) printf '%s\n' "" ;;
      esac
    }

    issuer_default_cert_path() {
      case "$1" in
        root) printf '%s\n' "/var/lib/pd-pki/authorities/root/root-ca.cert.pem" ;;
        intermediate) printf '%s\n' "/var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem" ;;
        *) printf '%s\n' "" ;;
      esac
    }

    issuer_default_chain_path() {
      case "$1" in
        root) printf '%s\n' "" ;;
        intermediate) printf '%s\n' "/var/lib/pd-pki/authorities/intermediate/chain.pem" ;;
        *) printf '%s\n' "" ;;
      esac
    }

    issuer_default_signer_state_dir() {
      case "$1" in
        root) printf '%s\n' "/var/lib/pd-pki/signer-state/root" ;;
        intermediate) printf '%s\n' "/var/lib/pd-pki/signer-state/intermediate" ;;
        *) printf '%s\n' "" ;;
      esac
    }

    issuer_default_pkcs11_module() {
      case "$1" in
        root|intermediate|custom)
          printf '%s\n' "${pkgs.yubico-piv-tool}/lib/libykcs11.so"
          ;;
        *)
          printf '%s\n' ""
          ;;
      esac
    }

    signer_backend_title() {
      case "$1" in
        file) printf '%s\n' "PEM issuer key file" ;;
        pkcs11) printf '%s\n' "YubiKey / PKCS#11 token" ;;
        *) printf '%s\n' "$1" ;;
      esac
    }

    dialog_run() {
      dialog --clear --stdout --backtitle "Pseudo Design PKI Operator" "$@"
    }

    dialog_info() {
      local title="$1"
      local text="$2"
      dialog_run --title "$title" --msgbox "$text" 18 80
    }

    show_error() {
      local title="$1"
      local text="$2"

      if ui_is_dialog; then
        dialog_run --title "$title" --msgbox "$text" 18 80
        return 0
      fi

      divider
      printf '%s\n' "$title" >&2
      printf '%b\n' "$text" >&2
      divider >&2
    }

    dialog_menu_height() {
      printf '%s\n' "12"
    }

    ui_is_dialog() {
      [ "$ui_backend" = "dialog" ]
    }

    print_header() {
      if ui_is_dialog; then
        return 0
      fi

      divider
      printf '%s\n' "Pseudo Design PKI Operator"
      printf '%s\n' "USB-guided root inventory export, request export, signing, import, and CRL handoff"
      printf '%s\n' "YubiKey status: $(yubikey_status_line)"
      divider
    }

    prompt_text() {
      local label="$1"
      local default_value="$2"
      local value=""

      if ui_is_dialog; then
        value="$(dialog_run --title "Input" --inputbox "$label" 12 80 "$default_value")" || return 1
        printf '%s' "$value"
        return 0
      fi

      if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$label" "$default_value" >&2
      else
        printf '%s: ' "$label" >&2
      fi

      IFS= read -r value
      if [ -z "$value" ]; then
        value="$default_value"
      fi
      printf '%s' "$value"
    }

    prompt_secret() {
      local label="$1"
      local value=""

      if ui_is_dialog; then
        value="$(dialog_run --title "Sensitive Input" --passwordbox "$label" 12 80)" || return 1
        printf '%s' "$value"
        return 0
      fi

      printf '%s: ' "$label" >&2
      IFS= read -r -s value
      printf '\n' >&2
      printf '%s' "$value"
    }

    prompt_yes_no() {
      local label="$1"
      local default_answer="$2"
      local value=""

      if ui_is_dialog; then
        if [ "$default_answer" = "n" ]; then
          dialog_run --title "Confirm" --defaultno --yesno "$label" 12 80
        else
          dialog_run --title "Confirm" --yesno "$label" 12 80
        fi
        return $?
      fi

      while true; do
        case "$default_answer" in
          y) printf '%s [Y/n]: ' "$label" >&2 ;;
          n) printf '%s [y/N]: ' "$label" >&2 ;;
          *) printf '%s [y/n]: ' "$label" >&2 ;;
        esac

        IFS= read -r value
        value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

        if [ -z "$value" ]; then
          value="$default_answer"
        fi

        case "$value" in
          y|yes) return 0 ;;
          n|no) return 1 ;;
        esac

        printf '%s\n' "Please answer y or n." >&2
      done
    }

    prompt_existing_file() {
      local label="$1"
      local default_value="$2"
      local optional="$3"
      local candidate=""

      while true; do
        candidate="$(prompt_text "$label" "$default_value")" || return 1
        if [ -z "$candidate" ] && [ "$optional" = "optional" ]; then
          printf '%s' ""
          return 0
        fi
        if [ -f "$candidate" ]; then
          printf '%s' "$candidate"
          return 0
        fi
        if ui_is_dialog; then
          dialog_info "Missing File" "File not found:\n$candidate"
        else
          printf '%s\n' "File not found: $candidate" >&2
        fi
      done
    }

    prompt_existing_dir() {
      local label="$1"
      local default_value="$2"
      local optional="$3"
      local candidate=""

      while true; do
        candidate="$(prompt_text "$label" "$default_value")" || return 1
        if [ -z "$candidate" ] && [ "$optional" = "optional" ]; then
          printf '%s' ""
          return 0
        fi
        if [ -d "$candidate" ]; then
          printf '%s' "$candidate"
          return 0
        fi
        if ui_is_dialog; then
          dialog_info "Missing Directory" "Directory not found:\n$candidate"
        else
          printf '%s\n' "Directory not found: $candidate" >&2
        fi
      done
    }

    pause() {
      if ui_is_dialog; then
        dialog_info "Continue" "Ready for the next step."
        return 0
      fi

      printf '%s' "Press Enter to continue..." >&2
      IFS= read -r _
    }

    unique_destination_path() {
      local base_path="$1"
      local candidate="$base_path"
      local suffix="1"

      while [ -e "$candidate" ]; do
        candidate="$base_path-$suffix"
        suffix=$((suffix + 1))
      done

      printf '%s' "$candidate"
    }

    copy_bundle_dir() {
      local source_dir="$1"
      local destination_dir="$2"

      mkdir -p "$(dirname "$destination_dir")"
      cp -R "$source_dir" "$destination_dir"
      sync "$destination_dir" >/dev/null 2>&1 || sync >/dev/null 2>&1 || true
    }

    request_bundle_role() {
      jq -r '.roleId // empty' "$1/request.json" 2>/dev/null || true
    }

    request_bundle_common_name() {
      jq -r '.commonName // empty' "$1/request.json" 2>/dev/null || true
    }

    request_bundle_basename() {
      jq -r '.basename // empty' "$1/request.json" 2>/dev/null || true
    }

    request_bundle_days() {
      jq -r '(.requestedDays // empty) | tostring' "$1/request.json" 2>/dev/null || true
    }

    request_bundle_profile() {
      jq -r '.requestedProfile // empty' "$1/request.json" 2>/dev/null || true
    }

    request_bundle_path_len() {
      jq -r '(.pathLen // empty) | tostring' "$1/request.json" 2>/dev/null || true
    }

    request_bundle_sans() {
      jq -r '(.subjectAltNames // []) | join(", ")' "$1/request.json" 2>/dev/null || true
    }

    request_bundle_csr_file() {
      jq -r '.csrFile // empty' "$1/request.json" 2>/dev/null || true
    }

    request_bundle_csr_path() {
      local bundle_dir="$1"
      local csr_file=""

      csr_file="$(request_bundle_csr_file "$bundle_dir")"
      if [ -n "$csr_file" ] && [ -f "$bundle_dir/$csr_file" ]; then
        printf '%s' "$bundle_dir/$csr_file"
        return 0
      fi
      if [ -f "$bundle_dir/csr.pem" ]; then
        printf '%s' "$bundle_dir/csr.pem"
      fi
    }

    signed_bundle_serial() {
      jq -r '.serial // empty' "$1/metadata.json" 2>/dev/null || true
    }

    signed_bundle_not_after() {
      jq -r '.notAfter // empty' "$1/metadata.json" 2>/dev/null || true
    }

    root_inventory_bundle_root_id() {
      jq -r '.rootId // empty' "$1/manifest.json" 2>/dev/null || true
    }

    root_inventory_bundle_subject() {
      jq -r '.certificate.subject // empty' "$1/manifest.json" 2>/dev/null || true
    }

    root_inventory_bundle_yubikey_serial() {
      jq -r '.yubiKey.serial // empty' "$1/manifest.json" 2>/dev/null || true
    }

    root_policy_file_for_root_id() {
      local root_id="$1"
      local candidate=""

      for candidate in \
        "''${ROOT_POLICY_ROOT:-/var/lib/pd-pki/policy/root-ca}/$root_id/root-signer-policy.json" \
        "''${ROOT_POLICY_ROOT:-/var/lib/pd-pki/policy/root-ca}/$root_id/root-policy.json"
      do
        if [ -f "$candidate" ]; then
          printf '%s' "$candidate"
          return 0
        fi
      done

      return 1
    }

    resolve_root_signer_policy_file() {
      local inventory_dir="$1"
      local fallback_path="$2"
      local root_id=""
      local candidate=""

      root_id="$(root_inventory_bundle_root_id "$inventory_dir")"
      if [ -n "$root_id" ]; then
        candidate="$(root_policy_file_for_root_id "$root_id" || true)"
        if [ -n "$candidate" ]; then
          printf '%s' "$candidate"
          return 0
        fi
      fi

      if [ -n "$fallback_path" ] && [ -f "$fallback_path" ]; then
        printf '%s' "$fallback_path"
        return 0
      fi

      return 1
    }

    root_yubikey_identity_summary_root_id() {
      jq -r '.rootId // empty' "$1" 2>/dev/null || true
    }

    root_yubikey_identity_summary_inventory_serial() {
      jq -r '.inventorySerial // empty' "$1" 2>/dev/null || true
    }

    root_yubikey_identity_summary_yubikey_serial() {
      jq -r '.yubikeySerial // empty' "$1" 2>/dev/null || true
    }

    root_yubikey_identity_summary_certificate_match() {
      jq -r '.certificate.match // empty' "$1" 2>/dev/null || true
    }

    root_yubikey_identity_summary_public_key_match() {
      jq -r '.verifiedPublicKey.match // empty' "$1" 2>/dev/null || true
    }

    find_request_bundles() {
      local root_dir="$1"
      local request_file=""
      local request_dir=""
      local role=""
      local common_name=""
      local basename=""
      local csr_file=""

      while IFS= read -r -d $'\0' request_file; do
        request_dir="$(dirname "$request_file")"
        role="$(jq -r '.roleId // empty' "$request_file" 2>/dev/null || true)"
        common_name="$(jq -r '.commonName // empty' "$request_file" 2>/dev/null || true)"
        basename="$(jq -r '.basename // empty' "$request_file" 2>/dev/null || true)"
        csr_file="$(jq -r '.csrFile // empty' "$request_file" 2>/dev/null || true)"

        if [ -n "$csr_file" ] && [ -f "$request_dir/$csr_file" ]; then
          printf '%s\t%s\t%s\t%s\n' "$request_dir" "$role" "$common_name" "$basename"
        elif [ -f "$request_dir/csr.pem" ]; then
          printf '%s\t%s\t%s\t%s\n' "$request_dir" "$role" "$common_name" "$basename"
        fi
      done < <(find "$root_dir" -maxdepth 4 -type f -name request.json -print0 2>/dev/null)
    }

    find_root_inventory_dirs() {
      local root_dir="$1"
      local manifest_path=""
      local inventory_dir=""
      local root_id=""
      local subject=""
      local yubikey_serial=""

      while IFS= read -r -d $'\0' manifest_path; do
        inventory_dir="$(dirname "$manifest_path")"
        root_id="$(jq -r '.rootId // empty' "$manifest_path" 2>/dev/null || true)"
        subject="$(jq -r '.certificate.subject // empty' "$manifest_path" 2>/dev/null || true)"
        yubikey_serial="$(jq -r '.yubiKey.serial // empty' "$manifest_path" 2>/dev/null || true)"

        if [ -n "$root_id" ] && [ -f "$inventory_dir/root-ca.cert.pem" ]; then
          printf '%s\t%s\t%s\t%s\n' "$inventory_dir" "$root_id" "$subject" "$yubikey_serial"
        fi
      done < <(find "$root_dir" -maxdepth 3 -type f -name manifest.json -print0 2>/dev/null)
    }

    find_signed_bundles() {
      local root_dir="$1"
      local request_file=""
      local bundle_dir=""
      local basename=""
      local role=""
      local common_name=""
      local cert_path=""
      local serial=""

      while IFS= read -r -d $'\0' request_file; do
        bundle_dir="$(dirname "$request_file")"
        basename="$(jq -r '.basename // empty' "$request_file" 2>/dev/null || true)"
        role="$(jq -r '.roleId // empty' "$request_file" 2>/dev/null || true)"
        common_name="$(jq -r '.commonName // empty' "$request_file" 2>/dev/null || true)"
        serial="$(jq -r '.serial // empty' "$bundle_dir/metadata.json" 2>/dev/null || true)"
        cert_path="$bundle_dir/$basename.cert.pem"

        if [ -n "$basename" ] && [ -f "$cert_path" ] && [ -f "$bundle_dir/chain.pem" ] && [ -f "$bundle_dir/metadata.json" ]; then
          printf '%s\t%s\t%s\t%s\n' "$bundle_dir" "$role" "$common_name" "$serial"
        fi
      done < <(find "$root_dir" -maxdepth 4 -type f -name request.json -print0 2>/dev/null)
    }

    detect_yubikey_serials() {
      if ! command -v ykman >/dev/null 2>&1; then
        return 0
      fi
      ykman list --serials 2>/dev/null | grep -v '^[[:space:]]*$' || true
    }

    yubikey_status_line() {
      local serials=""

      if ! command -v ykman >/dev/null 2>&1; then
        printf '%s\n' "detection unavailable"
        return 0
      fi

      serials="$(detect_yubikey_serials)"
      if [ -n "$serials" ]; then
        printf '%s\n' "detected: $(printf '%s\n' "$serials" | paste -sd ', ' -)"
      else
        printf '%s\n' "not detected"
      fi
    }

    wait_for_yubikey_insertion() {
      local answer=""
      local serials=""

      while true; do
        serials="$(detect_yubikey_serials)"
        if [ -n "$serials" ]; then
          if ui_is_dialog; then
            dialog_info "YubiKey Detected" "Detected YubiKey serial(s):\n$serials"
          else
            divider
            printf '%s\n' "Detected YubiKey serial(s):"
            printf '  %s\n' "$serials"
          fi
          return 0
        fi

        if ui_is_dialog; then
          dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Insert YubiKey" --infobox "Insert the root CA YubiKey now.\n\nThe ceremony will continue when the token is detected.\n\nPress q to cancel." 14 80
          if answer="$(read_key_with_timeout "$poll_seconds")"; then
            case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
              q) return 1 ;;
            esac
          fi
          continue
        fi

        print_header
        printf '%s\n' "Insert the root CA YubiKey now."
        printf '%s' "Press Enter to keep waiting or q to cancel: " >&2
        IFS= read -r answer
        case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
          q) return 1 ;;
        esac
      done
    }

    wait_for_yubikey_removal() {
      local answer=""
      local serials=""

      while true; do
        serials="$(detect_yubikey_serials)"
        if [ -z "$serials" ]; then
          return 0
        fi

        if ui_is_dialog; then
          dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Remove YubiKey" --infobox "Remove the YubiKey now.\n\nStill detected:\n$serials\n\nPress q to cancel." 15 80
          if answer="$(read_key_with_timeout "$poll_seconds")"; then
            case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
              q) return 1 ;;
            esac
          fi
          continue
        fi

        print_header
        printf '%s\n' "Remove the YubiKey now."
        printf '%s\n' "Still detected: $(printf '%s\n' "$serials" | paste -sd ', ' -)"
        printf '%s' "Press Enter after removing it or q to cancel: " >&2
        IFS= read -r answer
        case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
          q) return 1 ;;
        esac
      done
    }

    read_key_with_timeout() {
      local timeout_seconds="$1"
      local key=""

      if IFS= read -r -s -n 1 -t "$timeout_seconds" key; then
        printf '%s' "$key"
        return 0
      fi

      return 1
    }

    trim_whitespace() {
      local value="$1"
      value="''${value#"''${value%%[![:space:]]*}"}"
      value="''${value%"''${value##*[![:space:]]}"}"
      printf '%s' "$value"
    }

    maybe_wait_for_yubikey() {
      local answer=""
      local serials=""

      while true; do
        serials="$(detect_yubikey_serials)"
        if [ -n "$serials" ]; then
          if ui_is_dialog; then
            dialog_info "YubiKey Detected" "Detected YubiKey serial(s):\n$serials"
          else
            divider
            printf '%s\n' "Detected YubiKey serial(s):"
            printf '  %s\n' "$serials"
          fi
          return 0
        fi

        if ui_is_dialog; then
          dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Waiting For YubiKey" --infobox "No YubiKey detected yet.\n\nPlug in the token now.\n\nPress c to continue without a YubiKey.\nPress q to cancel." 14 80
          if answer="$(read_key_with_timeout "$poll_seconds")"; then
            :
          else
            continue
          fi
        else
          divider
          printf '%s\n' "No YubiKey detected."
          printf '%s' "Press [w] to keep waiting, [c] to continue, or [q] to cancel: " >&2
          IFS= read -r answer
        fi

        case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
          c) return 0 ;;
          q) return 1 ;;
          w)
            if ! ui_is_dialog; then
              printf '%s\n' "Waiting for a YubiKey. Press Ctrl-C to stop."
              sleep "$poll_seconds"
            fi
            ;;
          "")
            if ui_is_dialog; then
              continue
            fi
            return 0
            ;;
          *)
            printf '%s\n' "Please choose w, c, or q." >&2
            ;;
        esac
      done
    }

    write_secret_file() {
      local target_path="$1"
      local secret="$2"
      (
        umask 077
        printf '%s\n' "$secret" > "$target_path"
      )
    }

    run_privileged() {
      "$sudo_bin" -n "$@"
    }

    default_or_prompt_existing_file() {
      local label="$1"
      local default_value="$2"

      if [ -n "$default_value" ] && [ -f "$default_value" ]; then
        printf '%s' "$default_value"
        return 0
      fi

      prompt_existing_file "$label" "$default_value" "required"
    }

    default_or_prompt_existing_dir() {
      local label="$1"
      local default_value="$2"

      if [ -n "$default_value" ] && [ -d "$default_value" ]; then
        printf '%s' "$default_value"
        return 0
      fi

      prompt_existing_dir "$label" "$default_value" "required"
    }

    block_source_to_disk_path() {
      local source_path="$1"
      local parent_name=""

      [ -b "$source_path" ] || return 0
      parent_name="$(lsblk -ndo PKNAME "$source_path" 2>/dev/null || true)"
      if [ -n "$parent_name" ]; then
        printf '/dev/%s' "$parent_name"
      else
        printf '%s' "$source_path"
      fi
    }

    list_system_disk_paths() {
      local mount_path=""
      local source_path=""
      local disk_path=""

      for mount_path in / /boot /boot/efi /boot/firmware; do
        source_path="$(findmnt -n -o SOURCE --target "$mount_path" 2>/dev/null || true)"
        [ -n "$source_path" ] || continue
        disk_path="$(block_source_to_disk_path "$source_path")"
        [ -n "$disk_path" ] || continue
        printf '%s\n' "$disk_path"
      done | sort -u
    }

    path_is_listed() {
      local needle="$1"
      shift
      local candidate=""

      for candidate in "$@"; do
        if [ "$candidate" = "$needle" ]; then
          return 0
        fi
      done

      return 1
    }

    disk_identity_for_usb_disk() {
      local serial="$1"
      local vendor="$2"
      local model="$3"
      local size="$4"
      local disk_path="$5"

      if [ -n "$serial" ]; then
        printf 'serial:%s' "$serial"
      elif [ -n "$vendor$model$size" ]; then
        printf 'descriptor:%s|%s|%s' "$vendor" "$model" "$size"
      else
        printf 'path:%s' "$disk_path"
      fi
    }

    list_usb_disks() {
      local -a excluded_disk_identities=("$@")
      local disk_path=""
      local disk_identity=""
      local size=""
      local serial=""
      local vendor=""
      local model=""
      local description=""
      local -a system_disks=()

      mapfile -t system_disks < <(list_system_disk_paths)

      lsblk -J -o PATH,RM,TRAN,TYPE,SIZE,LABEL,SERIAL,VENDOR,MODEL 2>/dev/null |
        jq -r '
          [
            .blockdevices[]?
            | select(.type == "disk")
            | select(((.tran // "") == "usb") or (((.rm // 0) | tostring) == "1"))
            | [
                (.path // ""),
                (.size // ""),
                (.serial // ""),
                (.vendor // ""),
                (.model // ""),
                ([.vendor // "", .model // "", .serial // "", .label // ""] | map(select(. != "")) | join(" "))
              ]
            | @tsv
          ][]
        ' 2>/dev/null |
        while IFS=$'\t' read -r disk_path size serial vendor model description; do
          [ -n "$disk_path" ] || continue
          if path_is_listed "$disk_path" "''${system_disks[@]}"; then
            continue
          fi
          disk_identity="$(disk_identity_for_usb_disk "$serial" "$vendor" "$model" "$size" "$disk_path")"
          if [ "''${#excluded_disk_identities[@]}" -gt 0 ] && path_is_listed "$disk_identity" "''${excluded_disk_identities[@]}"; then
            continue
          fi
          [ -n "$description" ] || description="$disk_path"
          printf '%s\t%s\t%s\t%s\n' "$disk_path" "$disk_identity" "$size" "$description"
        done
    }

    list_disk_mount_paths() {
      local disk_path="$1"

      lsblk -J -o PATH,TYPE,MOUNTPOINTS "$disk_path" 2>/dev/null |
        jq -r '
          .blockdevices[]? | recurse(.children[]?)
          | (.mountpoints // [])[]?
          | select(. != null and . != "")
        ' 2>/dev/null |
        awk '{ print length, $0 }' |
        sort -rn |
        cut -d" " -f2-
    }

    unmount_disk_mount_paths() {
      local disk_path="$1"
      local mount_path=""

      while IFS= read -r mount_path; do
        [ -n "$mount_path" ] || continue
        run_privileged umount "$mount_path"
      done < <(list_disk_mount_paths "$disk_path")
    }

    expected_first_partition_path_for_disk() {
      local disk_path="$1"
      local disk_name=""

      disk_name="$(basename "$disk_path")"
      case "$disk_name" in
        *[0-9])
          printf '%sp1' "$disk_path"
          ;;
        *)
          printf '%s1' "$disk_path"
          ;;
      esac
    }

    first_partition_path_for_disk() {
      local disk_path="$1"
      local expected_partition_path=""

      expected_partition_path="$(expected_first_partition_path_for_disk "$disk_path")"
      {
        lsblk -nrpo PATH,TYPE "$disk_path" 2>/dev/null |
          awk '$2 == "part" { print $1; exit }'
        if [ -b "$expected_partition_path" ]; then
          printf '%s\n' "$expected_partition_path"
        fi
      } |
        awk 'NF { print; exit }'
    }

    rescan_disk_partition_table() {
      local disk_path="$1"

      run_privileged partprobe "$disk_path" >/dev/null 2>&1 || true
      run_privileged blockdev --rereadpt "$disk_path" >/dev/null 2>&1 || true
      run_privileged partx -u "$disk_path" >/dev/null 2>&1 || true
      udevadm settle --timeout=5 >/dev/null 2>&1 || true
    }

    wait_for_partition_path() {
      local disk_path="$1"
      local partition_path=""
      local retries_remaining="15"

      while [ "$retries_remaining" -gt 0 ]; do
        partition_path="$(first_partition_path_for_disk "$disk_path" || true)"
        if [ -n "$partition_path" ]; then
          printf '%s' "$partition_path"
          return 0
        fi

        rescan_disk_partition_table "$disk_path"
        retries_remaining="$((retries_remaining - 1))"
        sleep 1
      done

      return 1
    }

    run_logged_command() {
      local log_path="$1"
      shift
      local argument=""

      {
        printf '$'
        for argument in "$@"; do
          printf ' %q' "$argument"
        done
        printf '\n'
        "$@"
      } >> "$log_path" 2>&1
    }

    format_and_mount_export_disk() {
      local disk_path="$1"
      local mount_path="$2"
      local volume_label="$3"
      local partition_path=""
      local format_log=""

      format_log="$(mktemp "/tmp/pd-pki-sign-export.XXXXXX.log")"

      if ! unmount_disk_mount_paths "$disk_path" >> "$format_log" 2>&1; then
        show_error "Drive Preparation Failed" "The selected removable disk could not be unmounted before formatting:
$disk_path

Review:
$format_log"
        return 1
      fi

      if ! run_logged_command "$format_log" "$sudo_bin" -n wipefs -af "$disk_path"; then
        show_error "Drive Preparation Failed" "The selected removable disk could not be wiped:
$disk_path

Review:
$format_log"
        return 1
      fi

      if ! run_logged_command "$format_log" "$sudo_bin" -n parted -s "$disk_path" mklabel gpt; then
        show_error "Drive Preparation Failed" "The selected removable disk could not be repartitioned:
$disk_path

Review:
$format_log"
        return 1
      fi

      if ! run_logged_command "$format_log" "$sudo_bin" -n parted -s -a optimal "$disk_path" mkpart primary fat32 1MiB 100%; then
        show_error "Drive Preparation Failed" "The FAT32 partition could not be created on:
$disk_path

Review:
$format_log"
        return 1
      fi

      partition_path="$(wait_for_partition_path "$disk_path")" || {
        show_error "Drive Preparation Failed" "The new partition did not appear after formatting:
$disk_path

Review:
$format_log"
        return 1
      }

      if ! run_logged_command "$format_log" "$sudo_bin" -n mkfs.vfat -F 32 -n "$volume_label" "$partition_path"; then
        show_error "Drive Preparation Failed" "The new FAT32 filesystem could not be created on:
$partition_path

Review:
$format_log"
        return 1
      fi

      install -d -m 700 "$mount_path"
      if ! run_logged_command "$format_log" "$sudo_bin" -n mount -t vfat -o "uid=$(id -u),gid=$(id -g),umask=077" "$partition_path" "$mount_path"; then
        rmdir "$mount_path" 2>/dev/null || true
        show_error "Drive Preparation Failed" "The freshly formatted removable disk could not be mounted:
$partition_path

Review:
$format_log"
        return 1
      fi

      rm -f "$format_log"
      printf '%s' "$partition_path"
    }

    mount_existing_disk_read_only() {
      local disk_path="$1"
      local mount_path="$2"
      local partition_path=""
      local existing_mount=""

      partition_path="$(first_partition_path_for_disk "$disk_path" || true)"
      if [ -z "$partition_path" ]; then
        show_error "Request USB Mount Failed" "No readable partition was found on:
$disk_path"
        return 1
      fi

      existing_mount="$(findmnt -n -o TARGET --source "$partition_path" 2>/dev/null | head -n1 || true)"
      if [ -n "$existing_mount" ]; then
        printf '%s' "$existing_mount"
        return 0
      fi

      install -d -m 700 "$mount_path"
      if ! run_privileged mount -o ro "$partition_path" "$mount_path"; then
        rmdir "$mount_path" 2>/dev/null || true
        show_error "Request USB Mount Failed" "The request USB partition could not be mounted read-only:
$partition_path"
        return 1
      fi

      printf '%s' "$mount_path"
    }

    list_pkcs11_certificate_objects() {
      local module_path="$1"
      local line=""
      local label=""
      local subject=""
      local object_id=""
      local uri=""
      local output=""

      [ -f "$module_path" ] || return 0
      output="$(pkcs11-tool --module "$module_path" --list-objects --type cert 2>/dev/null || true)"
      [ -n "$output" ] || return 0

      while IFS= read -r line; do
        case "$line" in
          "Certificate Object;"*)
            if [ -n "$uri" ]; then
              printf '%s\t%s\t%s\t%s\n' "$label" "$subject" "$object_id" "$uri"
            fi
            label=""
            subject=""
            object_id=""
            uri=""
            ;;
          "  label:"*)
            label="$(trim_whitespace "''${line#*:}")"
            ;;
          "  subject:"*)
            subject="$(trim_whitespace "''${line#*:}")"
            ;;
          "  ID:"*)
            object_id="$(trim_whitespace "''${line#*:}")"
            object_id="''${object_id%% (*}"
            ;;
          "  uri:"*)
            uri="$(trim_whitespace "''${line#*:}")"
            ;;
        esac
      done <<< "$output"

      if [ -n "$uri" ]; then
        printf '%s\t%s\t%s\t%s\n' "$label" "$subject" "$object_id" "$uri"
      fi
    }

    pkcs11_private_key_uri_from_cert_uri() {
      local cert_uri="$1"
      local uri_body=""
      local component=""
      local private_uri="pkcs11:"
      local first="1"
      local -a uri_parts=()

      case "$cert_uri" in
        pkcs11:*)
          uri_body="''${cert_uri#pkcs11:}"
          ;;
        *)
          printf '%s' "$cert_uri"
          return 0
          ;;
      esac

      IFS=';' read -r -a uri_parts <<< "$uri_body"
      for component in "''${uri_parts[@]}"; do
        case "$component" in
          ""|object=*|type=*|pin-source=*|pin-value=*)
            continue
            ;;
        esac
        if [ "$first" = "0" ]; then
          private_uri="$private_uri;"
        fi
        private_uri="$private_uri$component"
        first="0"
      done

      if [ "$first" = "0" ]; then
        private_uri="$private_uri;"
      fi
      private_uri="$private_uri"'type=private'
      printf '%s' "$private_uri"
    }

    prompt_pkcs11_private_key_uri() {
      local issuer_key_uri=""

      while true; do
        issuer_key_uri="$(prompt_text "PKCS#11 private key URI" "pkcs11:")" || return 1
        case "$issuer_key_uri" in
          pkcs11:*)
            printf '%s' "$issuer_key_uri"
            return 0
            ;;
          *)
            if ui_is_dialog; then
              dialog_info "Invalid PKCS#11 URI" "PKCS#11 key URIs must begin with:\npkcs11:"
            else
              printf '%s\n' "PKCS#11 key URIs must begin with: pkcs11:" >&2
            fi
            ;;
        esac
      done
    }

    choose_signer_backend() {
      local choice=""

      if ui_is_dialog; then
        choice="$(dialog_run --title "Choose Signer Backend" --menu "Choose how the issuer signing key should be accessed." 16 80 8 1 "YubiKey / PKCS#11 token" 2 "PEM issuer key file")" || return 1
        case "$choice" in
          1) printf '%s' "pkcs11"; return 0 ;;
          2) printf '%s' "file"; return 0 ;;
        esac
      fi

      while true; do
        print_header
        printf '%s\n' "Choose how the issuer signing key should be accessed."
        printf '%s\n' "  1. YubiKey / PKCS#11 token"
        printf '%s\n' "  2. PEM issuer key file"
        printf '%s\n' "  q. Cancel"
        printf '%s' "Selection: " >&2
        IFS= read -r choice

        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
          1) printf '%s' "pkcs11"; return 0 ;;
          2) printf '%s' "file"; return 0 ;;
          q) return 1 ;;
        esac

        printf '%s\n' "Please choose 1, 2, or q." >&2
      done
    }

    choose_pkcs11_key_uri() {
      local module_path="$1"
      local choice=""
      local selected_line=""
      local label=""
      local subject=""
      local object_id=""
      local cert_uri=""
      local label_display=""
      local subject_display=""
      local object_id_display=""
      local -a cert_lines=()
      local -a menu_items=()

      while true; do
        mapfile -t cert_lines < <(list_pkcs11_certificate_objects "$module_path")

        if [ "''${#cert_lines[@]}" -eq 0 ]; then
          if ui_is_dialog; then
            choice="$(dialog_run --title "No Token Certificates Found" --menu "No certificate objects were discovered through:\n$module_path\n\nYou can refresh after inserting a token, or enter a PKCS#11 key URI manually." 17 100 6 m "Enter a PKCS#11 URI manually" r "Refresh object list")" || return 1
            case "$choice" in
              r)
                continue
                ;;
              m)
                prompt_pkcs11_private_key_uri
                return $?
                ;;
            esac
          fi

          print_header
          printf '%s\n' "No certificate objects were discovered through $module_path."
          printf '%s' "Choose [m]anual URI, [r]efresh, or [q]uit: " >&2
          IFS= read -r choice
          case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
            q) return 1 ;;
            r|"") continue ;;
            m)
              prompt_pkcs11_private_key_uri
              return $?
              ;;
            *)
              printf '%s\n' "Please choose m, r, or q." >&2
              ;;
          esac
          continue
        fi

        if ui_is_dialog; then
          menu_items=()
          local index="1"
          for selected_line in "''${cert_lines[@]}"; do
            IFS=$'\t' read -r label subject object_id cert_uri <<< "$selected_line"
            label_display="$label"
            subject_display="$subject"
            object_id_display="$object_id"
            if [ -z "$label_display" ]; then
              label_display="unlabeled object"
            fi
            if [ -z "$subject_display" ]; then
              subject_display="subject unavailable"
            fi
            if [ -z "$object_id_display" ]; then
              object_id_display="unknown"
            fi
            menu_items+=("$index" "$label_display | $subject_display | id $object_id_display")
            index=$((index + 1))
          done
          menu_items+=("m" "Enter a PKCS#11 URI manually")
          menu_items+=("r" "Refresh object list")
          choice="$(dialog_run --title "Choose Token Certificate" --menu "Choose the certificate object that matches the issuer key.\n\nThe wizard will derive the matching private-key URI from the selected token object ID." 22 110 "$(dialog_menu_height)" "''${menu_items[@]}")" || return 1
          case "$choice" in
            r)
              continue
              ;;
            m)
              prompt_pkcs11_private_key_uri
              return $?
              ;;
            *)
              selected_line="''${cert_lines[$((choice - 1))]}"
              IFS=$'\t' read -r label subject object_id cert_uri <<< "$selected_line"
              printf '%s' "$(pkcs11_private_key_uri_from_cert_uri "$cert_uri")"
              return 0
              ;;
          esac
        fi

        print_header
        printf '%s\n' "Discovered certificate objects through $module_path:"
        local index="1"
        for selected_line in "''${cert_lines[@]}"; do
          IFS=$'\t' read -r label subject object_id cert_uri <<< "$selected_line"
          label_display="$(trim_whitespace "$label")"
          if [ -z "$label_display" ]; then
            label_display="unlabeled object"
          fi
          printf '%s\n' "  $index. $label_display"
          if [ -n "$subject" ]; then
            printf '%s\n' "     subject: $subject"
          fi
          if [ -n "$object_id" ]; then
            printf '%s\n' "     id: $object_id"
          fi
          index=$((index + 1))
        done
        printf '%s' "Select an object number, [m]anual URI, [r]efresh, or [q]uit: " >&2
        IFS= read -r choice
        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
          q) return 1 ;;
          r|"") continue ;;
          m)
            prompt_pkcs11_private_key_uri
            return $?
            ;;
          *[!0-9]*)
            printf '%s\n' "Please choose a number, m, r, or q." >&2
            ;;
          *)
            if [ "$choice" -lt 1 ] || [ "$choice" -gt "''${#cert_lines[@]}" ]; then
              printf '%s\n' "That selection is out of range." >&2
              continue
            fi
            selected_line="''${cert_lines[$((choice - 1))]}"
            IFS=$'\t' read -r label subject object_id cert_uri <<< "$selected_line"
            printf '%s' "$(pkcs11_private_key_uri_from_cert_uri "$cert_uri")"
            return 0
            ;;
        esac
      done
    }

    list_usb_mounts() {
      if ! command -v lsblk >/dev/null 2>&1; then
        return 0
      fi

      lsblk -J -o NAME,PATH,RM,TRAN,TYPE,MOUNTPOINTS,LABEL,SERIAL,VENDOR,MODEL 2>/dev/null |
        jq -r '
          def mounts:
            (.mountpoints // []) | map(select(. != null and . != ""));
          [
            .blockdevices[]? | recurse(.children[]?)
            | select(((.tran // "") == "usb") or (((.rm // 0) | tostring) == "1"))
            | . as $device
            | mounts[]? as $mount
            | [
                $mount,
                (.path // ("/dev/" + (.name // ""))),
                (.label // ""),
                ([.vendor // "", .model // "", .serial // ""] | map(select(. != "")) | join(" "))
              ]
            | @tsv
          ]
          | unique[]
        ' 2>/dev/null || true
    }

    request_bundle_summary_text() {
      local bundle_dir="$1"
      local role=""
      local common_name=""
      local requested_days=""
      local requested_profile=""
      local path_len=""
      local sans=""

      role="$(request_bundle_role "$bundle_dir")"
      common_name="$(request_bundle_common_name "$bundle_dir")"
      requested_days="$(request_bundle_days "$bundle_dir")"
      requested_profile="$(request_bundle_profile "$bundle_dir")"
      path_len="$(request_bundle_path_len "$bundle_dir")"
      sans="$(request_bundle_sans "$bundle_dir")"

      printf '%s\n' "Path: $bundle_dir"
      printf '%s\n' "Role: $(role_title_for_id "$role")"
      if [ -n "$common_name" ]; then
        printf '%s\n' "Common name: $common_name"
      fi
      if [ -n "$requested_profile" ]; then
        printf '%s\n' "Requested profile: $requested_profile"
      fi
      if [ -n "$path_len" ]; then
        printf '%s\n' "Requested pathLen: $path_len"
      fi
      if [ -n "$requested_days" ]; then
        printf '%s\n' "Requested days: $requested_days"
      fi
      if [ -n "$sans" ]; then
        printf '%s\n' "Subject alternative names: $sans"
      fi
    }

    csr_subject() {
      openssl req -in "$1" -noout -subject 2>/dev/null | sed 's/^subject= *//' || true
    }

    csr_public_key_algorithm() {
      openssl req -in "$1" -noout -text 2>/dev/null |
        awk -F': ' '/Public Key Algorithm/ { print $2; exit }' || true
    }

    csr_public_key_bits() {
      openssl req -in "$1" -noout -text 2>/dev/null |
        awk -F'[()]' '/Public-Key:/ { print $2; exit }' |
        sed 's/ bits\{0,1\}$//' || true
    }

    csr_basic_constraints() {
      openssl req -in "$1" -noout -text 2>/dev/null |
        awk '
          /X509v3 Basic Constraints/ {
            getline
            gsub(/^[[:space:]]+/, "", $0)
            print
            exit
          }
        ' || true
    }

    request_bundle_review_text() {
      local bundle_dir="$1"
      local csr_path=""
      local subject=""
      local algorithm=""
      local bits=""
      local constraints=""

      request_bundle_summary_text "$bundle_dir"
      csr_path="$(request_bundle_csr_path "$bundle_dir")"
      if [ -z "$csr_path" ]; then
        return 0
      fi

      subject="$(csr_subject "$csr_path")"
      algorithm="$(csr_public_key_algorithm "$csr_path")"
      bits="$(csr_public_key_bits "$csr_path")"
      constraints="$(csr_basic_constraints "$csr_path")"

      if [ -n "$subject" ]; then
        printf '%s\n' "CSR subject: $subject"
      fi
      if [ -n "$algorithm" ] || [ -n "$bits" ]; then
        if [ -n "$algorithm" ] && [ -n "$bits" ]; then
          printf '%s\n' "CSR key: $algorithm ($bits bits)"
        elif [ -n "$algorithm" ]; then
          printf '%s\n' "CSR key: $algorithm"
        else
          printf '%s\n' "CSR key size: $bits bits"
        fi
      fi
      if [ -n "$constraints" ]; then
        printf '%s\n' "CSR basic constraints: $constraints"
      fi
    }

    signed_bundle_summary_text() {
      local bundle_dir="$1"
      local role=""
      local common_name=""
      local serial=""
      local not_after=""

      role="$(request_bundle_role "$bundle_dir")"
      common_name="$(request_bundle_common_name "$bundle_dir")"
      serial="$(signed_bundle_serial "$bundle_dir")"
      not_after="$(signed_bundle_not_after "$bundle_dir")"

      printf '%s\n' "Path: $bundle_dir"
      printf '%s\n' "Role: $(role_title_for_id "$role")"
      if [ -n "$common_name" ]; then
        printf '%s\n' "Common name: $common_name"
      fi
      if [ -n "$serial" ]; then
        printf '%s\n' "Serial: $serial"
      fi
      if [ -n "$not_after" ]; then
        printf '%s\n' "Not after: $not_after"
      fi
    }

    root_inventory_summary_text() {
      local inventory_dir="$1"
      local root_id=""
      local subject=""
      local yubikey_serial=""

      root_id="$(root_inventory_bundle_root_id "$inventory_dir")"
      subject="$(root_inventory_bundle_subject "$inventory_dir")"
      yubikey_serial="$(root_inventory_bundle_yubikey_serial "$inventory_dir")"

      printf '%s\n' "Path: $inventory_dir"
      if [ -n "$root_id" ]; then
        printf '%s\n' "Root ID: $root_id"
      fi
      if [ -n "$subject" ]; then
        printf '%s\n' "Subject: $subject"
      fi
      if [ -n "$yubikey_serial" ]; then
        printf '%s\n' "YubiKey serial: $yubikey_serial"
      fi
    }

    root_yubikey_identity_summary_text() {
      local summary_path="$1"
      local root_id=""
      local inventory_serial=""
      local yubikey_serial=""
      local certificate_match=""
      local public_key_match=""

      root_id="$(root_yubikey_identity_summary_root_id "$summary_path")"
      inventory_serial="$(root_yubikey_identity_summary_inventory_serial "$summary_path")"
      yubikey_serial="$(root_yubikey_identity_summary_yubikey_serial "$summary_path")"
      certificate_match="$(root_yubikey_identity_summary_certificate_match "$summary_path")"
      public_key_match="$(root_yubikey_identity_summary_public_key_match "$summary_path")"

      printf '%s\n' "Summary: $summary_path"
      if [ -n "$root_id" ]; then
        printf '%s\n' "Root ID: $root_id"
      fi
      if [ -n "$inventory_serial" ]; then
        printf '%s\n' "Inventory serial: $inventory_serial"
      fi
      if [ -n "$yubikey_serial" ]; then
        printf '%s\n' "Inserted serial: $yubikey_serial"
      fi
      if [ -n "$certificate_match" ]; then
        printf '%s\n' "Certificate match: $certificate_match"
      fi
      if [ -n "$public_key_match" ]; then
        printf '%s\n' "Verified public key match: $public_key_match"
      fi
    }

    choose_usb_mount() {
      local access_mode="$1"
      local intro="$2"
      local choice=""
      local mount_path=""
      local device_path=""
      local label=""
      local description=""
      local selected_line=""
      local menu_label=""
      local -a usb_lines=()
      local -a menu_items=()

      while true; do
        mapfile -t usb_lines < <(list_usb_mounts)

        if ui_is_dialog && [ "''${#usb_lines[@]}" -eq 0 ]; then
          while [ "''${#usb_lines[@]}" -eq 0 ]; do
            dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Waiting For Removable Media" --infobox "$intro\n\nNo mounted removable volumes detected yet.\n\nPlug in the drive now.\n\nPress m for a manual mounted path.\nPress q to cancel." 15 80
            if choice="$(read_key_with_timeout "$poll_seconds")"; then
              case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
                m)
                  mount_path="$(prompt_existing_dir "Mounted USB path" "" "required")" || return 1
                  if [ "$access_mode" = "write" ] && [ ! -w "$mount_path" ]; then
                    dialog_info "Not Writable" "That path is not writable:\n$mount_path"
                    continue
                  fi
                  printf '%s' "$mount_path"
                  return 0
                  ;;
                q)
                  return 1
                  ;;
              esac
            fi
            mapfile -t usb_lines < <(list_usb_mounts)
          done
        fi

        print_header
        printf '%s\n' "$intro"

        if [ "''${#usb_lines[@]}" -eq 0 ]; then
          if ui_is_dialog; then
            mount_path="$(prompt_existing_dir "Mounted USB path" "" "required")" || return 1
            if [ "$access_mode" = "write" ] && [ ! -w "$mount_path" ]; then
              dialog_info "Not Writable" "That path is not writable:\n$mount_path"
              continue
            fi
            printf '%s' "$mount_path"
            return 0
          fi
          printf '%s\n' "No mounted removable volumes were detected automatically."
        else
          if ui_is_dialog; then
            menu_items=()
            local index="1"
            for selected_line in "''${usb_lines[@]}"; do
              IFS=$'\t' read -r mount_path device_path label description <<< "$selected_line"
              menu_label="$mount_path | $device_path"
              if [ -n "$label" ]; then
                menu_label="$menu_label | $label"
              fi
              if [ -n "$description" ]; then
                menu_label="$menu_label | $description"
              fi
              menu_items+=("$index" "$menu_label")
              index=$((index + 1))
            done
            menu_items+=("m" "Manual mounted path")
            menu_items+=("r" "Refresh device list")
            choice="$(dialog_run --title "Choose Removable Media" --menu "$intro\n\nYubiKey status: $(yubikey_status_line)" 20 100 "$(dialog_menu_height)" "''${menu_items[@]}")" || return 1
            case "$choice" in
              r)
                continue
                ;;
              m)
                mount_path="$(prompt_existing_dir "Mounted USB path" "" "required")" || return 1
                if [ "$access_mode" = "write" ] && [ ! -w "$mount_path" ]; then
                  dialog_info "Not Writable" "That path is not writable:\n$mount_path"
                  continue
                fi
                printf '%s' "$mount_path"
                return 0
                ;;
              *)
                selected_line="''${usb_lines[$((choice - 1))]}"
                IFS=$'\t' read -r mount_path device_path label description <<< "$selected_line"
                if [ "$access_mode" = "write" ] && [ ! -w "$mount_path" ]; then
                  dialog_info "Not Writable" "That volume is not writable:\n$mount_path"
                  continue
                fi
                printf '%s' "$mount_path"
                return 0
                ;;
            esac
          fi

          local index="1"
          printf '%s\n' "Mounted removable volumes:"
          for selected_line in "''${usb_lines[@]}"; do
            IFS=$'\t' read -r mount_path device_path label description <<< "$selected_line"
            printf '%s\n' "  $index. $mount_path"
            printf '%s\n' "     device: $device_path"
            if [ -n "$label" ]; then
              printf '%s\n' "     label: $label"
            fi
            if [ -n "$description" ]; then
              printf '%s\n' "     details: $description"
            fi
            index=$((index + 1))
          done
        fi

        printf '%s' "Select a USB volume number, [m]anual path, [r]efresh, or [q]uit: " >&2
        IFS= read -r choice

        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
          q) return 1 ;;
          r|"") continue ;;
          m)
            mount_path="$(prompt_existing_dir "Mounted USB path" "" "required")"
            if [ "$access_mode" = "write" ] && [ ! -w "$mount_path" ]; then
              printf '%s\n' "That path is not writable: $mount_path" >&2
              continue
            fi
            printf '%s' "$mount_path"
            return 0
            ;;
          *[!0-9]*)
            printf '%s\n' "Please choose a number, m, r, or q." >&2
            ;;
          *)
            if [ "$choice" -lt 1 ] || [ "$choice" -gt "''${#usb_lines[@]}" ]; then
              printf '%s\n' "That selection is out of range." >&2
              continue
            fi
            selected_line="''${usb_lines[$((choice - 1))]}"
            IFS=$'\t' read -r mount_path device_path label description <<< "$selected_line"
            if [ "$access_mode" = "write" ] && [ ! -w "$mount_path" ]; then
              printf '%s\n' "That volume is not writable: $mount_path" >&2
              continue
            fi
            printf '%s' "$mount_path"
            return 0
            ;;
        esac
      done
    }

    choose_request_bundle_from_mount() {
      local mount_path="$1"
      local choice=""
      local selected_line=""
      local bundle_dir=""
      local role=""
      local common_name=""
      local basename=""
      local common_name_display=""
      local basename_display=""
      local -a bundle_lines=()
      local -a menu_items=()

      while true; do
        mapfile -t bundle_lines < <(find_request_bundles "$mount_path")

        if [ "''${#bundle_lines[@]}" -eq 0 ]; then
          if ui_is_dialog; then
            if dialog_run --title "No Request Bundles Found" --yesno "No request bundles were found on:\n$mount_path\n\nChoose Yes to refresh after plugging in media or copying files.\nChoose No to go back." 14 80; then
              continue
            fi
            return 1
          fi
          printf '%s\n' "No request bundles were found on that volume."
        else
          if ui_is_dialog; then
            menu_items=()
            local index="1"
            for selected_line in "''${bundle_lines[@]}"; do
              IFS=$'\t' read -r bundle_dir role common_name basename <<< "$selected_line"
              common_name_display="$common_name"
              basename_display="$basename"
              if [ -z "$common_name_display" ]; then
                common_name_display="unknown CN"
              fi
              if [ -z "$basename_display" ]; then
                basename_display="unknown basename"
              fi
              menu_items+=("$index" "$(role_title_for_id "$role") | $common_name_display | $basename_display")
              index=$((index + 1))
            done
            choice="$(dialog_run --title "Choose Request Bundle" --menu "Scanning $mount_path for request bundles." 20 100 "$(dialog_menu_height)" "''${menu_items[@]}")" || return 1
            selected_line="''${bundle_lines[$((choice - 1))]}"
            IFS=$'\t' read -r bundle_dir role common_name basename <<< "$selected_line"
            printf '%s' "$bundle_dir"
            return 0
          fi

          print_header
          printf '%s\n' "Scanning $mount_path for request bundles."
          local index="1"
          for selected_line in "''${bundle_lines[@]}"; do
            IFS=$'\t' read -r bundle_dir role common_name basename <<< "$selected_line"
            printf '%s\n' "  $index. $bundle_dir"
            printf '%s\n' "     role: $(role_title_for_id "$role")"
            if [ -n "$common_name" ]; then
              printf '%s\n' "     common name: $common_name"
            fi
            if [ -n "$basename" ]; then
              printf '%s\n' "     basename: $basename"
            fi
            index=$((index + 1))
          done
        fi

        printf '%s' "Select a bundle number, [r]efresh, or [q]uit: " >&2
        IFS= read -r choice
        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
          q) return 1 ;;
          r|"") continue ;;
          *[!0-9]*)
            printf '%s\n' "Please choose a number, r, or q." >&2
            ;;
          *)
            if [ "$choice" -lt 1 ] || [ "$choice" -gt "''${#bundle_lines[@]}" ]; then
              printf '%s\n' "That selection is out of range." >&2
              continue
            fi
            selected_line="''${bundle_lines[$((choice - 1))]}"
            IFS=$'\t' read -r bundle_dir role common_name basename <<< "$selected_line"
            printf '%s' "$bundle_dir"
            return 0
            ;;
        esac
      done
    }

    choose_signed_bundle_from_mount() {
      local mount_path="$1"
      local choice=""
      local selected_line=""
      local bundle_dir=""
      local role=""
      local common_name=""
      local serial=""
      local common_name_display=""
      local serial_display=""
      local -a bundle_lines=()
      local -a menu_items=()

      while true; do
        mapfile -t bundle_lines < <(find_signed_bundles "$mount_path")

        if [ "''${#bundle_lines[@]}" -eq 0 ]; then
          if ui_is_dialog; then
            if dialog_run --title "No Signed Bundles Found" --yesno "No signed bundles were found on:\n$mount_path\n\nChoose Yes to refresh after plugging in media or copying files.\nChoose No to go back." 14 80; then
              continue
            fi
            return 1
          fi
          printf '%s\n' "No signed bundles were found on that volume."
        else
          if ui_is_dialog; then
            menu_items=()
            local index="1"
            for selected_line in "''${bundle_lines[@]}"; do
              IFS=$'\t' read -r bundle_dir role common_name serial <<< "$selected_line"
              common_name_display="$common_name"
              serial_display="$serial"
              if [ -z "$common_name_display" ]; then
                common_name_display="unknown CN"
              fi
              if [ -z "$serial_display" ]; then
                serial_display="unknown"
              fi
              menu_items+=("$index" "$(role_title_for_id "$role") | $common_name_display | serial $serial_display")
              index=$((index + 1))
            done
            choice="$(dialog_run --title "Choose Signed Bundle" --menu "Scanning $mount_path for signed bundles." 20 100 "$(dialog_menu_height)" "''${menu_items[@]}")" || return 1
            selected_line="''${bundle_lines[$((choice - 1))]}"
            IFS=$'\t' read -r bundle_dir role common_name serial <<< "$selected_line"
            printf '%s' "$bundle_dir"
            return 0
          fi

          print_header
          printf '%s\n' "Scanning $mount_path for signed bundles."
          local index="1"
          for selected_line in "''${bundle_lines[@]}"; do
            IFS=$'\t' read -r bundle_dir role common_name serial <<< "$selected_line"
            printf '%s\n' "  $index. $bundle_dir"
            printf '%s\n' "     role: $(role_title_for_id "$role")"
            if [ -n "$common_name" ]; then
              printf '%s\n' "     common name: $common_name"
            fi
            if [ -n "$serial" ]; then
              printf '%s\n' "     serial: $serial"
            fi
            index=$((index + 1))
          done
        fi

        printf '%s' "Select a bundle number, [r]efresh, or [q]uit: " >&2
        IFS= read -r choice
        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
          q) return 1 ;;
          r|"") continue ;;
          *[!0-9]*)
            printf '%s\n' "Please choose a number, r, or q." >&2
            ;;
          *)
            if [ "$choice" -lt 1 ] || [ "$choice" -gt "''${#bundle_lines[@]}" ]; then
              printf '%s\n' "That selection is out of range." >&2
              continue
            fi
            selected_line="''${bundle_lines[$((choice - 1))]}"
            IFS=$'\t' read -r bundle_dir role common_name serial <<< "$selected_line"
            printf '%s' "$bundle_dir"
            return 0
            ;;
        esac
      done
    }

    choose_role() {
      local choice=""

      if ui_is_dialog; then
        choice="$(dialog_run --title "Choose Certificate Role" --menu "Choose a certificate role." 16 70 8 1 "Intermediate Signing Authority" 2 "OpenVPN Server Leaf" 3 "OpenVPN Client Leaf")" || return 1
        case "$choice" in
          1) printf '%s' "intermediate-signing-authority"; return 0 ;;
          2) printf '%s' "openvpn-server-leaf"; return 0 ;;
          3) printf '%s' "openvpn-client-leaf"; return 0 ;;
        esac
      fi

      while true; do
        print_header
        printf '%s\n' "Choose a certificate role."
        printf '%s\n' "  1. Intermediate Signing Authority"
        printf '%s\n' "  2. OpenVPN Server Leaf"
        printf '%s\n' "  3. OpenVPN Client Leaf"
        printf '%s\n' "  q. Cancel"
        printf '%s' "Selection: " >&2
        IFS= read -r choice

        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
          1) printf '%s' "intermediate-signing-authority"; return 0 ;;
          2) printf '%s' "openvpn-server-leaf"; return 0 ;;
          3) printf '%s' "openvpn-client-leaf"; return 0 ;;
          q) return 1 ;;
        esac

        printf '%s\n' "Please choose 1, 2, 3, or q." >&2
      done
    }

    choose_issuer_profile() {
      local choice=""

      if ui_is_dialog; then
        choice="$(dialog_run --title "Choose Issuer Profile" --menu "Choose an issuer profile." 16 70 8 1 "Root CA" 2 "Intermediate CA" 3 "Custom issuer paths")" || return 1
        case "$choice" in
          1) printf '%s' "root"; return 0 ;;
          2) printf '%s' "intermediate"; return 0 ;;
          3) printf '%s' "custom"; return 0 ;;
        esac
      fi

      while true; do
        print_header
        printf '%s\n' "Choose an issuer profile."
        printf '%s\n' "  1. Root CA"
        printf '%s\n' "  2. Intermediate CA"
        printf '%s\n' "  3. Custom issuer paths"
        printf '%s\n' "  q. Cancel"
        printf '%s' "Selection: " >&2
        IFS= read -r choice

        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
          1) printf '%s' "root"; return 0 ;;
          2) printf '%s' "intermediate"; return 0 ;;
          3) printf '%s' "custom"; return 0 ;;
          q) return 1 ;;
        esac

        printf '%s\n' "Please choose 1, 2, 3, or q." >&2
      done
    }

    show_request_bundle_summary() {
      local bundle_dir="$1"

      if ui_is_dialog; then
        dialog_info "Request Bundle Summary" "$(request_bundle_summary_text "$bundle_dir")"
        return 0
      fi

      divider
      printf '%s\n' "Selected request bundle"
      request_bundle_summary_text "$bundle_dir"
      divider
    }

    show_signed_bundle_summary() {
      local bundle_dir="$1"

      if ui_is_dialog; then
        dialog_info "Signed Bundle Summary" "$(signed_bundle_summary_text "$bundle_dir")"
        return 0
      fi

      divider
      printf '%s\n' "Selected signed bundle"
      signed_bundle_summary_text "$bundle_dir"
      divider
    }

    show_root_inventory_summary() {
      local inventory_dir="$1"

      if ui_is_dialog; then
        dialog_info "Root Inventory Summary" "$(root_inventory_summary_text "$inventory_dir")"
        return 0
      fi

      divider
      printf '%s\n' "Selected root inventory"
      root_inventory_summary_text "$inventory_dir"
      divider
    }

    show_root_yubikey_identity_summary() {
      local summary_path="$1"

      if ui_is_dialog; then
        dialog_info "Root CA YubiKey Verified" "$(root_yubikey_identity_summary_text "$summary_path")"
        return 0
      fi

      divider
      printf '%s\n' "Root CA YubiKey verified"
      root_yubikey_identity_summary_text "$summary_path"
      divider
    }

    choose_root_inventory_dir() {
      local root_dir="$1"
      local choice=""
      local selected_line=""
      local inventory_dir=""
      local root_id=""
      local subject=""
      local yubikey_serial=""
      local subject_display=""
      local yubikey_serial_display=""
      local -a inventory_lines=()
      local -a menu_items=()

      while true; do
        mapfile -t inventory_lines < <(find_root_inventory_dirs "$root_dir")

        if [ "''${#inventory_lines[@]}" -eq 0 ]; then
          if ui_is_dialog; then
            if dialog_run --title "No Root Inventory Found" --yesno "No committed root inventory entries were found under:\n$root_dir\n\nChoose Yes to refresh after copying inventory files.\nChoose No to enter a directory manually." 16 90; then
              continue
            fi
            inventory_dir="$(prompt_existing_dir "Root inventory directory" "$root_dir" "required")" || return 1
            printf '%s' "$inventory_dir"
            return 0
          fi

          print_header
          printf '%s\n' "No committed root inventory entries were found under $root_dir."
          printf '%s' "Choose [m]anual directory, [r]efresh, or [q]uit: " >&2
          IFS= read -r choice
          case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
            q) return 1 ;;
            r|"") continue ;;
            m)
              inventory_dir="$(prompt_existing_dir "Root inventory directory" "$root_dir" "required")" || return 1
              printf '%s' "$inventory_dir"
              return 0
              ;;
            *)
              printf '%s\n' "Please choose m, r, or q." >&2
              ;;
          esac
          continue
        fi

        if ui_is_dialog; then
          menu_items=()
          local index="1"
          for selected_line in "''${inventory_lines[@]}"; do
            IFS=$'\t' read -r inventory_dir root_id subject yubikey_serial <<< "$selected_line"
            subject_display="$subject"
            yubikey_serial_display="$yubikey_serial"
            if [ -z "$subject_display" ]; then
              subject_display="subject unavailable"
            fi
            if [ -z "$yubikey_serial_display" ]; then
              yubikey_serial_display="serial unavailable"
            fi
            menu_items+=("$index" "$root_id | $subject_display | serial $yubikey_serial_display")
            index=$((index + 1))
          done
          menu_items+=("m" "Enter a root inventory directory manually")
          menu_items+=("r" "Refresh inventory list")
          choice="$(dialog_run --title "Choose Root Inventory" --menu "Choose the committed root inventory entry that should authorize this root signing ceremony." 22 110 "$(dialog_menu_height)" "''${menu_items[@]}")" || return 1
          case "$choice" in
            r)
              continue
              ;;
            m)
              inventory_dir="$(prompt_existing_dir "Root inventory directory" "$root_dir" "required")" || return 1
              printf '%s' "$inventory_dir"
              return 0
              ;;
            *)
              selected_line="''${inventory_lines[$((choice - 1))]}"
              IFS=$'\t' read -r inventory_dir root_id subject yubikey_serial <<< "$selected_line"
              printf '%s' "$inventory_dir"
              return 0
              ;;
          esac
        fi

        print_header
        printf '%s\n' "Committed root inventory entries under $root_dir:"
        local index="1"
        for selected_line in "''${inventory_lines[@]}"; do
          IFS=$'\t' read -r inventory_dir root_id subject yubikey_serial <<< "$selected_line"
          printf '%s\n' "  $index. $inventory_dir"
          printf '%s\n' "     root id: $root_id"
          if [ -n "$subject" ]; then
            printf '%s\n' "     subject: $subject"
          fi
          if [ -n "$yubikey_serial" ]; then
            printf '%s\n' "     YubiKey serial: $yubikey_serial"
          fi
          index=$((index + 1))
        done

        printf '%s' "Select a root inventory number, [m]anual directory, [r]efresh, or [q]uit: " >&2
        IFS= read -r choice
        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
          q) return 1 ;;
          r|"") continue ;;
          m)
            inventory_dir="$(prompt_existing_dir "Root inventory directory" "$root_dir" "required")" || return 1
            printf '%s' "$inventory_dir"
            return 0
            ;;
          *[!0-9]*)
            printf '%s\n' "Please choose a number, m, r, or q." >&2
            ;;
          *)
            if [ "$choice" -lt 1 ] || [ "$choice" -gt "''${#inventory_lines[@]}" ]; then
              printf '%s\n' "That selection is out of range." >&2
              continue
            fi
            selected_line="''${inventory_lines[$((choice - 1))]}"
            IFS=$'\t' read -r inventory_dir root_id subject yubikey_serial <<< "$selected_line"
            printf '%s' "$inventory_dir"
            return 0
            ;;
        esac
      done
    }

    choose_yubikey_serial() {
      local choice=""
      local serial=""
      local -a serials=()
      local -a menu_items=()

      while true; do
        mapfile -t serials < <(detect_yubikey_serials)

        if [ "''${#serials[@]}" -eq 1 ]; then
          printf '%s' "''${serials[0]}"
          return 0
        fi

        if [ "''${#serials[@]}" -eq 0 ]; then
          serial="$(prompt_text "YubiKey serial" "")" || return 1
          if [ -n "$serial" ]; then
            printf '%s' "$serial"
            return 0
          fi
          if ui_is_dialog; then
            dialog_info "Missing YubiKey Serial" "A YubiKey serial is required for root identity verification."
          else
            printf '%s\n' "A YubiKey serial is required for root identity verification." >&2
          fi
          continue
        fi

        if ui_is_dialog; then
          menu_items=()
          local index="1"
          for serial in "''${serials[@]}"; do
            menu_items+=("$index" "$serial")
            index=$((index + 1))
          done
          menu_items+=("m" "Enter a YubiKey serial manually")
          menu_items+=("r" "Refresh detected YubiKeys")
          choice="$(dialog_run --title "Choose YubiKey Serial" --menu "Choose the inserted YubiKey serial for root identity verification." 20 90 "$(dialog_menu_height)" "''${menu_items[@]}")" || return 1
          case "$choice" in
            r)
              continue
              ;;
            m)
              serial="$(prompt_text "YubiKey serial" "")" || return 1
              ;;
            *)
              serial="''${serials[$((choice - 1))]}"
              ;;
          esac
        else
          print_header
          printf '%s\n' "Detected YubiKey serials:"
          local index="1"
          for serial in "''${serials[@]}"; do
            printf '%s\n' "  $index. $serial"
            index=$((index + 1))
          done
          printf '%s' "Select a serial number, [m]anual entry, [r]efresh, or [q]uit: " >&2
          IFS= read -r choice
          case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
            q) return 1 ;;
            r|"") continue ;;
            m)
              serial="$(prompt_text "YubiKey serial" "")" || return 1
              ;;
            *[!0-9]*)
              printf '%s\n' "Please choose a number, m, r, or q." >&2
              continue
              ;;
            *)
              if [ "$choice" -lt 1 ] || [ "$choice" -gt "''${#serials[@]}" ]; then
                printf '%s\n' "That selection is out of range." >&2
                continue
              fi
              serial="''${serials[$((choice - 1))]}"
              ;;
          esac
        fi

        if [ -n "$serial" ]; then
          printf '%s' "$serial"
          return 0
        fi

        if ui_is_dialog; then
          dialog_info "Missing YubiKey Serial" "A YubiKey serial is required for root identity verification."
        else
          printf '%s\n' "A YubiKey serial is required for root identity verification." >&2
        fi
      done
    }

    inventory_root_key_uri() {
      local inventory_dir="$1"

      if [ -f "$inventory_dir/root-key-uri.txt" ]; then
        tr -d '\n' < "$inventory_dir/root-key-uri.txt"
      fi
    }

    stable_yubikey_private_key_uri_from_inventory() {
      local inventory_dir="$1"
      local inventory_uri=""
      local object_id=""

      inventory_uri="$(inventory_root_key_uri "$inventory_dir")"
      object_id="$(printf '%s\n' "$inventory_uri" | sed -n 's/.*[;:]id=\([^;]*\).*/\1/p' | head -n1)"

      if [ -n "$object_id" ]; then
        printf 'pkcs11:token=YubiKey%%20PIV;id=%s;type=private' "$object_id"
        return 0
      fi

      printf '%s' "$inventory_uri"
    }

    choose_usb_disk() {
      local intro="$1"
      shift
      local -a excluded_disk_identities=("$@")
      local choice=""
      local selected_line=""
      local disk_path=""
      local size=""
      local description=""
      local -a disk_lines=()
      local -a menu_items=()

      while true; do
        mapfile -t disk_lines < <(list_usb_disks "''${excluded_disk_identities[@]}")

        if ui_is_dialog && [ "''${#disk_lines[@]}" -eq 0 ]; then
          while [ "''${#disk_lines[@]}" -eq 0 ]; do
            dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Waiting For Removable Media" --infobox "$intro\n\nNo removable disks detected yet.\n\nInsert the drive now.\n\nPress q to cancel." 15 90
            if choice="$(read_key_with_timeout "$poll_seconds")"; then
              case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
                q)
                  return 1
                  ;;
              esac
            fi
            mapfile -t disk_lines < <(list_usb_disks "''${excluded_disk_identities[@]}")
          done
        fi

        if [ "''${#disk_lines[@]}" -eq 0 ]; then
          print_header
          printf '%s\n' "$intro"
          printf '%s\n' "No removable disks were detected."
          printf '%s' "Press Enter to refresh or q to cancel: " >&2
          IFS= read -r choice
          case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
            q) return 1 ;;
          esac
          continue
        fi

        if [ "''${#disk_lines[@]}" -eq 1 ]; then
          printf '%s' "''${disk_lines[0]}"
          return 0
        fi

        if ui_is_dialog; then
          menu_items=()
          local index="1"
          for selected_line in "''${disk_lines[@]}"; do
            IFS=$'\t' read -r disk_path _ size description <<< "$selected_line"
            menu_items+=("$index" "$disk_path | $size | $description")
            index=$((index + 1))
          done
          choice="$(dialog_run --title "Choose Removable Disk" --menu "$intro" 20 110 "$(dialog_menu_height)" "''${menu_items[@]}")" || return 1
          selected_line="''${disk_lines[$((choice - 1))]}"
          printf '%s' "$selected_line"
          return 0
        fi

        print_header
        printf '%s\n' "$intro"
        printf '%s\n' "Detected removable disks:"
        local index="1"
        for selected_line in "''${disk_lines[@]}"; do
          IFS=$'\t' read -r disk_path _ size description <<< "$selected_line"
          printf '%s\n' "  $index. $disk_path"
          printf '%s\n' "     size: $size"
          printf '%s\n' "     details: $description"
          index=$((index + 1))
        done
        printf '%s' "Select a disk number, or q to cancel: " >&2
        IFS= read -r choice
        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
          q) return 1 ;;
          *[!0-9]*|"")
            printf '%s\n' "Please choose a number or q." >&2
            continue
            ;;
        esac
        if [ "$choice" -lt 1 ] || [ "$choice" -gt "''${#disk_lines[@]}" ]; then
          printf '%s\n' "That selection is out of range." >&2
          continue
        fi
        selected_line="''${disk_lines[$((choice - 1))]}"
        printf '%s' "$selected_line"
        return 0
      done
    }

    root_intermediate_signer_flow() {
      local request_disk_line=""
      local request_disk_path=""
      local request_usb_mount=""
      local request_usb_bundle=""
      local workflow_dir="$temp_root/root-intermediate-signer"
      local request_mount_path="$workflow_dir/request-usb"
      local request_stage_dir="$workflow_dir/request-bundle"
      local signed_stage_dir="$workflow_dir/signed-bundle"
      local export_mount_path="$workflow_dir/export-usb"
      local verify_work_dir="$workflow_dir/verify-root-yubikey"
      local request_role=""
      local request_review=""
      local issuer_cert=""
      local signer_state_dir=""
      local policy_file=""
      local pin_file=""
      local approved_by=""
      local root_inventory_root=""
      local root_inventory_dir=""
      local root_yubikey_serial=""
      local pkcs11_module=""
      local issuer_key_uri=""
      local sign_confirmation=""
      local signed_bundle_name=""
      local export_disk_line=""
      local export_disk_path=""
      local export_disk_size=""
      local export_disk_description=""
      local export_partition_path=""
      local export_destination_dir=""

      if ui_is_dialog; then
        dialog_info "Root Intermediate Signer" "This ceremony will:\n\n1. Copy one intermediate request bundle from removable media onto the signer.\n2. Require operator review of the CSR details.\n3. Verify the inserted root CA YubiKey against committed root inventory.\n4. Sign the CSR.\n5. Format a fresh removable drive for the signed output bundle.\n\nBefore continuing, confirm the committed root inventory and matching root policy tree are present on this workstation and the root PIN file is available locally."
      else
        print_header
        printf '%s\n' "This ceremony will:"
        printf '%s\n' "  1. Copy one intermediate request bundle from removable media onto the signer."
        printf '%s\n' "  2. Require operator review of the CSR details."
        printf '%s\n' "  3. Verify the inserted root CA YubiKey against committed root inventory."
        printf '%s\n' "  4. Sign the CSR."
        printf '%s\n' "  5. Format a fresh removable drive for the signed output bundle."
        printf '%s\n' ""
        printf '%s\n' "Confirm the committed root inventory and matching root policy tree are present on this workstation and the root PIN file is available locally."
      fi

      if ! prompt_yes_no "Proceed with the root intermediate signing ceremony?" "y"; then
        return 0
      fi

      rm -rf "$workflow_dir"
      mkdir -p "$workflow_dir"

      request_disk_line="$(choose_usb_disk "Insert the USB thumb drive that holds the intermediate CSR request bundle.")" || return 0
      IFS=$'\t' read -r request_disk_path _ _ _ <<< "$request_disk_line"
      request_usb_mount="$(mount_existing_disk_read_only "$request_disk_path" "$request_mount_path")" || return 1
      request_usb_bundle="$(choose_request_bundle_from_mount "$request_usb_mount")" || return 0

      rm -rf "$request_stage_dir"
      copy_bundle_dir "$request_usb_bundle" "$request_stage_dir"

      if findmnt -n --target "$request_usb_mount" >/dev/null 2>&1; then
        run_privileged umount "$request_usb_mount" >/dev/null 2>&1 || true
      fi

      if ui_is_dialog; then
        dialog_info "Request Bundle Downloaded" "The request bundle has been copied locally to:\n$request_stage_dir\n\nRemove the request USB drive now, then continue to review the CSR."
      else
        print_header
        printf '%s\n' "Request bundle copied locally to $request_stage_dir"
        printf '%s\n' "Remove the request USB drive now."
        pause
      fi

      request_role="$(request_bundle_role "$request_stage_dir")"
      if [ "$request_role" != "intermediate-signing-authority" ]; then
        show_error "Unsupported Request Bundle" "This dedicated signer workflow only accepts intermediate signing authority request bundles.\n\nDetected role:\n$request_role"
        return 1
      fi

      request_review="$(request_bundle_review_text "$request_stage_dir")"
      if ui_is_dialog; then
        dialog_info "CSR Review" "$request_review"
      else
        divider
        printf '%s\n' "Review the copied CSR details"
        printf '%s\n' "$request_review"
        divider
      fi
      if ! prompt_yes_no "Does this request match the approved intermediate CA issuance?" "n"; then
        return 0
      fi

      issuer_cert="$(default_or_prompt_existing_file "Root certificate path" "''${ROOT_CERT_FILE:-$(issuer_default_cert_path root)}")" || return 0
      signer_state_dir="$(default_or_prompt_existing_dir "Root signer state directory" "''${ROOT_SIGNER_STATE_DIR:-$(issuer_default_signer_state_dir root)}")" || return 0
      pin_file="$(default_or_prompt_existing_file "Root YubiKey PIN file" "''${PIN_FILE:-}")" || return 0
      root_inventory_root="''${ROOT_INVENTORY_ROOT:-/var/lib/pd-pki/inventory/root-ca}"
      root_inventory_dir="$(choose_root_inventory_dir "$root_inventory_root")" || return 0
      root_inventory_dir="$(cd "$root_inventory_dir" && pwd -P)"
      show_root_inventory_summary "$root_inventory_dir"
      policy_file="$(resolve_root_signer_policy_file "$root_inventory_dir" "''${ROOT_POLICY_FILE:-}" || true)"
      if [ -z "$policy_file" ]; then
        show_error "Missing Signer Policy" "No root signer policy file was found for the selected inventory entry.

Expected committed policy at one of:
''${ROOT_POLICY_ROOT:-/var/lib/pd-pki/policy/root-ca}/$(root_inventory_bundle_root_id "$root_inventory_dir")/root-signer-policy.json
''${ROOT_POLICY_ROOT:-/var/lib/pd-pki/policy/root-ca}/$(root_inventory_bundle_root_id "$root_inventory_dir")/root-policy.json

Optional fallback path:
''${ROOT_POLICY_FILE:-<not configured>}"
        return 1
      fi

      wait_for_yubikey_insertion || return 0
      root_yubikey_serial="$(choose_yubikey_serial)" || return 0
      pkcs11_module="$(issuer_default_pkcs11_module root)"
      issuer_key_uri="$(stable_yubikey_private_key_uri_from_inventory "$root_inventory_dir")"
      if [ -z "$issuer_key_uri" ]; then
        issuer_key_uri="$(choose_pkcs11_key_uri "$pkcs11_module")" || return 0
      fi

      rm -rf "$verify_work_dir"
      mkdir -p "$verify_work_dir"
      if ui_is_dialog; then
        dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Verifying Root CA YubiKey" --infobox "Verifying the inserted root CA YubiKey against:\n$root_inventory_dir\n\nYubiKey serial: $root_yubikey_serial" 14 90
      else
        print_header
        printf '%s\n' "Verifying the inserted root CA YubiKey against $root_inventory_dir"
        printf '%s\n' "YubiKey serial: $root_yubikey_serial"
      fi
      pd-pki-signing-tools verify-root-yubikey-identity \
        --inventory-dir "$root_inventory_dir" \
        --yubikey-serial "$root_yubikey_serial" \
        --pin-file "$pin_file" \
        --work-dir "$verify_work_dir"
      show_root_yubikey_identity_summary "$verify_work_dir/root-yubikey-identity-summary.json"

      approved_by="$(prompt_text "Approved by" "$(default_operator_id)")" || return 0
      if [ -z "$approved_by" ]; then
        show_error "Missing Approval Attribution" "An operator identifier is required to record this issuance."
        return 1
      fi

      sign_confirmation="Proceed with signing this intermediate CSR using the verified root CA YubiKey?\n\nRequest: $(request_bundle_common_name "$request_stage_dir")\nInventory: $(root_inventory_bundle_root_id "$root_inventory_dir")\nSigner policy: $policy_file\nApproved by: $approved_by"
      if ! prompt_yes_no "$sign_confirmation" "y"; then
        return 0
      fi

      rm -rf "$signed_stage_dir"
      mkdir -p "$signed_stage_dir"
      if ui_is_dialog; then
        dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Signing Intermediate CSR" --infobox "Signing the reviewed intermediate request bundle with the verified root CA YubiKey." 12 80
      fi
      pd-pki-signing-tools sign-request \
        --request-dir "$request_stage_dir" \
        --out-dir "$signed_stage_dir" \
        --issuer-key-uri "$issuer_key_uri" \
        --pkcs11-module "$pkcs11_module" \
        --pkcs11-pin-file "$pin_file" \
        --issuer-cert "$issuer_cert" \
        --signer-state-dir "$signer_state_dir" \
        --policy-file "$policy_file" \
        --approved-by "$approved_by"

      show_signed_bundle_summary "$signed_stage_dir"
      wait_for_yubikey_removal || return 0

      export_disk_line="$(choose_usb_disk "Insert a fresh USB thumb drive for the signed output bundle. This drive will be reformatted before the signed artifacts are written.")" || return 0
      IFS=$'\t' read -r export_disk_path _ export_disk_size export_disk_description <<< "$export_disk_line"

      if ! prompt_yes_no "The selected removable disk will be reformatted before the signed bundle is written.\n\nDisk: $export_disk_path\nSize: $export_disk_size\nDetails: $export_disk_description\n\nContinue only if this is the correct fresh output drive." "n"; then
        return 0
      fi

      rm -rf "$export_mount_path"
      mkdir -p "$export_mount_path"
      export_partition_path="$(format_and_mount_export_disk "$export_disk_path" "$export_mount_path" "PDPKISIGNED")" || return 1

      signed_bundle_name="intermediate-signed-$(current_timestamp_utc)"
      export_destination_dir="$export_mount_path/pd-pki-transfer/signed/$signed_bundle_name"
      if ! copy_bundle_dir "$signed_stage_dir" "$export_destination_dir"; then
        run_privileged umount "$export_mount_path" >/dev/null 2>&1 || true
        show_error "Signed Bundle Export Failed" "The signed bundle could not be copied to the formatted USB drive."
        return 1
      fi

      sync "$export_destination_dir" >/dev/null 2>&1 || sync >/dev/null 2>&1 || true
      if ! run_privileged umount "$export_mount_path"; then
        show_error "Signed Bundle Export Incomplete" "The signed bundle was copied to the formatted USB drive, but the mounted filesystem could not be unmounted safely.\n\nMount path:\n$export_mount_path"
        return 1
      fi

      if ui_is_dialog; then
        dialog_info "Signed Bundle Ready" "The fresh USB drive was reformatted and the signed intermediate bundle was written successfully.\n\nDisk: $export_disk_path\nPartition: $export_partition_path\nBundle path: pd-pki-transfer/signed/$signed_bundle_name\n\nThe filesystem has been unmounted. Remove and transport the drive now."
      else
        print_header
        printf '%s\n' "The fresh USB drive was reformatted and the signed intermediate bundle was written successfully."
        printf '%s\n' "Disk: $export_disk_path"
        printf '%s\n' "Partition: $export_partition_path"
        printf '%s\n' "Bundle path: pd-pki-transfer/signed/$signed_bundle_name"
        printf '%s\n' "The filesystem has been unmounted. Remove and transport the drive now."
        pause
      fi
    }

    export_root_inventory_flow() {
      local source_dir=""
      local usb_mount=""
      local stage_dir="$temp_root/export-root-inventory"
      local root_id=""
      local destination_dir=""

      source_dir="$(prompt_existing_dir "Root inventory archive directory" "/var/lib/pd-pki/yubikey-inventory" "required")"
      usb_mount="$(choose_usb_mount "write" "Choose the removable volume that should receive the root inventory bundle.")" || return 0

      rm -rf "$stage_dir"
      mkdir -p "$stage_dir"

      if ui_is_dialog; then
        dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Exporting Root Inventory Bundle" --infobox "Exporting root inventory bundle from:\n$source_dir" 12 80
      else
        print_header
        printf '%s\n' "Exporting root inventory bundle from $source_dir"
      fi
      pd-pki-signing-tools export-root-inventory --source-dir "$source_dir" --out-dir "$stage_dir"

      root_id="$(root_inventory_bundle_root_id "$stage_dir")"
      if [ -z "$root_id" ]; then
        root_id="root-inventory"
      fi
      destination_dir="$(unique_destination_path "$usb_mount/pd-pki-transfer/root-inventory/root-$root_id-$(current_timestamp_utc)")"
      copy_bundle_dir "$stage_dir" "$destination_dir"

      if ui_is_dialog; then
        dialog_info "Root Inventory Bundle Exported" "Saved to:\n$destination_dir"
      else
        print_header
        printf '%s\n' "Root inventory bundle exported."
        printf '%s\n' "Saved to: $destination_dir"
      fi
      show_root_inventory_summary "$destination_dir"
      pause
    }

    export_request_flow() {
      local role=""
      local state_dir=""
      local usb_mount=""
      local stage_dir="$temp_root/export-request"
      local bundle_name=""
      local common_name=""
      local destination_dir=""

      role="$(choose_role)" || return 0
      state_dir="$(prompt_existing_dir "State directory" "$(role_default_state_dir "$role")" "required")"
      usb_mount="$(choose_usb_mount "write" "Choose the removable volume that should receive the request bundle.")" || return 0

      rm -rf "$stage_dir"
      mkdir -p "$stage_dir"

      if ui_is_dialog; then
        dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Exporting Request Bundle" --infobox "Exporting $(role_title_for_id "$role") request bundle from:\n$state_dir" 12 80
      else
        print_header
        printf '%s\n' "Exporting $(role_title_for_id "$role") request bundle from $state_dir"
      fi
      pd-pki-signing-tools export-request --role "$role" --state-dir "$state_dir" --out-dir "$stage_dir"

      common_name="$(request_bundle_common_name "$stage_dir")"
      bundle_name="$(sanitize_label "$role-$common_name-$(current_timestamp_utc)")"
      destination_dir="$(unique_destination_path "$usb_mount/pd-pki-transfer/requests/$bundle_name")"
      copy_bundle_dir "$stage_dir" "$destination_dir"

      if ui_is_dialog; then
        dialog_info "Request Bundle Exported" "Saved to:\n$destination_dir"
      else
        print_header
        printf '%s\n' "Request bundle exported."
        printf '%s\n' "Saved to: $destination_dir"
      fi
      show_request_bundle_summary "$destination_dir"
      pause
    }

    sign_request_flow() {
      local usb_mount=""
      local request_dir=""
      local request_role=""
      local issuer_profile=""
      local signer_backend=""
      local issuer_key=""
      local issuer_key_uri=""
      local pkcs11_module=""
      local pkcs11_pin=""
      local pkcs11_pin_file=""
      local issuer_cert=""
      local issuer_chain=""
      local signer_state_dir=""
      local policy_file=""
      local approved_by=""
      local approval_ticket=""
      local approval_note=""
      local days=""
      local stage_dir="$temp_root/sign-request"
      local verify_work_dir="$temp_root/verify-root-yubikey"
      local destination_dir=""
      local bundle_name=""
      local root_identity_verification_required=0
      local policy_file_default=""
      local root_inventory_root=""
      local root_inventory_dir=""
      local root_yubikey_serial=""
      local sign_confirmation=""
      local -a sign_cmd=()

      usb_mount="$(choose_usb_mount "write" "Choose the removable volume that holds the request bundle and should receive the signed result.")" || return 0
      request_dir="$(choose_request_bundle_from_mount "$usb_mount")" || return 0
      request_role="$(request_bundle_role "$request_dir")"
      show_request_bundle_summary "$request_dir"

      issuer_profile="$(choose_issuer_profile)" || return 0
      signer_backend="$(choose_signer_backend)" || return 0
      if [ "$signer_backend" = "pkcs11" ]; then
        maybe_wait_for_yubikey || return 0
        pkcs11_module="$(prompt_existing_file "PKCS#11 module path" "$(issuer_default_pkcs11_module "$issuer_profile")" "required")"
        issuer_key_uri="$(choose_pkcs11_key_uri "$pkcs11_module")" || return 0
      else
        issuer_key="$(prompt_existing_file "Issuer key path" "$(issuer_default_key_path "$issuer_profile")" "required")"
      fi
      if [ "$request_role" = "intermediate-signing-authority" ] && [ "$issuer_profile" = "root" ]; then
        policy_file_default="''${ROOT_POLICY_FILE:-}"
      fi
      issuer_cert="$(prompt_existing_file "Issuer certificate path" "$(issuer_default_cert_path "$issuer_profile")" "required")"
      issuer_chain="$(prompt_existing_file "Issuer chain path (optional for roots)" "$(issuer_default_chain_path "$issuer_profile")" "optional")"
      signer_state_dir="$(prompt_existing_dir "Signer state directory" "$(issuer_default_signer_state_dir "$issuer_profile")" "required")"
      approved_by="$(prompt_text "Approved by" "$(default_operator_id)")"
      approval_ticket="$(prompt_text "Approval ticket (optional)" "")"
      approval_note="$(prompt_text "Approval note (optional)" "")"
      days="$(prompt_text "Override validity days (optional)" "")"
      if [ "$signer_backend" = "pkcs11" ]; then
        while true; do
          pkcs11_pin="$(prompt_secret "Token PIN")" || return 0
          if [ -n "$pkcs11_pin" ]; then
            break
          fi
          if ui_is_dialog; then
            dialog_info "Missing PIN" "The token PIN cannot be empty."
          else
            printf '%s\n' "The token PIN cannot be empty." >&2
          fi
        done
      fi

      if [ "$request_role" = "intermediate-signing-authority" ] && [ "$issuer_profile" = "root" ] && [ "$signer_backend" = "pkcs11" ]; then
        root_identity_verification_required=1
        root_inventory_root="''${ROOT_INVENTORY_ROOT:-/var/lib/pd-pki/inventory/root-ca}"
        root_inventory_dir="$(choose_root_inventory_dir "$root_inventory_root")" || return 0
        root_inventory_dir="$(cd "$root_inventory_dir" && pwd -P)"
        show_root_inventory_summary "$root_inventory_dir"
        policy_file_default="$(resolve_root_signer_policy_file "$root_inventory_dir" "$policy_file_default" || true)"
        root_yubikey_serial="$(choose_yubikey_serial)" || return 0
        sign_confirmation="Proceed to verify the inserted root CA YubiKey against committed root inventory and sign this intermediate request bundle with $(issuer_profile_title "$issuer_profile") using $(signer_backend_title "$signer_backend")?"
      else
        sign_confirmation="Proceed to sign this bundle with $(issuer_profile_title "$issuer_profile") using $(signer_backend_title "$signer_backend")?"
      fi

      policy_file="$(prompt_existing_file "Signer policy file" "$policy_file_default" "required")"

      if ! prompt_yes_no "$sign_confirmation" "y"; then
        return 0
      fi

      rm -rf "$stage_dir"
      mkdir -p "$stage_dir"
      if [ "$signer_backend" = "pkcs11" ]; then
        pkcs11_pin_file="$temp_root/pkcs11-pin-sign-$(current_timestamp_utc).txt"
        write_secret_file "$pkcs11_pin_file" "$pkcs11_pin"
        unset pkcs11_pin
      fi

      if [ "$root_identity_verification_required" = "1" ]; then
        rm -rf "$verify_work_dir"
        mkdir -p "$verify_work_dir"
        if ui_is_dialog; then
          dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Verifying Root CA YubiKey" --infobox "Verifying the inserted root CA YubiKey against:\n$root_inventory_dir\n\nYubiKey serial: $root_yubikey_serial" 14 90
        else
          print_header
          printf '%s\n' "Verifying the inserted root CA YubiKey against $root_inventory_dir"
          printf '%s\n' "YubiKey serial: $root_yubikey_serial"
        fi
        pd-pki-signing-tools verify-root-yubikey-identity \
          --inventory-dir "$root_inventory_dir" \
          --yubikey-serial "$root_yubikey_serial" \
          --pin-file "$pkcs11_pin_file" \
          --work-dir "$verify_work_dir"
        show_root_yubikey_identity_summary "$verify_work_dir/root-yubikey-identity-summary.json"
      fi

      sign_cmd=(
        pd-pki-signing-tools
        sign-request
        --request-dir "$request_dir"
        --out-dir "$stage_dir"
        --issuer-cert "$issuer_cert"
        --signer-state-dir "$signer_state_dir"
        --policy-file "$policy_file"
        --approved-by "$approved_by"
      )
      if [ "$signer_backend" = "pkcs11" ]; then
        sign_cmd+=(--issuer-key-uri "$issuer_key_uri" --pkcs11-module "$pkcs11_module" --pkcs11-pin-file "$pkcs11_pin_file")
      else
        sign_cmd+=(--issuer-key "$issuer_key")
      fi
      if [ -n "$issuer_chain" ]; then
        sign_cmd+=(--issuer-chain "$issuer_chain")
      fi
      if [ -n "$approval_ticket" ]; then
        sign_cmd+=(--approval-ticket "$approval_ticket")
      fi
      if [ -n "$approval_note" ]; then
        sign_cmd+=(--approval-note "$approval_note")
      fi
      if [ -n "$days" ]; then
        sign_cmd+=(--days "$days")
      fi

      if ui_is_dialog; then
        dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Signing Request Bundle" --infobox "Signing bundle from:\n$request_dir\n\nIssuer profile: $(issuer_profile_title "$issuer_profile")\nSigner backend: $(signer_backend_title "$signer_backend")" 15 80
      fi
      "''${sign_cmd[@]}"

      bundle_name="$(sanitize_label "$(request_bundle_role "$request_dir")-signed-$(request_bundle_common_name "$request_dir")-$(current_timestamp_utc)")"
      destination_dir="$(unique_destination_path "$usb_mount/pd-pki-transfer/signed/$bundle_name")"
      copy_bundle_dir "$stage_dir" "$destination_dir"

      if ui_is_dialog; then
        dialog_info "Signed Bundle Written" "Saved to:\n$destination_dir"
      else
        print_header
        printf '%s\n' "Signed bundle written to removable media."
        printf '%s\n' "Saved to: $destination_dir"
      fi
      show_signed_bundle_summary "$destination_dir"
      pause
    }

    import_signed_flow() {
      local usb_mount=""
      local signed_dir=""
      local role=""
      local state_dir=""

      usb_mount="$(choose_usb_mount "read" "Choose the removable volume that holds the signed bundle.")" || return 0
      signed_dir="$(choose_signed_bundle_from_mount "$usb_mount")" || return 0
      show_signed_bundle_summary "$signed_dir"

      role="$(request_bundle_role "$signed_dir")"
      state_dir="$(prompt_existing_dir "State directory" "$(role_default_state_dir "$role")" "required")"

      if ! prompt_yes_no "Import this signed bundle into $state_dir?" "y"; then
        return 0
      fi

      if ui_is_dialog; then
        dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Importing Signed Bundle" --infobox "Importing signed bundle into:\n$state_dir" 12 80
      fi
      pd-pki-signing-tools import-signed --role "$role" --state-dir "$state_dir" --signed-dir "$signed_dir"

      if ui_is_dialog; then
        dialog_info "Import Complete" "Signed bundle imported into runtime state.\n\nRole: $(role_title_for_id "$role")\nState directory: $state_dir"
      else
        print_header
        printf '%s\n' "Signed bundle imported into runtime state."
        printf '%s\n' "Role: $(role_title_for_id "$role")"
        printf '%s\n' "State directory: $state_dir"
      fi
      pause
    }

    generate_crl_flow() {
      local issuer_profile=""
      local signer_state_dir=""
      local signer_backend=""
      local issuer_key=""
      local issuer_key_uri=""
      local pkcs11_module=""
      local pkcs11_pin=""
      local pkcs11_pin_file=""
      local issuer_cert=""
      local days=""
      local usb_mount=""
      local stage_dir="$temp_root/generate-crl"
      local destination_dir=""
      local bundle_name=""

      issuer_profile="$(choose_issuer_profile)" || return 0
      signer_backend="$(choose_signer_backend)" || return 0
      signer_state_dir="$(prompt_existing_dir "Signer state directory" "$(issuer_default_signer_state_dir "$issuer_profile")" "required")"
      if [ "$signer_backend" = "pkcs11" ]; then
        maybe_wait_for_yubikey || return 0
        pkcs11_module="$(prompt_existing_file "PKCS#11 module path" "$(issuer_default_pkcs11_module "$issuer_profile")" "required")"
        issuer_key_uri="$(choose_pkcs11_key_uri "$pkcs11_module")" || return 0
      else
        issuer_key="$(prompt_existing_file "Issuer key path" "$(issuer_default_key_path "$issuer_profile")" "required")"
      fi
      issuer_cert="$(prompt_existing_file "Issuer certificate path" "$(issuer_default_cert_path "$issuer_profile")" "required")"
      days="$(prompt_text "CRL validity days" "30")"
      usb_mount="$(choose_usb_mount "write" "Choose the removable volume that should receive the CRL bundle.")" || return 0
      if [ "$signer_backend" = "pkcs11" ]; then
        while true; do
          pkcs11_pin="$(prompt_secret "Token PIN")" || return 0
          if [ -n "$pkcs11_pin" ]; then
            break
          fi
          if ui_is_dialog; then
            dialog_info "Missing PIN" "The token PIN cannot be empty."
          else
            printf '%s\n' "The token PIN cannot be empty." >&2
          fi
        done
      fi

      if ! prompt_yes_no "Generate a CRL with $(issuer_profile_title "$issuer_profile") using $(signer_backend_title "$signer_backend") and copy it to removable media?" "y"; then
        return 0
      fi

      rm -rf "$stage_dir"
      mkdir -p "$stage_dir"
      if [ "$signer_backend" = "pkcs11" ]; then
        pkcs11_pin_file="$temp_root/pkcs11-pin-crl-$(current_timestamp_utc).txt"
        write_secret_file "$pkcs11_pin_file" "$pkcs11_pin"
        unset pkcs11_pin
      fi

      if ui_is_dialog; then
        dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Generating CRL" --infobox "Generating CRL from signer state:\n$signer_state_dir\n\nSigner backend: $(signer_backend_title "$signer_backend")" 14 80
      fi
      if [ "$signer_backend" = "pkcs11" ]; then
        pd-pki-signing-tools generate-crl \
          --signer-state-dir "$signer_state_dir" \
          --issuer-key-uri "$issuer_key_uri" \
          --pkcs11-module "$pkcs11_module" \
          --pkcs11-pin-file "$pkcs11_pin_file" \
          --issuer-cert "$issuer_cert" \
          --out-dir "$stage_dir" \
          --days "$days"
      else
        pd-pki-signing-tools generate-crl \
          --signer-state-dir "$signer_state_dir" \
          --issuer-key "$issuer_key" \
          --issuer-cert "$issuer_cert" \
          --out-dir "$stage_dir" \
          --days "$days"
      fi

      bundle_name="$(sanitize_label "crl-$issuer_profile-$(current_timestamp_utc)")"
      destination_dir="$(unique_destination_path "$usb_mount/pd-pki-transfer/crls/$bundle_name")"
      copy_bundle_dir "$stage_dir" "$destination_dir"

      if ui_is_dialog; then
        dialog_info "CRL Bundle Written" "Saved to:\n$destination_dir"
      else
        print_header
        printf '%s\n' "CRL bundle written to removable media."
        printf '%s\n' "Saved to: $destination_dir"
      fi
      pause
    }

    main_menu() {
      local choice=""

      if ui_is_dialog; then
        while true; do
          choice="$(dialog_run --title "Main Menu" --menu "Choose an action.\n\nYubiKey status: $(yubikey_status_line)" 20 100 12 1 "Export root inventory bundle to removable media" 2 "Export request bundle to removable media" 3 "Sign request bundle from removable media" 4 "Import signed bundle from removable media" 5 "Generate CRL bundle to removable media" 6 "Quit")" || exit 0
          case "$choice" in
            1) export_root_inventory_flow ;;
            2) export_request_flow ;;
            3) sign_request_flow ;;
            4) import_signed_flow ;;
            5) generate_crl_flow ;;
            6) exit 0 ;;
          esac
        done
      fi

      while true; do
        print_header
        printf '%s\n' "Choose an action."
        printf '%s\n' "  1. Export root inventory bundle to removable media"
        printf '%s\n' "  2. Export request bundle to removable media"
        printf '%s\n' "  3. Sign request bundle from removable media"
        printf '%s\n' "  4. Import signed bundle from removable media"
        printf '%s\n' "  5. Generate CRL bundle to removable media"
        printf '%s\n' "  6. Quit"
        printf '%s' "Selection: " >&2
        IFS= read -r choice

        case "$choice" in
          1) export_root_inventory_flow ;;
          2) export_request_flow ;;
          3) sign_request_flow ;;
          4) import_signed_flow ;;
          5) generate_crl_flow ;;
          6|q|Q) exit 0 ;;
          *) printf '%s\n' "Please choose 1, 2, 3, 4, 5, or 6." >&2 ;;
        esac
      done
    }

    case "$workflow_mode" in
      main-menu)
        main_menu
        ;;
      root-intermediate-signer)
        root_intermediate_signer_flow
        ;;
    esac
  '';
}
