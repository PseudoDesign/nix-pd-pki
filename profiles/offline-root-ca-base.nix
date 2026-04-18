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
  ];

  environment.etc."motd".text = lib.mkDefault ''
    Pseudo Design offline root CA workstation

    Current app boundary:
      - local API and GUI on http://127.0.0.1:${toString cfg.port}/gui
      - workflow CLI via pd-pki-workflow
      - file-backed profile, token, workspace, bundle, and repository paths

    Runtime paths:
      profile: ${toString cfg.profileDir}
      token: ${toString cfg.tokenDir}
      workspace: ${toString cfg.workspaceDir}
      bundle: ${toString cfg.bundleDir}
      repository: ${toString cfg.repositoryRoot}
  '';

  system.nixos.tags = [ "offline-root-ca-base" ];
}
