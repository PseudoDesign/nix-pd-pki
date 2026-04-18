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
  planDir = "${toString cfg.workspaceDir}/plan";
  archiveDir = "${toString cfg.workspaceDir}/archive";
  rootInventoryBundleDir = "${toString cfg.bundleDir}/root-inventory";

  provisionCommand = pkgs.writeShellApplication {
    name = "pd-pki-root-provision";
    text = ''
      subcommand="''${1:-}"
      if [ -z "$subcommand" ]; then
        printf '%s\n' "usage: pd-pki-root-provision <dry-run|apply> [workflow flags]" >&2
        exit 2
      fi

      shift

      case "$subcommand" in
        dry-run)
          ${lib.optionalString cfg.liveHardware.enable ''
            pd-pki-live-token-state-export
          ''}
          exec ${lib.getExe' cfg.package "pd-pki-workflow"} root provision dry-run \
            --profile-dir ${lib.escapeShellArg (toString cfg.profileDir)} \
            --token-dir ${lib.escapeShellArg (toString cfg.tokenDir)} \
            --workspace-dir ${lib.escapeShellArg (toString cfg.workspaceDir)} \
            "$@"
          ;;
        apply)
          ${lib.optionalString cfg.liveHardware.enable ''
            pd-pki-live-token-state-export
            if [ "''${PD_PKI_ALLOW_FIXTURE_APPLY:-}" != "1" ]; then
              printf '%s\n' "live hardware mode does not yet implement destructive on-token provisioning" >&2
              printf '%s\n' "set PD_PKI_ALLOW_FIXTURE_APPLY=1 to run the current file-backed rehearsal against the captured live token state" >&2
              exit 1
            fi
          ''}
          exec ${lib.getExe' cfg.package "pd-pki-workflow"} root provision apply \
            --profile-dir ${lib.escapeShellArg (toString cfg.profileDir)} \
            --token-dir ${lib.escapeShellArg (toString cfg.tokenDir)} \
            --workspace-dir ${lib.escapeShellArg (toString cfg.workspaceDir)} \
            "$@"
          ;;
        *)
          printf '%s\n' "usage: pd-pki-root-provision <dry-run|apply> [workflow flags]" >&2
          exit 2
          ;;
      esac
    '';
  };

  inventoryExportCommand = pkgs.writeShellApplication {
    name = "pd-pki-root-inventory-export";
    text = ''
      exec ${lib.getExe' cfg.package "pd-pki-workflow"} root inventory export \
        --archive-dir ${lib.escapeShellArg archiveDir} \
        --bundle-dir ${lib.escapeShellArg rootInventoryBundleDir} \
        "$@"
    '';
  };
in
{
  imports = [ ./offline-root-ca-base.nix ];
  systemd.tmpfiles.rules = [
    "d ${planDir} 0700 ${cfg.user} ${cfg.group} - -"
    "d ${archiveDir} 0700 ${cfg.user} ${cfg.group} - -"
    "d ${rootInventoryBundleDir} 0700 ${cfg.user} ${cfg.group} - -"
  ];

  environment.shellInit = lib.mkAfter ''
    if [ "''${USER:-}" = ${lib.escapeShellArg operatorUser} ] && [ "''${HOME:-}" = ${lib.escapeShellArg operatorHome} ]; then
      export PD_PKI_PLAN_DIR=${lib.escapeShellArg planDir}
      export PD_PKI_ARCHIVE_DIR=${lib.escapeShellArg archiveDir}
      export PD_PKI_ROOT_INVENTORY_BUNDLE_DIR=${lib.escapeShellArg rootInventoryBundleDir}
    fi
  '';

  environment.systemPackages = [
    provisionCommand
    inventoryExportCommand
  ];

  environment.etc."motd".text = lib.mkForce ''
    Pseudo Design offline root YubiKey provisioner

    Suggested ceremony flow:
      1. Stage profile.json in ${toString cfg.profileDir}
      2. Run pd-pki-live-hardware-smoke and confirm the detected serial and slot
      3. Review the provisioning plan with: pd-pki-root-provision dry-run
      4. Use pd-pki-root-provision apply only for the current file-backed rehearsal
      5. Export the public inventory bundle with: pd-pki-root-inventory-export
      6. Normalize that bundle on the connected repository machine

    Runtime paths:
      plan: ${planDir}
      archive: ${archiveDir}
      root inventory bundle: ${rootInventoryBundleDir}
      token bridge: ${if cfg.liveHardware.enable then "pd-pki-live-token-state-export" else "disabled"}
      local GUI: http://127.0.0.1:${toString cfg.port}/gui
  '';

  system.nixos.tags = [ "root-yubikey-provisioner" ];
}
