{ pkgs, pdPkiSigningTools }:
pkgs.writeShellApplication {
  name = "pd-pki-root-yubikey-provisioner-wizard";
  runtimeInputs = [
    pdPkiSigningTools
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.jq
    pkgs.openssl
    pkgs.procps
    pkgs.sudo
    pkgs.usbutils
    pkgs.util-linux
    pkgs.yubikey-manager
    pkgs.zenity
  ];
  text = ''
    set -euo pipefail

    readonly poll_seconds="2"
    readonly profile_path="/etc/pd-pki/root-yubikey-init-profile.json"
    readonly operator_home="''${HOME:-/home/operator}"
    readonly sessions_root="$operator_home/root-yubikey-provisioning"
    readonly secrets_root="$operator_home/secrets"

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

    require_command() {
      command -v "$1" >/dev/null 2>&1 || {
        show_error "Missing Dependency" "Required command not found: $1"
        exit 1
      }
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

    prompt_credentials_verification() {
      local expected_pin="$1"
      local expected_puk="$2"
      local expected_management_key="$3"
      local entered=""
      local entered_pin=""
      local entered_puk=""
      local entered_management_key=""

      entered="$(zenity --forms \
        --width=980 \
        --height=520 \
        --title="Verify Recorded Credentials" \
        --text="Type the credentials back exactly as recorded before provisioning continues." \
        --separator='|' \
        --add-entry="PIN" \
        --add-entry="PUK" \
        --add-entry="Management Key")" || return 1

      IFS='|' read -r entered_pin entered_puk entered_management_key <<EOF
$entered
EOF

      if [ "$entered_pin" = "$expected_pin" ] && [ "$entered_puk" = "$expected_puk" ] && [ "$entered_management_key" = "$expected_management_key" ]; then
        return 0
      fi

      return 1
    }

    generate_and_confirm_credentials() {
      local pin=""
      local puk=""
      local management_key=""

      while true; do
        pin="$(generate_numeric_secret 8)"
        puk="$(generate_numeric_secret 8)"
        while [ "$puk" = "$pin" ]; do
          puk="$(generate_numeric_secret 8)"
        done
        management_key="$(generate_management_key)"

        show_info \
          "Record New Credentials" \
          "Write down these credentials before continuing.

PIN
$pin

PUK
$puk

Management Key
$management_key

The next screen will ask you to type them back exactly."

        while true; do
          if prompt_credentials_verification "$pin" "$puk" "$management_key"; then
            printf '%s\t%s\t%s\n' "$pin" "$puk" "$management_key"
            return 0
          fi

          if confirm_step \
            "Credentials Did Not Match" \
            "Retry Entry" \
            "Generate New Set" \
            "The recorded values did not match what was entered.

Choose Retry Entry to try again with the same values.
Choose Generate New Set to discard them and create a fresh PIN, PUK, and management key."; then
            continue
          fi
          break
        done
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

    show_command_failure() {
      local title="$1"
      local log_path="$2"
      local summary="$3"

      show_error "$title" "$summary"
      if [ -f "$log_path" ]; then
        zenity --text-info \
          --width=1100 \
          --height=720 \
          --title="$title Log" \
          --filename="$log_path"
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
      local yubikey_serial=""
      local certificate_install_path=""
      local archive_dir=""
      local certificate_fingerprint=""

      yubikey_serial="$(jq -r '.yubikeySerial' "$summary_path")"
      certificate_install_path="$(jq -r '.certificateInstallPath' "$summary_path")"
      archive_dir="$(jq -r '.archiveDirectory' "$summary_path")"
      certificate_fingerprint="$(jq -r '.certificate.sha256Fingerprint' "$summary_path")"

      show_info \
        "Provisioning Complete" \
        "Root YubiKey provisioning completed successfully.

YubiKey serial: $yubikey_serial
Certificate fingerprint: $certificate_fingerprint
Installed certificate: $certificate_install_path
Archived public artifacts: $archive_dir
Ceremony work directory: $work_dir
Secret files: $secret_dir

Next steps:
1. Export the public root inventory bundle from the archive directory.
2. Normalize and commit the inventory on the development machine.
3. Run verify-root-yubikey-identity before future root signing ceremonies."
    }

    main() {
      local credentials=""
      local root_pin=""
      local root_puk=""
      local root_management_key=""
      local session_timestamp=""
      local yubikey_serial=""
      local work_dir=""
      local secret_dir=""
      local pin_file=""
      local puk_file=""
      local management_key_file=""
      local dry_run_log=""
      local apply_log=""

      require_command jq
      require_command pd-pki-signing-tools
      require_command sudo
      require_command ykman
      require_command zenity
      require_command openssl
      [ -f "$profile_path" ] || {
        show_error "Missing Profile" "Provisioning profile not found:
$profile_path"
        exit 1
      }

      install -d -m 700 "$sessions_root" "$secrets_root"

      wait_for_usb_clear

      if ! confirm_step \
        "Confirm Destructive Operation" \
        "This Key Is Approved" \
        "Cancel" \
        "This operation will format the inserted YubiKey and replace any existing PIV material.

Continue only if this token is new in box or has been explicitly designated acceptable for this destroy-and-replace provisioning ceremony."; then
        exit 0
      fi

      credentials="$(generate_and_confirm_credentials)" || exit 0
      IFS=$'\t' read -r root_pin root_puk root_management_key <<EOF
$credentials
EOF

      yubikey_serial="$(wait_for_single_yubikey)"
      [ -n "$yubikey_serial" ] || {
        show_error "No YubiKey Detected" "The wizard could not determine a YubiKey serial."
        exit 1
      }

      session_timestamp="$(current_timestamp_utc)"
      work_dir="$sessions_root/root-$yubikey_serial-$session_timestamp"
      secret_dir="$secrets_root/root-yubikey-$yubikey_serial-$session_timestamp"
      pin_file="$secret_dir/root-pin.txt"
      puk_file="$secret_dir/root-puk.txt"
      management_key_file="$secret_dir/root-management-key.txt"
      dry_run_log="$work_dir/init-root-yubikey.dry-run.log"
      apply_log="$work_dir/init-root-yubikey.apply.log"

      install -d -m 700 "$work_dir" "$secret_dir"

      if ! run_command_with_progress \
        "Preparing Provisioning Plan" \
        "Generating the reviewed dry-run plan for YubiKey serial $yubikey_serial..." \
        "$dry_run_log" \
        pd-pki-signing-tools init-root-yubikey \
          --profile "$profile_path" \
          --yubikey-serial "$yubikey_serial" \
          --work-dir "$work_dir" \
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
        sudo -n pd-pki-signing-tools init-root-yubikey \
          --profile "$profile_path" \
          --yubikey-serial "$yubikey_serial" \
          --work-dir "$work_dir" \
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

      show_success_screen "$work_dir/root-yubikey-init-summary.json" "$secret_dir" "$work_dir"
    }

    main "$@"
  '';
}
