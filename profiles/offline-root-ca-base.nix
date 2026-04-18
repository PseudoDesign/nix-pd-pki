{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pd-pki-workflow;
  operatorUser = cfg.user;
  operatorHome = toString cfg.stateDir;
  liveHardwareEnabled = cfg.liveHardware.enable;
  liveHardwareSlot = cfg.liveHardware.keySlot;
  managedProvisioningInputsEnabled =
    liveHardwareEnabled && cfg.liveHardware.managedProvisioningInputs.enable;
  managedProvisioningContractVersion = cfg.liveHardware.managedProvisioningInputs.contractVersion;
  managedProvisioningSyncInterval = cfg.liveHardware.managedProvisioningInputs.syncInterval;

  liveHardwareShell = ''
    set -euo pipefail

    slot=${lib.escapeShellArg liveHardwareSlot}

    fail() {
      printf '%s\n' "$1" >&2
      exit 1
    }

    detect_single_serial() {
      local serials=()
      mapfile -t serials < <(ykman list --serials)

      if [ "''${#serials[@]}" -eq 0 ]; then
        fail "no YubiKey detected; insert exactly one approved token"
      fi

      if [ "''${#serials[@]}" -ne 1 ]; then
        fail "expected exactly one YubiKey, found ''${#serials[@]}"
      fi

      printf '%s\n' "''${serials[0]}"
    }

    export_slot_certificate() {
      local certificate_path="$1"
      ykman piv certificates export "$slot" "$certificate_path" >/dev/null 2>&1
    }

    export_attestation_certificate() {
      local certificate_path="$1"
      ykman piv keys attest "$slot" "$certificate_path" >/dev/null 2>&1
    }
  '';

  liveHardwareSmokeCommand = pkgs.writeShellApplication {
    name = "pd-pki-live-hardware-smoke";
    runtimeInputs = with pkgs; [
      coreutils
      yubico-piv-tool
      yubikey-manager
    ];
    text = ''
      ${liveHardwareShell}

      serial="$(detect_single_serial)"
      tmp_dir="$(mktemp -d)"
      trap 'rm -rf "$tmp_dir"' EXIT

      certificate_status="missing"
      attestation_status="not-attempted"

      if export_slot_certificate "$tmp_dir/root_certificate.pem"; then
        certificate_status="present"
        if export_attestation_certificate "$tmp_dir/attestation-certificate.pem"; then
          attestation_status="present"
        else
          attestation_status="unavailable"
        fi
      fi

      printf '%s\n' "Detected YubiKey serial: $serial"
      printf '%s\n' "Configured PIV slot: $slot"
      printf '%s\n' "Certificate in slot: $certificate_status"
      printf '%s\n' "Attestation certificate export: $attestation_status"
      printf '\n%s\n' "Available smart card readers:"
      ykman list --readers || true
      printf '\n%s\n' "PIV status:"
      exec yubico-piv-tool -a status
    '';
  };

  liveTokenStateExportCommand = pkgs.writeShellApplication {
    name = "pd-pki-live-token-state-export";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      yubikey-manager
    ];
    text = ''
      ${liveHardwareShell}

      token_dir=${lib.escapeShellArg (toString cfg.tokenDir)}
      serial="$(detect_single_serial)"
      tmp_dir="$(mktemp -d)"
      trap 'rm -rf "$tmp_dir"' EXIT

      install -d -m 700 "$token_dir"

      initialized=false
      attestation_certificate_status="not-exported"

      if export_slot_certificate "$tmp_dir/root_certificate.pem"; then
        initialized=true
        install -m 600 "$tmp_dir/root_certificate.pem" "$token_dir/root_certificate.pem"

        if export_attestation_certificate "$tmp_dir/attestation-certificate.pem"; then
          install -m 600 "$tmp_dir/attestation-certificate.pem" "$token_dir/attestation-certificate.pem"
          attestation_certificate_status="exported"
        else
          rm -f "$token_dir/attestation-certificate.pem"
          attestation_certificate_status="unavailable"
        fi

        jq -n \
          --arg slot "$slot" \
          --arg serial "$serial" \
          --arg attestation_certificate "$attestation_certificate_status" \
          --arg source "live-yubikey" \
          '{
            attested_slot: $slot,
            device_serial: $serial,
            attestation_certificate: $attestation_certificate,
            source: $source
          }' > "$tmp_dir/attestation.json"
        install -m 600 "$tmp_dir/attestation.json" "$token_dir/attestation.json"
      else
        rm -f \
          "$token_dir/root_certificate.pem" \
          "$token_dir/attestation.json" \
          "$token_dir/attestation-certificate.pem"
      fi

      jq -n \
        --arg serial "$serial" \
        --arg slot "$slot" \
        --arg source "live-yubikey" \
        --argjson initialized "$initialized" \
        '{
          device_serial: $serial,
          key_slot: $slot,
          initialized: $initialized,
          fail_attestation: false,
          source: $source
        }' > "$tmp_dir/token_state.json"
      install -m 600 "$tmp_dir/token_state.json" "$token_dir/token_state.json"

      printf '%s\n' "synchronized live token state into $token_dir"
      if [ "$initialized" = true ]; then
        printf '%s\n' "slot $slot currently contains a certificate"
      else
        printf '%s\n' "slot $slot does not currently contain a certificate"
      fi
    '';
  };

  liveProvisionerInputSyncCommand = pkgs.writeShellApplication {
    name = "pd-pki-live-provisioner-input-sync";
    runtimeInputs = with pkgs; [
      coreutils
      jq
    ];
    text = ''
      set -euo pipefail

      profile_dir=${lib.escapeShellArg (toString cfg.profileDir)}
      token_dir=${lib.escapeShellArg (toString cfg.tokenDir)}
      root_name=${lib.escapeShellArg cfg.web.rootName}
      slot=${lib.escapeShellArg liveHardwareSlot}
      contract_version=${lib.escapeShellArg managedProvisioningContractVersion}
      tmp_dir="$(mktemp -d)"
      trap 'rm -rf "$tmp_dir"' EXIT

      install -d -m 700 "$profile_dir" "$token_dir"

      clear_managed_inputs() {
        rm -f \
          "$profile_dir/profile.json" \
          "$token_dir/token_state.json" \
          "$token_dir/root_certificate.pem" \
          "$token_dir/attestation.json" \
          "$token_dir/attestation-certificate.pem"
      }

      if ! ${lib.getExe liveTokenStateExportCommand} >/dev/null 2>&1; then
        clear_managed_inputs
        printf '%s\n' "live hardware input sync is not ready; cleared managed provisioning inputs"
        exit 0
      fi

      serial="$(jq -re '.device_serial' "$token_dir/token_state.json")"
      certificate_source="$token_dir/root_certificate.pem"

      if [ ! -f "$certificate_source" ]; then
        certificate_source="$tmp_dir/root_certificate.pem"
        cat > "$certificate_source" <<EOF
-----BEGIN CERTIFICATE-----
PENDING-$root_name
-----END CERTIFICATE-----
EOF
      fi

      jq -n \
        --arg contract_version "$contract_version" \
        --arg expected_serial "$serial" \
        --arg key_slot "$slot" \
        --arg root_name "$root_name" \
        --rawfile certificate_pem "$certificate_source" \
        '{
          certificate_pem: $certificate_pem,
          contract_version: $contract_version,
          expected_serial: $expected_serial,
          key_slot: $key_slot,
          root_name: $root_name
        }' > "$tmp_dir/profile.json"
      install -m 600 "$tmp_dir/profile.json" "$profile_dir/profile.json"

      printf '%s\n' "synchronized managed provisioning inputs into $profile_dir and $token_dir"
    '';
  };

  liveRootIdentityExportCommand = pkgs.writeShellApplication {
    name = "pd-pki-live-root-identity-export";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      yubikey-manager
    ];
    text = ''
      ${liveHardwareShell}

      token_dir=${lib.escapeShellArg (toString cfg.tokenDir)}
      serial="$(detect_single_serial)"
      tmp_dir="$(mktemp -d)"
      trap 'rm -rf "$tmp_dir"' EXIT

      install -d -m 700 "$token_dir"

      if ! export_slot_certificate "$tmp_dir/root_certificate.pem"; then
        fail "no certificate found in PIV slot $slot; cannot export root identity"
      fi

      if ! export_attestation_certificate "$tmp_dir/attestation-certificate.pem"; then
        fail "could not export an attestation certificate for slot $slot; the key may not have been generated on this YubiKey"
      fi

      install -m 600 "$tmp_dir/root_certificate.pem" "$token_dir/root_certificate.pem"
      install -m 600 "$tmp_dir/attestation-certificate.pem" "$token_dir/attestation-certificate.pem"

      jq -n \
        --arg slot "$slot" \
        --arg serial "$serial" \
        --arg source "live-yubikey" \
        '{
          attested_slot: $slot,
          device_serial: $serial,
          attestation_certificate: "exported",
          source: $source
        }' > "$tmp_dir/attestation.json"
      install -m 600 "$tmp_dir/attestation.json" "$token_dir/attestation.json"

      printf '%s\n' "exported live root identity into $token_dir"
    '';
  };
