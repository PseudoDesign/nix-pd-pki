{ pkgs, pdPkiSigningTools }:
pkgs.writeShellApplication {
  name = "pd-pki-root-yubikey-provisioner-wizard";
  runtimeInputs = [
    pdPkiSigningTools
    pkgs.coreutils
    pkgs.dosfstools
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.jq
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
    readonly profile_path="/etc/pd-pki/root-yubikey-init-profile.json"
    readonly session_home="''${HOME:-/var/lib/pd-pki}"
    readonly sessions_root="$session_home/root-yubikey-provisioning"
    readonly secrets_root="$session_home/secrets"
    readonly archives_root="$session_home/yubikey-inventory"
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

    read_json_value() {
      local query="$1"
      local json_path="$2"

      jq -r "$query" "$json_path" 2>/dev/null ||
        "$sudo_bin" -n jq -r "$query" "$json_path"
    }

    require_command() {
      command -v "$1" >/dev/null 2>&1 || {
        show_error "Missing Dependency" "Required command not found: $1"
        exit 1
      }
    }

    ceremony_timestamp_from_work_dir() {
      local work_dir="$1"
      local work_dir_name=""

      work_dir_name="$(basename "$work_dir")"
      printf '%s' "''${work_dir_name##*-}"
    }

    find_resume_work_dir_for_installed_root_certificate() {
      local certificate_install_path="$1"
      local candidate=""

      [ -f "$certificate_install_path" ] || return 1

      while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        [ -f "$candidate/root-ca.cert.pem" ] || continue
        [ -f "$candidate/root-yubikey-init-summary.json" ] || continue
        if "$sudo_bin" -n cmp -s "$candidate/root-ca.cert.pem" "$certificate_install_path"; then
          printf '%s' "$candidate"
          return 0
        fi
      done < <(
        find "$sessions_root" -maxdepth 1 -mindepth 1 -type d -name 'root-*' -printf '%T@ %p\n' 2>/dev/null |
          sort -nr |
          cut -d' ' -f2-
      )

      return 1
    }

    handle_existing_root_certificate_install_path() {
      local certificate_install_path="$1"
      local resume_work_dir=""
      local summary_path=""
      local yubikey_serial=""
      local certificate_fingerprint=""
      local public_bundle_relative_path=""

      [ -e "$certificate_install_path" ] || return 0

      resume_work_dir="$(find_resume_work_dir_for_installed_root_certificate "$certificate_install_path" || true)"
      if [ -n "$resume_work_dir" ]; then
        summary_path="$resume_work_dir/root-yubikey-init-summary.json"
        yubikey_serial="$(read_json_value '.yubikeySerial // empty' "$summary_path" 2>/dev/null || true)"
        certificate_fingerprint="$(read_json_value '.certificate.sha256Fingerprint // empty' "$summary_path" 2>/dev/null || true)"

        if confirm_step \
          "Existing Root Certificate Installed" \
          "Export Public Bundle" \
          "Cancel" \
          "This appliance already has an installed runtime root certificate:

$certificate_install_path

Matching completed ceremony artifacts were found:
$resume_work_dir

YubiKey serial: $yubikey_serial
Certificate fingerprint: $certificate_fingerprint

Provisioning a new root on top of the existing runtime certificate is blocked.

You can still finish this ceremony by exporting the public root-inventory bundle from the completed work directory to a third flash drive now."; then
          wait_for_usb_clear
          public_bundle_relative_path="$(
            export_public_root_inventory_bundle \
              "$resume_work_dir" \
              "$(ceremony_timestamp_from_work_dir "$resume_work_dir")" \
              "$resume_work_dir" \
              "" \
              ""
          )" || exit 1
          show_resumed_public_export_success_screen \
            "$summary_path" \
            "$resume_work_dir" \
            "$public_bundle_relative_path"
          exit 0
        fi
      fi

      show_error \
        "Existing Root Certificate Installed" \
        "This appliance already has an installed runtime root certificate:

$certificate_install_path

Provisioning a new root on top of an existing runtime certificate is blocked.

Use a fresh appliance image for a new ceremony, or if this is an intentional lab rerun, move the existing runtime root certificate and matching runtime metadata aside before restarting the wizard."
      exit 1
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

    usb_device_is_keyboard_or_hub_only() {
      local device_path="$1"
      local interface_path=""
      local class=""
      local subclass=""
      local protocol=""
      local found_interface=0

      for interface_path in "$device_path":*; do
        [ -d "$interface_path" ] || continue
        [ -f "$interface_path/bInterfaceClass" ] || continue
        found_interface=1
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
        if usb_device_is_keyboard_or_hub_only "$device_path"; then
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

    disk_identity_for_usb_export_disk() {
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

    list_usb_export_disks() {
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
          disk_identity="$(disk_identity_for_usb_export_disk "$serial" "$vendor" "$model" "$size" "$disk_path")"
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

The wizard will stay on this screen until only the keyboard remains attached.

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
            printf '%s\n' "# Insert the YubiKey to provision.

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

    generate_numeric_secret() {
      local length="$1"
      local value=""

      while [ "''${#value}" -lt "$length" ]; do
        value="$value$(LC_ALL=C tr -dc '0-9' < /dev/urandom | head -c "$length" || true)"
      done

      printf '%s' "''${value:0:length}"
    }

    generate_management_key() {
      openssl rand -hex 32 | tr '[:lower:]' '[:upper:]'
    }

    root_id_from_certificate() {
      local certificate_path="$1"

      {
        openssl x509 -in "$certificate_path" -noout -fingerprint -sha256 2>/dev/null ||
          "$sudo_bin" -n openssl x509 -in "$certificate_path" -noout -fingerprint -sha256
      } |
        cut -d= -f2 |
        tr -d ':' |
        tr '[:upper:]' '[:lower:]'
    }

    generate_credentials() {
      local pin=""
      local puk=""
      local management_key=""

      pin="$(generate_numeric_secret 8)"
      puk="$(generate_numeric_secret 8)"
      while [ "$puk" = "$pin" ]; do
        puk="$(generate_numeric_secret 8)"
      done
      management_key="$(generate_management_key)"

      printf '%s\t%s\t%s\n' "$pin" "$puk" "$management_key"
    }

    write_secret_file() {
      local target_path="$1"
      local secret="$2"
      (
        umask 077
        printf '%s\n' "$secret" > "$target_path"
      )
    }

    choose_usb_disk_for_secret_export() {
      local share_label="$1"
      shift
      local -a excluded_disk_identities=("$@")
      local disk_path=""
      local disk_identity=""
      local size=""
      local description=""
      local line=""
      local choice=""
      local -a disk_lines=()
      local -a progress_disk_lines=()
      local -a rows=()

      while true; do
        mapfile -t disk_lines < <(list_usb_export_disks "''${excluded_disk_identities[@]}")

        if [ "''${#disk_lines[@]}" -eq 0 ]; then
          (
            while true; do
              mapfile -t progress_disk_lines < <(list_usb_export_disks "''${excluded_disk_identities[@]}")
              if [ "''${#progress_disk_lines[@]}" -gt 0 ]; then
                printf '%s\n' "# Removable media detected. Continuing..."
                printf '%s\n' "100"
                break
              fi

              printf '%s\n' "# Insert the USB flash drive for custodian $share_label.

The wizard will format the selected drive before writing the PIN, the PUK, and management key share $share_label.

Use a different flash drive for each custodian."
              sleep "$poll_seconds"
            done
          ) | zenity --progress \
            --pulsate \
            --auto-close \
            --no-cancel \
            --width=960 \
            --height=500 \
            --title="Insert Flash Drive For Custodian $share_label" \
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
            --title="Choose Flash Drive For Custodian $share_label" \
            --text="Multiple removable disks are available. Choose the disk to format for custodian $share_label." \
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

    choose_usb_disk_for_public_inventory_export() {
      local excluded_disk_identity_a="$1"
      local excluded_disk_identity_b="$2"
      local disk_path=""
      local disk_identity=""
      local size=""
      local description=""
      local line=""
      local choice=""
      local -a disk_lines=()
      local -a progress_disk_lines=()
      local -a rows=()

      while true; do
        mapfile -t disk_lines < <(list_usb_export_disks "$excluded_disk_identity_a" "$excluded_disk_identity_b")

        if [ "''${#disk_lines[@]}" -eq 0 ]; then
          (
            while true; do
              mapfile -t progress_disk_lines < <(list_usb_export_disks "$excluded_disk_identity_a" "$excluded_disk_identity_b")
              if [ "''${#progress_disk_lines[@]}" -gt 0 ]; then
                printf '%s\n' "# Removable media detected. Continuing..."
                printf '%s\n' "100"
                break
              fi

              printf '%s\n' "# Insert the third USB flash drive for public root-inventory export.

This drive will be reformatted before the public root certificate artifacts are written.

Use a flash drive that is different from both custodian secret-share drives."
              sleep "$poll_seconds"
            done
          ) | zenity --progress \
            --pulsate \
            --auto-close \
            --no-cancel \
            --width=960 \
            --height=500 \
            --title="Insert Flash Drive For Public Export" \
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
            --title="Choose Flash Drive For Public Export" \
            --text="Multiple removable disks are available. Choose the flash drive to format for public root-inventory export." \
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

    confirm_secret_export_disk_format() {
      local share_label="$1"
      local disk_path="$2"
      local size="$3"
      local description="$4"

      confirm_step \
        "Confirm Drive Format For Custodian $share_label" \
        "Format And Export" \
        "Cancel" \
        "The selected flash drive will be reformatted before the secret-share bundle is written.

All existing data on this drive will be permanently destroyed.

Custodian: $share_label
Disk: $disk_path
Size: $size
Details: $description

Continue only if this is the correct flash drive for custodian $share_label."
    }

    confirm_public_inventory_disk_format() {
      local disk_path="$1"
      local size="$2"
      local description="$3"

      confirm_step \
        "Confirm Drive Format For Public Export" \
        "Format And Export" \
        "Cancel" \
        "The selected flash drive will be reformatted before the public root-inventory bundle is written.

All existing data on this drive will be permanently destroyed.

Disk: $disk_path
Size: $size
Details: $description

Continue only if this is the correct third flash drive for exporting the public root certificate artifacts."
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

    perform_secret_share_bundle_export() {
      local share_label="$1"
      local share_position="$2"
      local management_key_share="$3"
      local root_pin="$4"
      local root_puk="$5"
      local session_timestamp="$6"
      local secret_dir="$7"
      local subject="$8"
      local validity_days="$9"
      local disk_path="''${10}"
      local share_slug=""
      local partition_path=""
      local mount_path=""
      local bundle_name=""
      local bundle_stage_root=""
      local bundle_stage_path=""
      local target_parent=""
      local target_bundle=""
      local export_record_path=""
      local management_key_share_file=""
      local exported_at=""
      local volume_label=""

      share_slug="$(printf '%s' "$share_label" | tr '[:upper:]' '[:lower:]')"
      bundle_name="root-yubikey-secret-share-$share_slug-$session_timestamp"
      bundle_stage_root="$(mktemp -d "/tmp/$bundle_name.XXXXXX")"
      bundle_stage_path="$bundle_stage_root/$bundle_name"
      mount_path="$bundle_stage_root/mount"
      target_parent="$mount_path/pd-pki-transfer/root-secret-shares"
      target_bundle="$target_parent/$bundle_name"
      export_record_path="$secret_dir/share-$share_slug-export.json"
      management_key_share_file="root-management-key-share-$share_slug.txt"
      exported_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      volume_label="$(printf 'PDRT%s' "$share_label" | tr '[:lower:]' '[:upper:]')"

      partition_path="$(format_and_mount_export_disk \
        "Share Export Failed" \
        "flash drive for custodian $share_label" \
        "secret-share-format-$share_label" \
        "$disk_path" \
        "$mount_path" \
        "$volume_label")" || {
        rm -rf "$bundle_stage_root"
        return 1
      }

      install -d -m 700 "$bundle_stage_path"
      write_secret_file "$bundle_stage_path/root-pin.txt" "$root_pin"
      write_secret_file "$bundle_stage_path/root-puk.txt" "$root_puk"
      write_secret_file "$bundle_stage_path/$management_key_share_file" "$management_key_share"
      cat > "$bundle_stage_path/README.txt" <<EOF
Pseudo Design root YubiKey secret share bundle

Custodian share: $share_label of 2
Ceremony timestamp: $session_timestamp
Subject: $subject
Validity days: $validity_days

This bundle contains:
- the routine root-signing PIN
- the break-glass PUK
- management key share $share_label

Management key reconstruction:
- share A is the first 32 hexadecimal characters
- share B is the final 32 hexadecimal characters
- reconstruct by concatenating share A followed by share B with no separator

Handle this drive as a sealed ceremony secret.
EOF
      jq -n \
        --arg exportedAt "$exported_at" \
        --arg ceremonyTimestamp "$session_timestamp" \
        --arg shareId "$share_label" \
        --arg sharePosition "$share_position" \
        --arg subject "$subject" \
        --arg validityDays "$validity_days" \
        --arg pinFile "root-pin.txt" \
        --arg pukFile "root-puk.txt" \
        --arg managementKeyShareFile "$management_key_share_file" \
        '{
          schemaVersion: 1,
          profile: "root-yubikey-secret-share",
          exportedAt: $exportedAt,
          ceremonyTimestamp: $ceremonyTimestamp,
          subject: $subject,
          validityDays: $validityDays,
          shareId: $shareId,
          shareCount: 2,
          sharePosition: $sharePosition,
          managementKeyReassembly: "Concatenate share A followed by share B with no separator.",
          files: {
            pin: $pinFile,
            puk: $pukFile,
            managementKeyShare: $managementKeyShareFile
          }
        }' > "$bundle_stage_path/manifest.json"

      if run_privileged test -e "$target_bundle"; then
        show_error "Share Export Failed" "The destination already contains:
$target_bundle"
        rm -rf "$bundle_stage_root"
        return 1
      fi

      if ! mkdir -p "$target_parent"; then
        show_error "Share Export Failed" "The destination path could not be created:
$target_parent"
        run_privileged umount "$mount_path" >/dev/null 2>&1 || true
        rm -rf "$bundle_stage_root"
        return 1
      fi

      if ! cp -R "$bundle_stage_path" "$target_parent/"; then
        show_error "Share Export Failed" "The secret share for custodian $share_label could not be copied to:
$target_parent"
        run_privileged umount "$mount_path" >/dev/null 2>&1 || true
        rm -rf "$bundle_stage_root"
        return 1
      fi

      jq -n \
        --arg exportedAt "$exported_at" \
        --arg shareId "$share_label" \
        --arg mountPath "$mount_path" \
        --arg devicePath "$partition_path" \
        --arg diskPath "$disk_path" \
        --arg bundlePath "$target_bundle" \
        --arg filesystemLabel "$volume_label" \
        '{
          schemaVersion: 1,
          profile: "root-yubikey-secret-share-export-record",
          exportedAt: $exportedAt,
          shareId: $shareId,
          mountPath: $mountPath,
          devicePath: $devicePath,
          diskPath: $diskPath,
          bundlePath: $bundlePath,
          filesystemLabel: $filesystemLabel
        }' > "$export_record_path"

      sync
      if ! run_privileged umount "$mount_path"; then
        show_error "Share Export Failed" "The flash drive for custodian $share_label was written, but the mounted volume could not be unmounted safely:
$mount_path"
        rm -rf "$bundle_stage_root"
        return 1
      fi

      rm -rf "$bundle_stage_root"

      show_info \
        "Custodian $share_label Exported" \
        "The flash drive for custodian $share_label was reformatted and the secret-share bundle was written successfully.

Disk: $disk_path
Filesystem label: $volume_label
Bundle path: $target_bundle

The volume has been unmounted. Remove and seal the flash drive now."
    }

    export_secret_share_bundle() {
      local share_label="$1"
      local share_position="$2"
      local management_key_share="$3"
      local root_pin="$4"
      local root_puk="$5"
      local session_timestamp="$6"
      local secret_dir="$7"
      local subject="$8"
      local validity_days="$9"
      local excluded_disk_identity="''${10}"
      local selected_line=""
      local disk_path=""
      local disk_identity=""
      local size=""
      local description=""

      selected_line="$(choose_usb_disk_for_secret_export "$share_label" "$excluded_disk_identity")" || return 1
      IFS=$'\t' read -r disk_path disk_identity size description <<EOF
$selected_line
EOF

      if ! confirm_secret_export_disk_format "$share_label" "$disk_path" "$size" "$description"; then
        return 1
      fi

      run_step_with_progress \
        "Preparing Custodian $share_label Flash Drive" \
        "Formatting and writing the flash drive for custodian $share_label.

The wizard is erasing the selected drive, creating a fresh filesystem, copying the secret-share bundle, and unmounting the drive safely.

Please wait and do not remove the drive." \
        perform_secret_share_bundle_export \
        "$share_label" \
        "$share_position" \
        "$management_key_share" \
        "$root_pin" \
        "$root_puk" \
        "$session_timestamp" \
        "$secret_dir" \
        "$subject" \
        "$validity_days" \
        "$disk_path" || return 1

      printf '%s' "$disk_identity"
    }

    perform_public_root_inventory_export() {
      local source_dir="$1"
      local bundle_name="$2"
      local work_dir="$3"
      local disk_path="$4"
      local bundle_stage_root=""
      local mount_path=""
      local partition_path=""
      local target_parent=""
      local target_bundle=""
      local export_log=""
      local export_record_path=""
      local exported_at=""
      local volume_label="PDRTPUB"

      bundle_stage_root="$(mktemp -d "/tmp/$bundle_name.XXXXXX")"
      mount_path="$bundle_stage_root/mount"
      target_parent="$mount_path/pd-pki-transfer/root-inventory"
      target_bundle="$target_parent/$bundle_name"
      export_log="$work_dir/root-inventory-export.log"
      export_record_path="$work_dir/root-inventory-export.json"
      exported_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

      partition_path="$(format_and_mount_export_disk \
        "Public Inventory Export Failed" \
        "flash drive for public root-inventory export" \
        "public-root-inventory-format" \
        "$disk_path" \
        "$mount_path" \
        "$volume_label")" || {
        rm -rf "$bundle_stage_root"
        return 1
      }

      mkdir -p "$target_parent"
      if ! "$sudo_bin" -n pd-pki-signing-tools export-root-inventory \
        --source-dir "$source_dir" \
        --out-dir "$target_bundle" > "$export_log" 2>&1; then
        show_command_failure \
          "Public Inventory Export Failed" \
          "$export_log" \
          "The public root-inventory bundle could not be exported to the selected flash drive."
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
        --arg logPath "$export_log" \
        '{
          schemaVersion: 1,
          profile: "root-yubikey-public-export-record",
          exportedAt: $exportedAt,
          mountPath: $mountPath,
          devicePath: $devicePath,
          diskPath: $diskPath,
          bundlePath: $bundlePath,
          filesystemLabel: $filesystemLabel,
          logPath: $logPath
        }' > "$export_record_path"

      sync
      if ! run_privileged umount "$mount_path"; then
        show_error "Public Inventory Export Failed" "The public root-inventory bundle was written, but the mounted volume could not be unmounted safely:
$mount_path"
        rm -rf "$bundle_stage_root"
        return 1
      fi

      rm -rf "$bundle_stage_root"

      show_info \
        "Public Inventory Exported" \
        "The public root-inventory flash drive was reformatted and the exported artifact bundle was written successfully.

Disk: $disk_path
Filesystem label: $volume_label
Bundle path: $target_bundle

The volume has been unmounted. Remove the flash drive and move it to the development machine for normalization and commit."
    }

    export_public_root_inventory_bundle() {
      local source_dir="$1"
      local session_timestamp="$2"
      local work_dir="$3"
      local excluded_disk_identity_a="$4"
      local excluded_disk_identity_b="$5"
      local selected_line=""
      local disk_path=""
      local disk_identity=""
      local size=""
      local description=""
      local root_id=""
      local bundle_name=""
      local relative_bundle_path=""

      root_id="$(root_id_from_certificate "$source_dir/root-ca.cert.pem")" || {
        show_error "Public Inventory Export Failed" "The public root certificate could not be read from the ceremony work directory:
$source_dir/root-ca.cert.pem"
        return 1
      }
      bundle_name="root-$root_id-$session_timestamp"
      relative_bundle_path="pd-pki-transfer/root-inventory/$bundle_name"

      selected_line="$(choose_usb_disk_for_public_inventory_export "$excluded_disk_identity_a" "$excluded_disk_identity_b")" || return 1
      IFS=$'\t' read -r disk_path disk_identity size description <<EOF
$selected_line
EOF

      if ! confirm_public_inventory_disk_format "$disk_path" "$size" "$description"; then
        return 1
      fi

      run_step_with_progress \
        "Preparing Public Root Inventory Flash Drive" \
        "Formatting the selected flash drive and exporting the public root certificate artifacts.

The wizard is erasing the selected drive, creating a fresh filesystem, writing the public root-inventory bundle, and unmounting the drive safely.

Please wait and do not remove the drive." \
        perform_public_root_inventory_export \
        "$source_dir" \
        "$bundle_name" \
        "$work_dir" \
        "$disk_path" || return 1

      printf '%s' "$relative_bundle_path"
    }

    remove_local_plaintext_secret_files() {
      local secret_dir="$1"
      local pin_file="$2"
      local puk_file="$3"
      local management_key_file="$4"

      rm -f "$pin_file" "$puk_file" "$management_key_file"
      cat > "$secret_dir/README.txt" <<EOF
Pseudo Design root YubiKey local secret handling

The plaintext PIN, PUK, and full management key files were removed from this
workstation after successful provisioning.

This directory retains only non-secret export records for the removable-media
share bundles.
EOF
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

    run_command_with_progress() {
      local title="$1"
      local progress_text="$2"
      local log_path="$3"
      shift 3
      local command_pid=""
      local progress_pid=""
      local status="0"
      local live_progress_text=""
      local touch_line=""

      "$@" > "$log_path" 2>&1 &
      command_pid="$!"

      (
        while kill -0 "$command_pid" >/dev/null 2>&1; do
          live_progress_text="$progress_text"
          if [ -f "$log_path" ]; then
            touch_line="$(grep -E 'Touch your YubiKey|Touch not detected' "$log_path" 2>/dev/null | tail -n1 || true)"
            if [ -n "$touch_line" ]; then
              live_progress_text="Touch the YubiKey now.

$touch_line"
            fi
          fi
          printf '%s\n' "# $live_progress_text"
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

    show_plan_review() {
      local work_dir="$1"
      local yubikey_serial="$2"
      local plan_path="$work_dir/root-yubikey-init-plan.json"
      local subject=""
      local validity_days=""
      local slot=""
      local algorithm=""
      local pin_policy=""
      local touch_policy=""
      local certificate_install_path=""
      local archive_dir=""

      subject="$(jq -r '.subject' "$plan_path")"
      validity_days="$(jq -r '.validityDays' "$plan_path")"
      slot="$(jq -r '.slot' "$plan_path")"
      algorithm="$(jq -r '.algorithm' "$plan_path")"
      pin_policy="$(jq -r '.pinPolicy' "$plan_path")"
      touch_policy="$(jq -r '.touchPolicy' "$plan_path")"
      certificate_install_path="$(jq -r '.certificateInstallPath' "$plan_path")"
      archive_dir="$(jq -r '.archiveDirectory' "$plan_path")"

      confirm_step \
        "Review Provisioning Plan" \
        "Continue" \
        "Cancel" \
        "The provisioning plan has been generated and saved.

YubiKey serial: $yubikey_serial
Subject: $subject
Validity days: $validity_days
Slot: $slot
Algorithm: $algorithm
PIN policy: $pin_policy
Touch policy: $touch_policy
Certificate install path: $certificate_install_path
Archive directory: $archive_dir
Work directory: $work_dir

Continue only if this matches the expected ceremony."
    }

    show_success_screen() {
      local summary_path="$1"
      local secret_dir="$2"
      local work_dir="$3"
      local public_bundle_relative_path="$4"
      local yubikey_serial=""
      local certificate_install_path=""
      local archive_dir=""
      local certificate_fingerprint=""

      yubikey_serial="$(read_json_value '.yubikeySerial' "$summary_path")"
      certificate_install_path="$(read_json_value '.certificateInstallPath' "$summary_path")"
      archive_dir="$(read_json_value '.archiveDirectory' "$summary_path")"
      certificate_fingerprint="$(read_json_value '.certificate.sha256Fingerprint' "$summary_path")"

      show_info \
        "Provisioning Complete" \
        "Root YubiKey provisioning completed successfully.

YubiKey serial: $yubikey_serial
Certificate fingerprint: $certificate_fingerprint
Installed certificate: $certificate_install_path
Archived public artifacts: $archive_dir
Exported public bundle: $public_bundle_relative_path
Ceremony work directory: $work_dir
Secret export records: $secret_dir

The plaintext PIN, PUK, and full management key files were removed from this workstation after provisioning. Custodian flash drives now hold the exported secret shares.

Next steps:
1. Move the public export flash drive to the development machine.
2. Run normalize-root-inventory using the exported bundle path shown above.
3. Commit the resulting inventory entry in the repository.
4. Run verify-root-yubikey-identity before future root signing ceremonies."
    }

    show_resumed_public_export_success_screen() {
      local summary_path="$1"
      local work_dir="$2"
      local public_bundle_relative_path="$3"
      local yubikey_serial=""
      local certificate_fingerprint=""

      yubikey_serial="$(read_json_value '.yubikeySerial' "$summary_path")"
      certificate_fingerprint="$(read_json_value '.certificate.sha256Fingerprint' "$summary_path")"

      show_info \
        "Public Export Complete" \
        "The root YubiKey was already provisioned successfully during an earlier ceremony run, and the public root-inventory bundle has now been exported to the flash drive.

YubiKey serial: $yubikey_serial
Certificate fingerprint: $certificate_fingerprint
Ceremony work directory: $work_dir
Exported public bundle: $public_bundle_relative_path

Next steps:
1. Move the public export flash drive to the development machine.
2. Run normalize-root-inventory using the exported bundle path shown above.
3. Commit the resulting inventory entry in the repository.
4. Run verify-root-yubikey-identity before future root signing ceremonies."
    }

    main() {
      local credentials=""
      local root_pin=""
      local root_puk=""
      local root_management_key=""
      local management_key_share_a=""
      local management_key_share_b=""
      local session_timestamp=""
      local subject=""
      local validity_days=""
      local yubikey_serial=""
      local work_dir=""
      local secret_dir=""
      local pin_file=""
      local puk_file=""
      local management_key_file=""
      local dry_run_log=""
      local apply_log=""
      local share_a_disk_identity=""
      local share_b_disk_identity=""
      local archive_dir=""
      local public_bundle_relative_path=""
      local certificate_install_path=""

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
      require_command cmp
      [ -x "$sudo_bin" ] || {
        show_error "Missing Dependency" "Required sudo wrapper not found:
$sudo_bin"
        exit 1
      }
      [ -f "$profile_path" ] || {
        show_error "Missing Profile" "Provisioning profile not found:
$profile_path"
        exit 1
      }

      install -d -m 700 "$sessions_root" "$secrets_root"
      subject="$(jq -r '.subject' "$profile_path")"
      validity_days="$(jq -r '.validityDays' "$profile_path")"
      certificate_install_path="$(jq -r '.certificateInstallPath' "$profile_path")"

      handle_existing_root_certificate_install_path "$certificate_install_path"

      wait_for_usb_clear

      if ! confirm_step \
        "Confirm Media And Destructive Operation" \
        "Requirements Confirmed" \
        "Cancel" \
        "Before continuing, confirm that the ceremony team has:

1. Three USB flash drives
   - two custodian drives for secret-share export
   - one additional drive for public root-inventory export later in the ceremony
2. One YubiKey that is approved for this root-provisioning operation

This ceremony is destructive:
- the approved YubiKey will be reset and any existing PIV material on it will be permanently erased
- each flash drive selected during this ceremony, including the third drive used for public root-inventory export, will be reformatted and all existing data on it will be permanently destroyed

Continue only if the YubiKey is new in box or has been explicitly designated acceptable for this destroy-and-replace ceremony, and only if the three USB flash drives are available for use."; then
        exit 0
      fi

      credentials="$(generate_credentials)" || exit 1
      IFS=$'\t' read -r root_pin root_puk root_management_key <<EOF
$credentials
EOF

      management_key_share_a="''${root_management_key:0:32}"
      management_key_share_b="''${root_management_key:32:32}"
      session_timestamp="$(current_timestamp_utc)"
      secret_dir="$secrets_root/root-yubikey-$session_timestamp"
      pin_file="$secret_dir/root-pin.txt"
      puk_file="$secret_dir/root-puk.txt"
      management_key_file="$secret_dir/root-management-key.txt"
      install -d -m 700 "$secret_dir"

      show_info \
        "Export Ceremony Secrets" \
        "The wizard has generated a fresh PIN, a fresh PUK, and a two-part management key.

The next two steps will export:
- the PIN
- the PUK
- one half of the management key

to two separate USB flash drives, one for each custodian.

Each flash drive selected during this ceremony will be reformatted immediately before its bundle is written, including the third drive used later for public root-inventory export.

Remove and seal each flash drive after export."

      share_a_disk_identity="$(
        export_secret_share_bundle \
          "A" \
          "first-half" \
          "$management_key_share_a" \
          "$root_pin" \
          "$root_puk" \
          "$session_timestamp" \
          "$secret_dir" \
          "$subject" \
          "$validity_days" \
          ""
      )" || exit 1

      wait_for_usb_clear

      share_b_disk_identity="$(
        export_secret_share_bundle \
        "B" \
        "second-half" \
        "$management_key_share_b" \
        "$root_pin" \
        "$root_puk" \
        "$session_timestamp" \
        "$secret_dir" \
        "$subject" \
        "$validity_days" \
        "$share_a_disk_identity"
      )" || exit 1

      wait_for_usb_clear

      yubikey_serial="$(wait_for_single_yubikey)"
      [ -n "$yubikey_serial" ] || {
        show_error "No YubiKey Detected" "The wizard could not determine a YubiKey serial."
        exit 1
      }

      work_dir="$sessions_root/root-$yubikey_serial-$session_timestamp"
      archive_dir="$archives_root/root-$yubikey_serial-$session_timestamp"
      dry_run_log="$work_dir/init-root-yubikey.dry-run.log"
      apply_log="$work_dir/init-root-yubikey.apply.log"

      install -d -m 700 "$work_dir"

      if ! run_command_with_progress \
        "Preparing Provisioning Plan" \
        "Generating the reviewed dry-run plan for YubiKey serial $yubikey_serial..." \
        "$dry_run_log" \
        pd-pki-signing-tools init-root-yubikey \
          --profile "$profile_path" \
          --yubikey-serial "$yubikey_serial" \
          --work-dir "$work_dir" \
          --archive-dir "$archive_dir" \
          --dry-run; then
        show_command_failure \
          "Dry-Run Failed" \
          "$dry_run_log" \
          "The provisioning plan could not be generated. Review the log for details."
        exit 1
      fi

      if ! show_plan_review "$work_dir" "$yubikey_serial"; then
        exit 0
      fi

      if ! confirm_step \
        "Final Erase Warning" \
        "Erase And Provision" \
        "Cancel" \
        "The wizard is ready to provision YubiKey serial $yubikey_serial.

This step irreversibly erases the token PIV application, generates a new root CA signing key in slot 9C, writes the self-signed root certificate, and archives the public ceremony artifacts.

When the YubiKey flashes during certificate generation, touch it once to authorize the operation."; then
        exit 0
      fi

      write_secret_file "$pin_file" "$root_pin"
      write_secret_file "$puk_file" "$root_puk"
      write_secret_file "$management_key_file" "$root_management_key"

      if ! run_command_with_progress \
        "Provisioning YubiKey" \
        "Provisioning YubiKey serial $yubikey_serial.

Touch the YubiKey once when it begins flashing during certificate generation." \
        "$apply_log" \
        "$sudo_bin" -n pd-pki-signing-tools init-root-yubikey \
          --profile "$profile_path" \
          --yubikey-serial "$yubikey_serial" \
          --work-dir "$work_dir" \
          --archive-dir "$archive_dir" \
          --pin-file "$pin_file" \
          --puk-file "$puk_file" \
          --management-key-file "$management_key_file" \
          --force-reset; then
        show_command_failure \
          "Provisioning Failed" \
          "$apply_log" \
          "The YubiKey provisioning step failed. If privilege escalation was unavailable, the attached log will show the sudo error directly. The generated credentials remain in:
$secret_dir"
        exit 1
      fi

      remove_local_plaintext_secret_files "$secret_dir" "$pin_file" "$puk_file" "$management_key_file"
      wait_for_usb_clear

      public_bundle_relative_path="$(
        export_public_root_inventory_bundle \
          "$work_dir" \
          "$session_timestamp" \
          "$work_dir" \
          "$share_a_disk_identity" \
          "$share_b_disk_identity"
      )" || exit 1

      show_success_screen \
        "$work_dir/root-yubikey-init-summary.json" \
        "$secret_dir" \
        "$work_dir" \
        "$public_bundle_relative_path"
    }

    main "$@"
  '';
}
