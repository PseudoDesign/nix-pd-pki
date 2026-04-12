{ pkgs }:
pkgs.writeShellApplication {
  name = "pd-pki-operator";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.dialog
    pkgs.findutils
    pkgs.gnugrep
    pkgs.jq
    pkgs.util-linux
    pkgs.yubikey-manager
  ];
  text = ''
    set -euo pipefail

    poll_seconds="2"
    temp_root=""

    cleanup() {
      if [ -n "$temp_root" ] && [ -d "$temp_root" ]; then
        rm -rf "$temp_root"
      fi
    }

    trap cleanup EXIT INT TERM

    usage() {
      cat <<'EOF'
    Usage: pd-pki-operator [--poll-seconds SECONDS] [--help]

    Interactive operator TUI for exporting request bundles to removable media,
    signing request bundles from removable media, importing signed bundles back
    into runtime state, and exporting CRLs.

    YubiKey detection in this build is informational only. Signing still uses the
    issuer key paths passed through to pd-pki-signing-tools.

    In an interactive terminal the app uses a full-screen dialog interface.
    Set PD_PKI_OPERATOR_PLAIN=1 to force the line-oriented fallback.
    EOF
    }

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --poll-seconds)
          poll_seconds="$2"
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
        printf '%s\n' "operator"
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

    dialog_run() {
      dialog --clear --stdout --backtitle "Pseudo Design PKI Operator" "$@"
    }

    dialog_info() {
      local title="$1"
      local text="$2"
      dialog_run --title "$title" --msgbox "$text" 18 80
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
      printf '%s\n' "USB-guided request export, signing, import, and CRL handoff"
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

    signed_bundle_serial() {
      jq -r '.serial // empty' "$1/metadata.json" 2>/dev/null || true
    }

    signed_bundle_not_after() {
      jq -r '.notAfter // empty' "$1/metadata.json" 2>/dev/null || true
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
        printf '%s\n' "not detected (advisory only in this build)"
      fi
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

    maybe_wait_for_yubikey() {
      local answer=""
      local serials=""

      while true; do
        serials="$(detect_yubikey_serials)"
        if [ -n "$serials" ]; then
          if ui_is_dialog; then
            dialog_info "YubiKey Detected" "Detected YubiKey serial(s):\n$serials\n\nDetection is informational only in this build. Signing still uses file-based issuer keys."
          else
            divider
            printf '%s\n' "Detected YubiKey serial(s):"
            printf '  %s\n' "$serials"
            printf '%s\n' "Detection is informational only in this build; signing still uses file-based issuer keys."
          fi
          return 0
        fi

        if ui_is_dialog; then
          dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Waiting For YubiKey" --infobox "No YubiKey detected yet.\n\nPlug in the token now.\n\nThis build still signs with file-based issuer keys.\n\nPress c to continue without a YubiKey.\nPress q to cancel." 14 80
          if answer="$(read_key_with_timeout "$poll_seconds")"; then
            :
          else
            continue
          fi
        else
          divider
          printf '%s\n' "No YubiKey detected."
          printf '%s\n' "Detection is informational only in this build; signing still uses file-based issuer keys."
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
      local issuer_profile=""
      local issuer_key=""
      local issuer_cert=""
      local issuer_chain=""
      local signer_state_dir=""
      local policy_file=""
      local approved_by=""
      local approval_ticket=""
      local approval_note=""
      local days=""
      local stage_dir="$temp_root/sign-request"
      local destination_dir=""
      local bundle_name=""
      local -a sign_cmd=()

      maybe_wait_for_yubikey || return 0
      usb_mount="$(choose_usb_mount "write" "Choose the removable volume that holds the request bundle and should receive the signed result.")" || return 0
      request_dir="$(choose_request_bundle_from_mount "$usb_mount")" || return 0
      show_request_bundle_summary "$request_dir"

      issuer_profile="$(choose_issuer_profile)" || return 0
      issuer_key="$(prompt_existing_file "Issuer key path" "$(issuer_default_key_path "$issuer_profile")" "required")"
      issuer_cert="$(prompt_existing_file "Issuer certificate path" "$(issuer_default_cert_path "$issuer_profile")" "required")"
      issuer_chain="$(prompt_existing_file "Issuer chain path (optional for roots)" "$(issuer_default_chain_path "$issuer_profile")" "optional")"
      signer_state_dir="$(prompt_existing_dir "Signer state directory" "$(issuer_default_signer_state_dir "$issuer_profile")" "required")"
      policy_file="$(prompt_existing_file "Signer policy file" "" "required")"
      approved_by="$(prompt_text "Approved by" "$(default_operator_id)")"
      approval_ticket="$(prompt_text "Approval ticket (optional)" "")"
      approval_note="$(prompt_text "Approval note (optional)" "")"
      days="$(prompt_text "Override validity days (optional)" "")"

      if ! prompt_yes_no "Proceed to sign this bundle with $(issuer_profile_title "$issuer_profile")?" "y"; then
        return 0
      fi

      rm -rf "$stage_dir"
      mkdir -p "$stage_dir"

      sign_cmd=(
        pd-pki-signing-tools
        sign-request
        --request-dir "$request_dir"
        --out-dir "$stage_dir"
        --issuer-key "$issuer_key"
        --issuer-cert "$issuer_cert"
        --signer-state-dir "$signer_state_dir"
        --policy-file "$policy_file"
        --approved-by "$approved_by"
      )
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
        dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Signing Request Bundle" --infobox "Signing bundle from:\n$request_dir\n\nIssuer profile: $(issuer_profile_title "$issuer_profile")" 14 80
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
      local issuer_key=""
      local issuer_cert=""
      local days=""
      local usb_mount=""
      local stage_dir="$temp_root/generate-crl"
      local destination_dir=""
      local bundle_name=""

      maybe_wait_for_yubikey || return 0
      issuer_profile="$(choose_issuer_profile)" || return 0
      signer_state_dir="$(prompt_existing_dir "Signer state directory" "$(issuer_default_signer_state_dir "$issuer_profile")" "required")"
      issuer_key="$(prompt_existing_file "Issuer key path" "$(issuer_default_key_path "$issuer_profile")" "required")"
      issuer_cert="$(prompt_existing_file "Issuer certificate path" "$(issuer_default_cert_path "$issuer_profile")" "required")"
      days="$(prompt_text "CRL validity days" "30")"
      usb_mount="$(choose_usb_mount "write" "Choose the removable volume that should receive the CRL bundle.")" || return 0

      if ! prompt_yes_no "Generate a CRL with $(issuer_profile_title "$issuer_profile") and copy it to removable media?" "y"; then
        return 0
      fi

      rm -rf "$stage_dir"
      mkdir -p "$stage_dir"

      if ui_is_dialog; then
        dialog --clear --backtitle "Pseudo Design PKI Operator" --title "Generating CRL" --infobox "Generating CRL from signer state:\n$signer_state_dir" 12 80
      fi
      pd-pki-signing-tools generate-crl \
        --signer-state-dir "$signer_state_dir" \
        --issuer-key "$issuer_key" \
        --issuer-cert "$issuer_cert" \
        --out-dir "$stage_dir" \
        --days "$days"

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
          choice="$(dialog_run --title "Main Menu" --menu "Choose an action.\n\nYubiKey status: $(yubikey_status_line)" 18 90 10 1 "Export request bundle to removable media" 2 "Sign request bundle from removable media" 3 "Import signed bundle from removable media" 4 "Generate CRL bundle to removable media" 5 "Quit")" || exit 0
          case "$choice" in
            1) export_request_flow ;;
            2) sign_request_flow ;;
            3) import_signed_flow ;;
            4) generate_crl_flow ;;
            5) exit 0 ;;
          esac
        done
      fi

      while true; do
        print_header
        printf '%s\n' "Choose an action."
        printf '%s\n' "  1. Export request bundle to removable media"
        printf '%s\n' "  2. Sign request bundle from removable media"
        printf '%s\n' "  3. Import signed bundle from removable media"
        printf '%s\n' "  4. Generate CRL bundle to removable media"
        printf '%s\n' "  5. Quit"
        printf '%s' "Selection: " >&2
        IFS= read -r choice

        case "$choice" in
          1) export_request_flow ;;
          2) sign_request_flow ;;
          3) import_signed_flow ;;
          4) generate_crl_flow ;;
          5|q|Q) exit 0 ;;
          *) printf '%s\n' "Please choose 1, 2, 3, 4, or 5." >&2 ;;
        esac
      done
    }

    main_menu
  '';
}
