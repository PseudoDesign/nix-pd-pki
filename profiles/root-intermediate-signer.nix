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
  requestBundleDir = "${toString cfg.bundleDir}/request";
  signedBundleDir = "${toString cfg.bundleDir}/signed";
  inventoryRootDir = "${toString cfg.repositoryRoot}/inventory/root-ca";
  policyDir = "${toString cfg.repositoryRoot}/policy/intermediate-ca";

  verifyInventoryCommand = pkgs.writeShellApplication {
    name = "pd-pki-root-inventory-verify";
    text = ''
      root_name="''${1:-}"
      if [ -z "$root_name" ]; then
        printf '%s\n' "usage: pd-pki-root-inventory-verify <root-name>" >&2
        exit 2
      fi

      exec ${lib.getExe' cfg.package "pd-pki-workflow"} root inventory verify \
        --repository-root ${lib.escapeShellArg (toString cfg.repositoryRoot)} \
        --root-name "$root_name" \
        --token-dir ${lib.escapeShellArg (toString cfg.tokenDir)}
    '';
  };

  signIntermediateCommand = pkgs.writeShellApplication {
    name = "pd-pki-root-sign-intermediate";
    text = ''
      root_name="''${1:-}"
      request_bundle_dir="''${2:-${requestBundleDir}}"
      signed_bundle_dir="''${3:-${signedBundleDir}}"

      if [ -z "$root_name" ]; then
        printf '%s\n' "usage: pd-pki-root-sign-intermediate <root-name> [request-bundle-dir] [signed-bundle-dir]" >&2
        exit 2
      fi

      exec ${lib.getExe' cfg.package "pd-pki-workflow"} request sign \
        --repository-root ${lib.escapeShellArg (toString cfg.repositoryRoot)} \
        --root-name "$root_name" \
        --token-dir ${lib.escapeShellArg (toString cfg.tokenDir)} \
        --request-bundle-dir "$request_bundle_dir" \
        --signed-bundle-dir "$signed_bundle_dir"
    '';
  };
in
{
  imports = [ ./offline-root-ca-base.nix ];
  systemd.tmpfiles.rules = [
    "d ${requestBundleDir} 0700 ${cfg.user} ${cfg.group} - -"
    "d ${signedBundleDir} 0700 ${cfg.user} ${cfg.group} - -"
    "d ${toString cfg.repositoryRoot}/inventory 0700 ${cfg.user} ${cfg.group} - -"
    "d ${inventoryRootDir} 0700 ${cfg.user} ${cfg.group} - -"
    "d ${toString cfg.repositoryRoot}/policy 0700 ${cfg.user} ${cfg.group} - -"
    "d ${policyDir} 0700 ${cfg.user} ${cfg.group} - -"
  ];

  environment.shellInit = lib.mkAfter ''
    if [ "''${USER:-}" = ${lib.escapeShellArg operatorUser} ] && [ "''${HOME:-}" = ${lib.escapeShellArg operatorHome} ]; then
      export PD_PKI_REQUEST_BUNDLE_DIR=${lib.escapeShellArg requestBundleDir}
      export PD_PKI_SIGNED_BUNDLE_DIR=${lib.escapeShellArg signedBundleDir}
      export PD_PKI_ROOT_INVENTORY_DIR=${lib.escapeShellArg inventoryRootDir}
      export PD_PKI_INTERMEDIATE_POLICY_DIR=${lib.escapeShellArg policyDir}
    fi
  '';

  environment.systemPackages = [
    verifyInventoryCommand
    signIntermediateCommand
  ];

  environment.etc."motd".text = lib.mkForce ''
    Pseudo Design offline root intermediate signer

    Suggested ceremony flow:
      1. Copy committed root inventory into ${inventoryRootDir}
      2. Copy the intermediate signer policy into ${policyDir}
      3. Stage token identity artifacts in ${toString cfg.tokenDir}
      4. Stage the incoming request bundle in ${requestBundleDir}
      5. Verify the inserted root token with: pd-pki-root-inventory-verify <root-name>
      6. Sign the request with: pd-pki-root-sign-intermediate <root-name>
      7. Return the signed bundle from ${signedBundleDir} to removable media

    Runtime paths:
      request bundle: ${requestBundleDir}
      signed bundle: ${signedBundleDir}
      local GUI: http://127.0.0.1:${toString cfg.port}/gui
  '';

  system.nixos.tags = [ "root-intermediate-signer" ];
}
