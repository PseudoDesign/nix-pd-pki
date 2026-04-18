{
  config,
  lib,
  pkgs,
  pd-pki-python,
  pd-pki-package ? null,
  ...
}:
let
  cfg = config.services.pd-pki-workflow;
  defaultPackage =
    if pd-pki-package != null then
      pd-pki-package
    else
      pd-pki-python.packages.${pkgs.stdenv.hostPlatform.system}.pd-pki;
in
{
  options.services.pd-pki-workflow = {
    enable = lib.mkEnableOption "pd-pki workflow API";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "Package providing the pd-pki API and workflow entrypoints.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "pdpki";
      description = "User account that runs the pd-pki API service.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "pdpki";
      description = "Group that owns the pd-pki runtime state.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/pd-pki";
      description = "Top-level runtime state directory.";
    };

    profileDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/pd-pki/profile";
      description = "Directory containing root provisioning profiles.";
    };

    tokenDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/pd-pki/token";
      description = "Directory containing token exports or future adapters.";
    };

    liveHardware.enable = lib.mkEnableOption "bridging a live YubiKey into tokenDir artifacts";

    liveHardware.keySlot = lib.mkOption {
      type = lib.types.str;
      default = "9c";
      description = "PIV slot expected to hold the root key when exporting live hardware state.";
    };

    workspaceDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/pd-pki/workspace";
      description = "Directory for generated plan and archive artifacts.";
    };

    bundleDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/pd-pki/bundle";
      description = "Directory for transported request and inventory bundles.";
    };

    repositoryRoot = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/pd-pki/repository";
      description = "Directory holding normalized inventory and policy data.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Listen address for the pd-pki API service.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "TCP port for the pd-pki API service.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the configured API port in the firewall.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables passed to the pd-pki API service.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.group} = { };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = true;
    };

    systemd.tmpfiles.rules = [
      "d ${toString cfg.stateDir} 0700 ${cfg.user} ${cfg.group} - -"
      "d ${toString cfg.profileDir} 0700 ${cfg.user} ${cfg.group} - -"
      "d ${toString cfg.tokenDir} 0700 ${cfg.user} ${cfg.group} - -"
      "d ${toString cfg.workspaceDir} 0700 ${cfg.user} ${cfg.group} - -"
      "d ${toString cfg.bundleDir} 0700 ${cfg.user} ${cfg.group} - -"
      "d ${toString cfg.repositoryRoot} 0700 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.pd-pki-api = {
      description = "pd-pki workflow API";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = cfg.environment;

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        ExecStart = "${lib.getExe' cfg.package "pd-pki-api"} --host ${cfg.listenAddress} --port ${toString cfg.port}";
        Restart = "on-failure";
        RestartSec = 2;
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          cfg.stateDir
          cfg.profileDir
          cfg.tokenDir
          cfg.workspaceDir
          cfg.bundleDir
          cfg.repositoryRoot
        ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall [ cfg.port ];
  };
}
