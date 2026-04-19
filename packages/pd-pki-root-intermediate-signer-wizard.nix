{ pkgs, pdPkiSigningTools }:
pkgs.writeShellApplication {
  name = "pd-pki-root-intermediate-signer-wizard";
  runtimeInputs = [
    pdPkiSigningTools
    pkgs.coreutils
    pkgs.dosfstools
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.jq
    pkgs.opensc
    pkgs.openssl
    pkgs.parted
    pkgs.procps
    pkgs.systemd
    pkgs.usbutils
    pkgs.util-linux
    pkgs.yubikey-manager
    pkgs.zenity
  ];
  text = ''
    set -euo pipefail

    readonly poll_seconds="2"
    readonly session_home="''${HOME:-/var/lib/pd-pki}"
    readonly sessions_root="$session_home/root-intermediate-signing"
    readonly pin_file_path="''${PIN_FILE:-$session_home/secrets/root-pin.txt}"
    readonly policy_root="''${ROOT_POLICY_ROOT:-$session_home/policy/root-ca}"
    readonly policy_file_fallback_path="''${ROOT_POLICY_FILE:-}"
    readonly inventory_root="''${ROOT_INVENTORY_ROOT:-$session_home/inventory/root-ca}"
    readonly root_cert_file="''${ROOT_CERT_FILE:-$session_home/authorities/root/root-ca.cert.pem}"
    readonly root_signer_state_dir="''${ROOT_SIGNER_STATE_DIR:-$session_home/signer-state/root}"
    readonly pkcs11_module_path="${pkgs.yubico-piv-tool}/lib/libykcs11.so"
    readonly sudo_bin="/run/wrappers/bin/sudo"

    trim_whitespace() {
      local value="$1"
      value="''${value#"''${value%%[![:space:]]*}"}"
      value="''${value%"''${value##*[![:space:]]}"}"
      printf '%s' "$value"
    }

    current_timestamp_utc() {
      date -u +"%Y%m%dT%H%M%SZ"
    }

    show_info() {
      zenity --info \
        --width=900 \
        --height=420 \
        --title="$1" \
        --text="$2"
    }

    show_error() {
      zenity --error \
        --width=900 \
        --height=420 \
        --title="$1" \
        --text="$2"
    }

    confirm_step() {
      zenity --question \
        --width=900 \
        --height=420 \
        --title="$1" \
        --ok-label="$2" \
        --cancel-label="$3" \
        --text="$4"
    }

    prompt_text() {
      local title="$1"
      local text="$2"
      local default_value="$3"

      zenity --entry \
        --width=720 \
        --height=220 \
        --title="$title" \
        --text="$text" \
        --entry-text="$default_value"
    }

    require_command() {
      command -v "$1" >/dev/null 2>&1 || {
        show_error "Missing Dependency" "Required command not found: $1"
        exit 1
      }
    }

    run_privileged() {
      "$sudo_bin" -n "$@"
    }

    read_sysfs_value() {
      local path="$1"
      if [ -f "$path" ]; then
        tr -d '\n' < "$path"
      fi
    }

    usb_device_is_kiosk_input_or_hub_only() {
      local device_path="$1"
      local interface_path=""
      local class=""
      local subclass=""
      local protocol=""
      local found_interface="0"

      for interface_path in "$device_path":*; do
        [ -d "$interface_path" ] || continue
        [ -f "$interface_path/bInterfaceClass" ] || continue
        found_interface="1"
        class="$(tr '[:upper:]' '[:lower:]' < "$interface_path/bInterfaceClass")"
        subclass="$(tr '[:upper:]' '[:lower:]' < "$interface_path/bInterfaceSubClass")"
        protocol="$(tr '[:upper:]' '[:lower:]' < "$interface_path/bInterfaceProtocol")"
        case "$class:$subclass:$protocol" in
          03:01:01|03:00:00|09:*:*)
            ;;
          *)
            return 1
            ;;
        esac
      done

      [ "$found_interface" = "1" ]
    }

    list_unexpected_usb_devices() {
      local allow_yubikeys="$1"
      local device_path=""
      local device_name=""
      local vendor_id=""
      local product_id=""
      local manufacturer=""
      local product=""
      local description=""
      local busnum=""
      local devnum=""

      for device_path in /sys/bus/usb/devices/*; do
        [ -f "$device_path/idVendor" ] || continue
        device_name="$(basename "$device_path")"
        case "$device_name" in
          usb*)
            continue
            ;;
        esac
        vendor_id="$(tr '[:upper:]' '[:lower:]' < "$device_path/idVendor")"
        product_id="$(tr '[:upper:]' '[:lower:]' < "$device_path/idProduct")"
        manufacturer="$(trim_whitespace "$(read_sysfs_value "$device_path/manufacturer")")"
        product="$(trim_whitespace "$(read_sysfs_value "$device_path/product")")"
        busnum="$(trim_whitespace "$(read_sysfs_value "$device_path/busnum")")"
        devnum="$(trim_whitespace "$(read_sysfs_value "$device_path/devnum")")"

        case "$(printf '%s %s' "$manufacturer" "$product" | tr '[:upper:]' '[:lower:]')" in
          *root\ hub*)
            continue
            ;;
        esac
        if [ "$manufacturer" = "Linux Foundation" ]; then
          continue
        fi
        if [ "$allow_yubikeys" = "1" ] && [ "$vendor_id" = "1050" ]; then
          continue
        fi
        if usb_device_is_kiosk_input_or_hub_only "$device_path"; then
          continue
        fi

        description="$(trim_whitespace "$manufacturer $product")"
        if [ -z "$description" ]; then
          description="$vendor_id:$product_id"
        fi

        printf '%s\t%s\t%s\t%s\n' "$busnum" "$devnum" "$vendor_id:$product_id" "$description"
      done
    }

    format_unexpected_usb_devices() {
      local allow_yubikeys="$1"
      local busnum=""
      local devnum=""
      local ids=""
      local description=""
      local output=""

      while IFS=$'\t' read -r busnum devnum ids description; do
        [ -n "$busnum" ] || continue
        output="$output
Bus $(printf '%03d' "$busnum") Device $(printf '%03d' "$devnum"): $description ($ids)"
      done < <(list_unexpected_usb_devices "$allow_yubikeys")

      if [ -n "$output" ]; then
        printf '%s' "''${output#"$'\n'"}"
      fi
    }

    detect_yubikey_serials() {
      ykman list --serials 2>/dev/null | grep -v '^[[:space:]]*$' || true
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

    wait_for_usb_clear() {
      (
        while true; do
          local remaining=""
          remaining="$(format_unexpected_usb_devices 0)"
          if [ -z "$remaining" ]; then
            printf '%s\n' "# USB ports are clear. Continuing..."
            printf '%s\n' "100"
            break
          fi

          printf '%s\n' "# Remove all YubiKeys, USB keys, and other USB devices before continuing.

The wizard will stay on this screen until only approved kiosk input devices remain attached.

Still detected:
$remaining"
          sleep "$poll_seconds"
        done
      ) | zenity --progress \
        --pulsate \
        --auto-close \
        --no-cancel \
        --width=960 \
        --height=500 \
        --title="Clear USB Ports" \
        --text="Checking USB state..."
    }

    wait_for_single_yubikey() {
      local serials=""
      local count="0"
      local unexpected=""

      (
        while true; do
          serials="$(detect_yubikey_serials)"
          count="$(printf '%s\n' "$serials" | grep -c . || true)"
          unexpected="$(format_unexpected_usb_devices 1)"

          if [ "$count" = "1" ] && [ -z "$unexpected" ]; then
            printf '%s\n' "# YubiKey serial $serials detected. Continuing..."
            printf '%s\n' "100"
            break
          fi

          if [ -n "$unexpected" ]; then
            printf '%s\n' "# Insert exactly one YubiKey and leave all other USB devices disconnected.

Unexpected USB devices are still attached:
$unexpected"
          elif [ "$count" -gt 1 ]; then
            printf '%s\n' "# More than one YubiKey is attached.

Leave only the token for this ceremony connected.

Detected serials:
$serials"
          else
            printf '%s\n' "# Insert the YubiKey for the root signing ceremony.

The wizard will continue automatically when exactly one token is detected."
          fi

          sleep "$poll_seconds"
        done
      ) | zenity --progress \
        --pulsate \
        --auto-close \
        --no-cancel \
        --width=960 \
        --height=500 \
        --title="Insert YubiKey" \
        --text="Waiting for a single YubiKey..."

      printf '%s' "$(detect_yubikey_serials | head -n 1)"
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

    request_bundle_path_len() {
      jq -r '(.pathLen // empty) | tostring' "$1/request.json" 2>/dev/null || true
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

    request_bundle_summary_text() {
      local bundle_dir="$1"
      local role=""
      local common_name=""
      local requested_days=""
      local path_len=""
      local csr_path=""
      local subject=""
      local algorithm=""
      local bits=""
      local constraints=""

      role="$(request_bundle_role "$bundle_dir")"
      common_name="$(request_bundle_common_name "$bundle_dir")"
      requested_days="$(request_bundle_days "$bundle_dir")"
      path_len="$(request_bundle_path_len "$bundle_dir")"
      csr_path="$(request_bundle_csr_path "$bundle_dir")"
      subject="$(csr_subject "$csr_path")"
      algorithm="$(csr_public_key_algorithm "$csr_path")"
      bits="$(csr_public_key_bits "$csr_path")"
      constraints="$(csr_basic_constraints "$csr_path")"

      printf '%s\n' "Bundle path: $bundle_dir"
      printf '%s\n' "Role: $role"
      if [ -n "$common_name" ]; then
        printf '%s\n' "Common name: $common_name"
      fi
      if [ -n "$requested_days" ]; then
        printf '%s\n' "Requested days: $requested_days"
      fi
      if [ -n "$path_len" ]; then
        printf '%s\n' "Requested pathLen: $path_len"
      fi
      if [ -n "$subject" ]; then
        printf '%s\n' "CSR subject: $subject"
      fi
      if [ -n "$algorithm" ] && [ -n "$bits" ]; then
        printf '%s\n' "CSR key: $algorithm ($bits bits)"
      elif [ -n "$algorithm" ]; then
        printf '%s\n' "CSR key: $algorithm"
      fi
      if [ -n "$constraints" ]; then
        printf '%s\n' "CSR basic constraints: $constraints"
      fi
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

    choose_request_bundle_from_mount() {
      local mount_path="$1"
      local line=""
      local choice=""
      local bundle_dir=""
      local role=""
      local common_name=""
      local basename=""
      local -a bundle_lines=()
      local -a rows=()

      while true; do
        mapfile -t bundle_lines < <(find_request_bundles "$mount_path")

        if [ "''${#bundle_lines[@]}" -eq 0 ]; then
          if zenity --question \
            --width=820 \
            --height=260 \
            --title="No Request Bundles Found" \
            --ok-label="Refresh" \
            --cancel-label="Cancel" \
            --text="No request bundles were found on:
$mount_path

Choose Refresh after inserting a different request drive or correcting the media contents."; then
            continue
          fi
          return 1
        fi

        if [ "''${#bundle_lines[@]}" -eq 1 ]; then
          IFS=$'\t' read -r bundle_dir role common_name basename <<EOF
''${bundle_lines[0]}
EOF
          printf '%s' "$bundle_dir"
          return 0
        fi

        rows=()
        for line in "''${bundle_lines[@]}"; do
          IFS=$'\t' read -r bundle_dir role common_name basename <<EOF
$line
EOF
          [ -n "$common_name" ] || common_name="unknown CN"
          [ -n "$basename" ] || basename="unknown basename"
          rows+=("$bundle_dir" "$common_name" "$basename")
        done

        choice="$(
          zenity --list \
            --width=1100 \
            --height=520 \
            --title="Choose Request Bundle" \
            --text="Multiple request bundles were found. Choose the intermediate request bundle to review and sign." \
            --column="Bundle" \
            --column="Common Name" \
            --column="Basename" \
            "''${rows[@]}"
        )" || return 1

        if [ -n "$choice" ]; then
          printf '%s' "$choice"
          return 0
        fi
      done
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
        "$policy_root/$root_id/root-signer-policy.json" \
        "$policy_root/$root_id/root-policy.json"
      do
        if [ -f "$candidate" ]; then
          printf '%s' "$candidate"
          return 0
        fi
      done

      return 1
    }

    root_inventory_summary_text() {
      local inventory_dir="$1"
      local root_id=""
      local subject=""
      local yubikey_serial=""

      root_id="$(root_inventory_bundle_root_id "$inventory_dir")"
      subject="$(root_inventory_bundle_subject "$inventory_dir")"
      yubikey_serial="$(root_inventory_bundle_yubikey_serial "$inventory_dir")"

      printf '%s\n' "Inventory path: $inventory_dir"
      if [ -n "$root_id" ]; then
        printf '%s\n' "Root ID: $root_id"
      fi
      if [ -n "$subject" ]; then
        printf '%s\n' "Subject: $subject"
      fi
      if [ -n "$yubikey_serial" ]; then
        printf '%s\n' "Recorded YubiKey serial: $yubikey_serial"
      fi
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

    choose_root_inventory_dir() {
      local root_dir="$1"
      local choice=""
      local line=""
      local inventory_dir=""
      local root_id=""
      local subject=""
      local yubikey_serial=""
      local -a inventory_lines=()
      local -a rows=()

      while true; do
        mapfile -t inventory_lines < <(find_root_inventory_dirs "$root_dir")

        if [ "''${#inventory_lines[@]}" -eq 0 ]; then
          if [ -d "$root_dir" ]; then
            choice="$(zenity --file-selection --directory --width=900 --height=520 --title="Choose Root Inventory Directory" --filename="$root_dir/")" || return 1
            if [ -n "$choice" ]; then
              printf '%s' "$choice"
              return 0
            fi
          fi
          show_error "Root Inventory Not Found" "No committed root inventory entries were found under:
$root_dir"
          return 1
        fi

        if [ "''${#inventory_lines[@]}" -eq 1 ]; then
          IFS=$'\t' read -r inventory_dir root_id subject yubikey_serial <<EOF
''${inventory_lines[0]}
EOF
          printf '%s' "$inventory_dir"
          return 0
        fi

        rows=()
        for line in "''${inventory_lines[@]}"; do
          IFS=$'\t' read -r inventory_dir root_id subject yubikey_serial <<EOF
$line
EOF
          [ -n "$subject" ] || subject="subject unavailable"
          [ -n "$yubikey_serial" ] || yubikey_serial="serial unavailable"
          rows+=("$inventory_dir" "$root_id" "$subject" "$yubikey_serial")
        done

        choice="$(
          zenity --list \
            --width=1200 \
            --height=560 \
            --title="Choose Root Inventory" \
            --text="Choose the committed root inventory entry that should authorize this root signing ceremony." \
            --column="Directory" \
            --column="Root ID" \
            --column="Subject" \
            --column="YubiKey Serial" \
            "''${rows[@]}"
        )" || return 1

        if [ -n "$choice" ]; then
          printf '%s' "$choice"
          return 0
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

      if [ -n "$inventory_uri" ]; then
        printf '%s' "$inventory_uri"
        return 0
      fi

      printf '%s' 'pkcs11:token=YubiKey%20PIV;id=%02;type=private'
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

      printf '%s\n' "Verification summary: $summary_path"
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

    choose_usb_disk() {
      local wait_title="$1"
      local wait_text="$2"
      local list_title="$3"
      local list_text="$4"
      shift 4
      local -a excluded_disk_identities=("$@")
      local line=""
      local choice=""
      local disk_path=""
      local disk_identity=""
      local size=""
      local description=""
      local -a disk_lines=()
      local -a progress_disk_lines=()
      local -a rows=()

      while true; do
        mapfile -t disk_lines < <(list_usb_disks "''${excluded_disk_identities[@]}")

        if [ "''${#disk_lines[@]}" -eq 0 ]; then
          (
            while true; do
              mapfile -t progress_disk_lines < <(list_usb_disks "''${excluded_disk_identities[@]}")
              if [ "''${#progress_disk_lines[@]}" -gt 0 ]; then
                printf '%s\n' "# Removable media detected. Continuing..."
                printf '%s\n' "100"
                break
              fi

              printf '%s\n' "# $wait_text"
              sleep "$poll_seconds"
            done
          ) | zenity --progress \
            --pulsate \
            --auto-close \
            --no-cancel \
            --width=960 \
            --height=500 \
            --title="$wait_title" \
            --text="Waiting for removable media..."
          continue
        fi

        if [ "''${#disk_lines[@]}" -eq 1 ]; then
          printf '%s' "''${disk_lines[0]}"
          return 0
        fi

        rows=()
        for line in "''${disk_lines[@]}"; do
          IFS=$'\t' read -r disk_path disk_identity size description <<EOF
$line
EOF
          [ -n "$description" ] || description="$disk_path"
          rows+=("$disk_path" "$size" "$description")
        done

        choice="$(
          zenity --list \
            --width=1100 \
            --height=520 \
            --title="$list_title" \
            --text="$list_text" \
            --column="Disk" \
            --column="Size" \
            --column="Details" \
            "''${rows[@]}"
        )" || return 1

        for line in "''${disk_lines[@]}"; do
          IFS=$'\t' read -r disk_path disk_identity size description <<EOF
$line
EOF
          if [ "$disk_path" = "$choice" ]; then
            printf '%s' "$line"
            return 0
          fi
        done
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

    log_disk_partition_state() {
      local disk_path="$1"
      local log_path="$2"
      local expected_partition_path=""

      expected_partition_path="$(expected_first_partition_path_for_disk "$disk_path")"
      {
        printf 'Partition scan for %s\n' "$disk_path"
        lsblk -o NAME,PATH,TYPE,FSTYPE,SIZE,MOUNTPOINTS "$disk_path" 2>/dev/null || true
        printf 'expected-first-partition=%s exists=%s\n' \
          "$expected_partition_path" \
          "$(if [ -b "$expected_partition_path" ]; then printf yes; else printf no; fi)"
      } >> "$log_path" 2>&1
    }

    rescan_disk_partition_table() {
      local disk_path="$1"
      local log_path="$2"

      {
        printf 'Rescanning partition table for %s\n' "$disk_path"
        "$sudo_bin" -n partprobe "$disk_path" || true
        "$sudo_bin" -n blockdev --rereadpt "$disk_path" || true
        "$sudo_bin" -n partx -u "$disk_path" || true
        udevadm settle --timeout=5 || true
      } >> "$log_path" 2>&1

      log_disk_partition_state "$disk_path" "$log_path"
    }

    wait_for_partition_path() {
      local disk_path="$1"
      local log_path="$2"
      local partition_path=""
      local retries_remaining="15"

      while [ "$retries_remaining" -gt 0 ]; do
        partition_path="$(first_partition_path_for_disk "$disk_path" || true)"
        if [ -n "$partition_path" ]; then
          printf '%s' "$partition_path"
          return 0
        fi

        rescan_disk_partition_table "$disk_path" "$log_path"
        retries_remaining="$((retries_remaining - 1))"
        sleep 1
      done

      return 1
    }

    run_logged_retry_command() {
      local log_path="$1"
      local retries_remaining="$2"
      shift 2
      local status="0"
      local argument=""

      : > "$log_path"
      while [ "$retries_remaining" -gt 0 ]; do
        {
          printf 'Attempt %s\n' "$((6 - retries_remaining))"
          printf '$'
          for argument in "$@"; do
            printf ' %q' "$argument"
          done
          printf '\n'
          "$@"
        } >> "$log_path" 2>&1 && return 0

        status="$?"
        printf 'exit=%s\n\n' "$status" >> "$log_path"
        retries_remaining="$((retries_remaining - 1))"
        [ "$retries_remaining" -gt 0 ] || return "$status"
        sleep 1
      done

      return "$status"
    }

    show_command_failure() {
      local title="$1"
      local log_path="$2"
      local summary="$3"
      local detail="$summary"
      local excerpt=""

      if [ -n "$log_path" ]; then
        detail="$detail

Log path:
$log_path"
      fi

      if [ -f "$log_path" ]; then
        excerpt="$(tail -n 40 "$log_path" 2>/dev/null || true)"
        if [ -n "$excerpt" ]; then
          detail="$detail

Recent log lines:
$excerpt"
        fi
      fi

      show_error "$title" "$detail" || true
      if [ -f "$log_path" ]; then
        zenity --text-info \
          --width=1100 \
          --height=720 \
          --title="$title Log" \
          --filename="$log_path" || true
      fi
    }

    run_step_with_progress() {
      local title="$1"
      local progress_text="$2"
      shift 2
      local worker_pid=""
      local progress_pid=""
      local status="0"

      "$@" &
      worker_pid="$!"

      (
        while kill -0 "$worker_pid" >/dev/null 2>&1; do
          printf '%s\n' "# $progress_text"
          sleep "$poll_seconds"
        done
        printf '%s\n' "100"
      ) | zenity --progress \
        --pulsate \
        --auto-close \
        --no-cancel \
        --width=960 \
        --height=500 \
        --title="$title" \
        --text="$progress_text" &
      progress_pid="$!"

      if wait "$worker_pid"; then
        status="0"
      else
        status="$?"
      fi
      wait "$progress_pid" || true
      return "$status"
    }

    run_command_with_progress() {
      local title="$1"
      local progress_text="$2"
      local log_path="$3"
      shift 3
      local command_pid=""
      local progress_pid=""
      local status="0"

      "$@" > "$log_path" 2>&1 &
      command_pid="$!"

      (
        while kill -0 "$command_pid" >/dev/null 2>&1; do
          printf '%s\n' "# $progress_text"
          sleep "$poll_seconds"
        done
        printf '%s\n' "100"
      ) | zenity --progress \
        --pulsate \
        --auto-close \
        --no-cancel \
        --width=960 \
        --height=480 \
        --title="$title" \
        --text="$progress_text" &
      progress_pid="$!"

      if wait "$command_pid"; then
        status="0"
      else
        status="$?"
      fi
      wait "$progress_pid" || true
      return "$status"
    }

    format_and_mount_export_disk() {
      local failure_title="$1"
      local export_subject="$2"
      local log_slug="$3"
      local disk_path="$4"
      local mount_path="$5"
      local volume_label="$6"
      local partition_path=""
      local format_log=""

      format_log="$(mktemp "/tmp/pd-pki-$log_slug.XXXXXX.log")"

      unmount_disk_mount_paths "$disk_path" || {
        show_error "$failure_title" "The selected $export_subject could not be unmounted before formatting:
$disk_path"
        rm -f "$format_log"
        return 1
      }

      if ! run_logged_retry_command "$format_log" "5" "$sudo_bin" -n wipefs -af "$disk_path"; then
        show_command_failure "$failure_title" "$format_log" "The selected $export_subject could not be prepared for formatting:
$disk_path"
        return 1
      fi

      if ! run_logged_retry_command "$format_log" "5" "$sudo_bin" -n parted -s "$disk_path" mklabel gpt; then
        show_command_failure "$failure_title" "$format_log" "The selected $export_subject could not be repartitioned:
$disk_path"
        return 1
      fi

      if ! run_logged_retry_command "$format_log" "5" "$sudo_bin" -n parted -s -a optimal "$disk_path" mkpart primary fat32 1MiB 100%; then
        show_command_failure "$failure_title" "$format_log" "The FAT32 partition could not be created on:
$disk_path"
        return 1
      fi

      partition_path="$(wait_for_partition_path "$disk_path" "$format_log")" || {
        show_command_failure "$failure_title" "$format_log" "The new partition on the $export_subject did not appear after formatting:
$disk_path"
        return 1
      }

      if ! run_logged_retry_command "$format_log" "5" "$sudo_bin" -n mkfs.vfat -F 32 -n "$volume_label" "$partition_path"; then
        show_command_failure "$failure_title" "$format_log" "The new FAT32 filesystem could not be created on:
$partition_path"
        return 1
      fi

      install -d -m 700 "$mount_path"
      if ! run_logged_retry_command "$format_log" "5" "$sudo_bin" -n mount -t vfat -o "uid=$(id -u),gid=$(id -g),umask=077" "$partition_path" "$mount_path"; then
        rmdir "$mount_path" 2>/dev/null || true
        show_command_failure "$failure_title" "$format_log" "The freshly formatted $export_subject could not be mounted:
$partition_path"
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
        printf '%s\t0' "$existing_mount"
        return 0
      fi

      install -d -m 700 "$mount_path"
      if ! run_privileged mount -o ro "$partition_path" "$mount_path"; then
        rmdir "$mount_path" 2>/dev/null || true
        show_error "Request USB Mount Failed" "The request USB partition could not be mounted read-only:
$partition_path"
        return 1
      fi

      printf '%s\t1' "$mount_path"
    }

    perform_request_bundle_import() {
      local request_bundle_dir="$1"
      local request_stage_dir="$2"
      local request_mount_path="$3"
      local request_mount_owned="$4"

      rm -rf "$request_stage_dir"
      cp -R "$request_bundle_dir" "$request_stage_dir"
      sync "$request_stage_dir" >/dev/null 2>&1 || sync >/dev/null 2>&1 || true

      if [ "$request_mount_owned" = "1" ]; then
        run_privileged umount "$request_mount_path"
      fi
    }

    confirm_signed_export_disk_format() {
      local disk_path="$1"
      local size="$2"
      local description="$3"

      confirm_step \
        "Confirm Drive Format For Signed Export" \
        "Format And Export" \
        "Cancel" \
        "The selected flash drive will be reformatted before the signed intermediate bundle is written.

All existing data on this drive will be permanently destroyed.

Disk: $disk_path
Size: $size
Details: $description

Continue only if this is the correct flash drive for the signed export bundle."
    }

    perform_signed_bundle_export() {
      local source_dir="$1"
      local bundle_name="$2"
      local work_dir="$3"
      local disk_path="$4"
      local bundle_stage_root=""
      local mount_path=""
      local partition_path=""
      local target_parent=""
      local target_bundle=""
      local export_record_path=""
      local exported_at=""
      local volume_label="PDPKISIGNED"

      bundle_stage_root="$(mktemp -d "/tmp/$bundle_name.XXXXXX")"
      mount_path="$bundle_stage_root/mount"
      target_parent="$mount_path/pd-pki-transfer/signed"
      target_bundle="$target_parent/$bundle_name"
      export_record_path="$work_dir/signed-bundle-export.json"
      exported_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

      partition_path="$(format_and_mount_export_disk \
        "Signed Bundle Export Failed" \
        "flash drive for signed bundle export" \
        "signed-bundle-format" \
        "$disk_path" \
        "$mount_path" \
        "$volume_label")" || {
        rm -rf "$bundle_stage_root"
        return 1
      }

      mkdir -p "$target_parent"
      if ! cp -R "$source_dir" "$target_bundle"; then
        show_error "Signed Bundle Export Failed" "The signed bundle could not be copied to:
$target_parent"
        run_privileged umount "$mount_path" >/dev/null 2>&1 || true
        rm -rf "$bundle_stage_root"
        return 1
      fi

      jq -n \
        --arg exportedAt "$exported_at" \
        --arg mountPath "$mount_path" \
        --arg devicePath "$partition_path" \
        --arg diskPath "$disk_path" \
        --arg bundlePath "$target_bundle" \
        --arg filesystemLabel "$volume_label" \
        '{
          schemaVersion: 1,
          profile: "root-intermediate-signed-export-record",
          exportedAt: $exportedAt,
          mountPath: $mountPath,
          devicePath: $devicePath,
          diskPath: $diskPath,
          bundlePath: $bundlePath,
          filesystemLabel: $filesystemLabel
        }' > "$export_record_path"

      sync
      if ! run_privileged umount "$mount_path"; then
        show_error "Signed Bundle Export Failed" "The signed bundle was written, but the mounted volume could not be unmounted safely:
$mount_path"
        rm -rf "$bundle_stage_root"
        return 1
      fi

      rm -rf "$bundle_stage_root"
      printf '%s' "pd-pki-transfer/signed/$bundle_name"
    }

    show_success_screen() {
      local request_dir="$1"
      local signed_dir="$2"
      local root_inventory_dir="$3"
      local work_dir="$4"
      local exported_bundle_path="$5"
      local common_name=""
      local root_id=""
      local serial=""
      local not_after=""

      common_name="$(request_bundle_common_name "$request_dir")"
      root_id="$(root_inventory_bundle_root_id "$root_inventory_dir")"
      serial="$(jq -r '.serial // empty' "$signed_dir/metadata.json" 2>/dev/null || true)"
      not_after="$(jq -r '.notAfter // empty' "$signed_dir/metadata.json" 2>/dev/null || true)"

      show_info \
        "Signing Complete" \
        "The intermediate request was signed successfully.

Common name: $common_name
Root inventory: $root_id
Issued serial: $serial
Not after: $not_after
Exported signed bundle: $exported_bundle_path
Ceremony work directory: $work_dir

Next steps:
1. Remove the signed export flash drive.
2. Move it to the intermediate system.
3. Import the bundle from pd-pki-transfer/signed/.
4. Retain the ceremony work directory for audit records."
    }

    main() {
      local session_timestamp=""
      local work_dir=""
      local request_stage_dir=""
      local signed_stage_dir=""
      local verify_work_dir=""
      local request_disk_line=""
      local request_disk_path=""
      local request_mount_info=""
      local request_mount_path=""
      local request_mount_owned=""
      local request_bundle_dir=""
      local request_review=""
      local request_role=""
      local root_inventory_dir=""
      local root_inventory_summary=""
      local policy_file_path=""
      local yubikey_serial=""
      local verify_log=""
      local sign_log=""
      local issuer_key_uri=""
      local approved_by=""
      local export_disk_line=""
      local export_disk_path=""
      local export_disk_size=""
      local export_disk_description=""
      local exported_bundle_path=""
      local bundle_name=""

      require_command jq
      require_command lsblk
      require_command findmnt
      require_command wipefs
      require_command parted
      require_command partprobe
      require_command partx
      require_command blockdev
      require_command mkfs.vfat
      require_command mount
      require_command umount
      require_command udevadm
      require_command pd-pki-signing-tools
      require_command ykman
      require_command zenity
      require_command openssl
      [ -x "$sudo_bin" ] || {
        show_error "Missing Dependency" "Required sudo wrapper not found:
$sudo_bin"
        exit 1
      }
      [ -f "$pin_file_path" ] || {
        show_error "Missing PIN File" "Root YubiKey PIN file not found:
$pin_file_path"
        exit 1
      }
      [ -f "$root_cert_file" ] || {
        show_error "Missing Root Certificate" "Root certificate not found:
$root_cert_file"
        exit 1
      }
      [ -d "$root_signer_state_dir" ] || {
        show_error "Missing Signer State" "Root signer state directory not found:
$root_signer_state_dir"
        exit 1
      }

      install -d -m 700 "$sessions_root"

      wait_for_usb_clear

      if ! confirm_step \
        "Confirm Media And Ceremony" \
        "Requirements Confirmed" \
        "Cancel" \
        "Before continuing, confirm that the ceremony team has:

1. One USB flash drive that carries the intermediate CSR request bundle
2. One approved root CA YubiKey for this signing ceremony
3. One separate USB flash drive for the signed export bundle later in the ceremony

This ceremony is partially destructive:
- the request flash drive will be mounted read-only and copied locally
- the outbound signed-bundle flash drive will be reformatted and all existing data on it will be permanently destroyed

Continue only if the correct request media, the correct YubiKey, and a separate export flash drive are available."; then
        exit 0
      fi

      session_timestamp="$(current_timestamp_utc)"
      work_dir="$sessions_root/intermediate-sign-$session_timestamp"
      request_stage_dir="$work_dir/request-bundle"
      signed_stage_dir="$work_dir/signed-bundle"
      verify_work_dir="$work_dir/verify-root-yubikey"
      verify_log="$work_dir/verify-root-yubikey.log"
      sign_log="$work_dir/sign-request.log"
      install -d -m 700 "$work_dir"

      request_disk_line="$(choose_usb_disk \
        "Insert Request Flash Drive" \
        "Insert the USB flash drive that holds the intermediate CSR request bundle.

The wizard will copy the reviewed request locally before asking you to remove the drive." \
        "Choose Request Flash Drive" \
        "Multiple removable disks are available. Choose the disk that holds the intermediate CSR request bundle.")" || exit 0
      IFS=$'\t' read -r request_disk_path _ _ _ <<EOF
$request_disk_line
EOF

      request_mount_info="$(mount_existing_disk_read_only "$request_disk_path" "$work_dir/request-media")" || exit 1
      IFS=$'\t' read -r request_mount_path request_mount_owned <<EOF
$request_mount_info
EOF

      request_bundle_dir="$(choose_request_bundle_from_mount "$request_mount_path")" || exit 0

      if ! run_step_with_progress \
        "Copying Request Bundle" \
        "Copying the selected request bundle locally and safely unmounting the request flash drive.

Please wait and do not remove the drive." \
        perform_request_bundle_import \
        "$request_bundle_dir" \
        "$request_stage_dir" \
        "$request_mount_path" \
        "$request_mount_owned"; then
        show_error "Request Bundle Copy Failed" "The request bundle could not be copied from the selected flash drive."
        exit 1
      fi

      request_role="$(request_bundle_role "$request_stage_dir")"
      if [ "$request_role" != "intermediate-signing-authority" ]; then
        show_error "Unsupported Request Bundle" "This signer wizard only accepts intermediate signing authority request bundles.

Detected role:
$request_role"
        exit 1
      fi

      show_info \
        "Request Bundle Copied" \
        "The request bundle has been copied locally.

Copied bundle:
$request_stage_dir

Remove the request flash drive now. The next screen will wait until all removable USB devices are clear."

      wait_for_usb_clear

      request_review="$(request_bundle_summary_text "$request_stage_dir")"
      if ! confirm_step \
        "Review CSR Details" \
        "Request Matches" \
        "Cancel" \
        "$request_review

Continue only if the request subject, key details, and CA constraints match the approved intermediate issuance."; then
        exit 0
      fi

      root_inventory_dir="$(choose_root_inventory_dir "$inventory_root")" || exit 1
      root_inventory_summary="$(root_inventory_summary_text "$root_inventory_dir")"
      if ! confirm_step \
        "Confirm Root Inventory" \
        "Inventory Confirmed" \
        "Cancel" \
        "$root_inventory_summary

Continue only if this is the committed root inventory entry that should authorize the signing ceremony."; then
        exit 0
      fi

      policy_file_path="$(resolve_root_signer_policy_file "$root_inventory_dir" "$policy_file_fallback_path" || true)"
      if [ -z "$policy_file_path" ]; then
        show_error "Missing Signer Policy" "No root signer policy file was found for the selected inventory entry.

Expected committed policy at one of:
$policy_root/$(root_inventory_bundle_root_id "$root_inventory_dir")/root-signer-policy.json
$policy_root/$(root_inventory_bundle_root_id "$root_inventory_dir")/root-policy.json

Optional fallback path:
''${policy_file_fallback_path:-<not configured>}"
        exit 1
      fi

      yubikey_serial="$(wait_for_single_yubikey)"
      [ -n "$yubikey_serial" ] || {
        show_error "No YubiKey Detected" "The wizard could not determine a YubiKey serial."
        exit 1
      }

      install -d -m 700 "$verify_work_dir"
      if ! run_command_with_progress \
        "Verifying Root CA YubiKey" \
        "Verifying the inserted YubiKey against the committed root inventory.

Please wait and do not remove the token." \
        "$verify_log" \
        pd-pki-signing-tools verify-root-yubikey-identity \
          --inventory-dir "$root_inventory_dir" \
          --yubikey-serial "$yubikey_serial" \
          --pin-file "$pin_file_path" \
          --work-dir "$verify_work_dir"; then
        show_command_failure \
          "Root YubiKey Verification Failed" \
          "$verify_log" \
          "The inserted YubiKey could not be verified against the committed root inventory."
        exit 1
      fi

      show_info \
        "Root YubiKey Verified" \
        "$(root_yubikey_identity_summary_text "$verify_work_dir/root-yubikey-identity-summary.json")"

      approved_by="$(prompt_text "Approval Attribution" "Enter the operator identifier to record for this signing action." "''${USER:-pdpki}")" || exit 0
      approved_by="$(trim_whitespace "$approved_by")"
      if [ -z "$approved_by" ]; then
        show_error "Missing Approval Attribution" "An operator identifier is required to record this issuance."
        exit 1
      fi

      issuer_key_uri="$(stable_yubikey_private_key_uri_from_inventory "$root_inventory_dir")"

      if ! confirm_step \
        "Proceed With Signing" \
        "Sign Intermediate CSR" \
        "Cancel" \
        "The reviewed intermediate request is ready to sign.

Request common name: $(request_bundle_common_name "$request_stage_dir")
Root inventory: $(root_inventory_bundle_root_id "$root_inventory_dir")
Signer policy: $policy_file_path
YubiKey serial: $yubikey_serial
Approved by: $approved_by

When the YubiKey flashes during signing, touch it once if required."; then
        exit 0
      fi

      rm -rf "$signed_stage_dir"
      mkdir -p "$signed_stage_dir"
      if ! run_command_with_progress \
        "Signing Intermediate CSR" \
        "Signing the reviewed intermediate request bundle with the verified root CA YubiKey.

If the YubiKey flashes, touch it to authorize the signing operation." \
        "$sign_log" \
        pd-pki-signing-tools sign-request \
          --request-dir "$request_stage_dir" \
          --out-dir "$signed_stage_dir" \
          --issuer-key-uri "$issuer_key_uri" \
          --pkcs11-module "$pkcs11_module_path" \
          --pkcs11-pin-file "$pin_file_path" \
          --issuer-cert "$root_cert_file" \
          --signer-state-dir "$root_signer_state_dir" \
          --policy-file "$policy_file_path" \
          --approved-by "$approved_by"; then
        show_command_failure \
          "Signing Failed" \
          "$sign_log" \
          "The reviewed intermediate request bundle could not be signed."
        exit 1
      fi

      show_info \
        "Signed Bundle Prepared" \
        "The intermediate request was signed successfully and staged locally.

Staged bundle:
$signed_stage_dir

Remove the YubiKey now. The next screen will wait until all removable USB devices are clear before export."

      wait_for_usb_clear

      export_disk_line="$(choose_usb_disk \
        "Insert Signed Export Flash Drive" \
        "Insert the USB flash drive that should receive the signed intermediate bundle.

This drive will be reformatted before the signed artifacts are written." \
        "Choose Signed Export Flash Drive" \
        "Multiple removable disks are available. Choose the flash drive to reformat for the signed export bundle.")" || exit 0
      IFS=$'\t' read -r export_disk_path _ export_disk_size export_disk_description <<EOF
$export_disk_line
EOF

      if ! confirm_signed_export_disk_format "$export_disk_path" "$export_disk_size" "$export_disk_description"; then
        exit 0
      fi

      bundle_name="intermediate-signed-$session_timestamp"
      exported_bundle_path="$(
        run_step_with_progress \
          "Preparing Signed Export Flash Drive" \
          "Formatting the selected flash drive and writing the signed intermediate bundle.

The wizard is erasing the selected drive, creating a fresh filesystem, copying the signed bundle, and unmounting the drive safely.

Please wait and do not remove the drive." \
          perform_signed_bundle_export \
          "$signed_stage_dir" \
          "$bundle_name" \
          "$work_dir" \
          "$export_disk_path"
      )" || exit 1

      show_success_screen \
        "$request_stage_dir" \
        "$signed_stage_dir" \
        "$root_inventory_dir" \
        "$work_dir" \
        "$exported_bundle_path"
    }

    main "$@"
  '';
}
