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
  ];

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