in
{
  imports = [ ../modules/pd-pki-workflow.nix ];
  assertions = [
    {
      assertion = !cfg.liveHardware.managedProvisioningInputs.enable || liveHardwareEnabled;
      message = "managed live root provisioning inputs require services.pd-pki-workflow.liveHardware.enable = true";
    }
  ];
  services.pd-pki-workflow = {
    enable = true;
    listenAddress = lib.mkDefault "127.0.0.1";
    port = lib.mkDefault 8000;
  };

  services.getty.autologinUser = lib.mkDefault operatorUser;
  services.pcscd.enable = true;

  users.users.${operatorUser} = {
    shell = pkgs.bashInteractive;
    extraGroups = [ "wheel" ];
  };

  security.sudo.wheelNeedsPassword = false;

  environment.shellInit = lib.mkAfter ''
    if [ "''${USER:-}" = ${lib.escapeShellArg operatorUser} ] && [ "''${HOME:-}" = ${lib.escapeShellArg operatorHome} ]; then
      umask 077
      export PD_PKI_STATE_DIR=${lib.escapeShellArg (toString cfg.stateDir)}
      export PD_PKI_PROFILE_DIR=${lib.escapeShellArg (toString cfg.profileDir)}
      export PD_PKI_TOKEN_DIR=${lib.escapeShellArg (toString cfg.tokenDir)}
      export PD_PKI_WORKSPACE_DIR=${lib.escapeShellArg (toString cfg.workspaceDir)}
      export PD_PKI_BUNDLE_DIR=${lib.escapeShellArg (toString cfg.bundleDir)}
      export PD_PKI_REPOSITORY_ROOT=${lib.escapeShellArg (toString cfg.repositoryRoot)}
      export PD_PKI_LOCAL_GUI_URL=${lib.escapeShellArg "http://127.0.0.1:${toString cfg.port}/gui"}
      export PD_PKI_LIVE_HARDWARE=${lib.escapeShellArg (if liveHardwareEnabled then "1" else "0")}
      export PD_PKI_PIV_SLOT=${lib.escapeShellArg liveHardwareSlot}
    fi
  '';

  environment.systemPackages = [
    cfg.package
    pkgs.curl
    pkgs.git
    pkgs.jq
    pkgs.opensc
    pkgs.openssl
    pkgs.tmux
    pkgs.tree
    pkgs.yubico-piv-tool
    pkgs.yubikey-manager
  ]
  ++ lib.optionals liveHardwareEnabled [
    liveHardwareSmokeCommand
    liveTokenStateExportCommand
    liveRootIdentityExportCommand
  ]
  ++ lib.optionals managedProvisioningInputsEnabled [ liveProvisionerInputSyncCommand ];

  systemd.services.pd-pki-api = lib.mkIf managedProvisioningInputsEnabled {
    wants = [ "pd-pki-live-provisioner-input-sync.service" ];
    after = [ "pd-pki-live-provisioner-input-sync.service" ];
  };

  systemd.services.pd-pki-live-provisioner-input-sync = lib.mkIf managedProvisioningInputsEnabled {
    description = "Synchronize managed root provisioning inputs from live hardware";
    before = [ "pd-pki-api.service" ];
    after = [ "pcscd.service" ];
    wants = [ "pcscd.service" ];

    serviceConfig = {
      Type = "oneshot";
      User = cfg.user;
      Group = cfg.group;
      WorkingDirectory = cfg.stateDir;
      ExecStart = lib.getExe liveProvisionerInputSyncCommand;
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [
        cfg.profileDir
        cfg.tokenDir
      ];
    };
  };

  systemd.timers.pd-pki-live-provisioner-input-sync = lib.mkIf managedProvisioningInputsEnabled {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5s";
      OnUnitActiveSec = managedProvisioningSyncInterval;
      Unit = "pd-pki-live-provisioner-input-sync.service";
    };
  };

  environment.etc."motd".text = lib.mkDefault ''
    Pseudo Design offline root CA workstation

    Current app boundary:
      - local API and GUI on http://127.0.0.1:${toString cfg.port}/gui
      - workflow CLI via pd-pki-workflow
      - file-backed profile, token, workspace, bundle, and repository paths
      - live hardware bridge: ${if liveHardwareEnabled then "enabled" else "disabled"}

    Runtime paths:
      profile: ${toString cfg.profileDir}
      token: ${toString cfg.tokenDir}
      workspace: ${toString cfg.workspaceDir}
      bundle: ${toString cfg.bundleDir}
      repository: ${toString cfg.repositoryRoot}

    Live hardware:
      slot: ${liveHardwareSlot}
      smoke test: ${if liveHardwareEnabled then "pd-pki-live-hardware-smoke" else "disabled"}
  '';

  system.nixos.tags = [
    "offline-root-ca-base"
  ]
  ++ lib.optionals liveHardwareEnabled [ "live-hardware-bridge" ];
}
