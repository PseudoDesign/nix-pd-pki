{
  pkgs,
  nixpkgs,
  pd-pki-python,
  pd-pki-package,
}:
let
  lib = nixpkgs.lib;

  evaluated = lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit pd-pki-python;
      inherit pd-pki-package;
    };
    modules = [ ../systems/hardware-lab.nix ];
  };

  cfg = evaluated.config.services.pd-pki-workflow;
  service = evaluated.config.systemd.services.pd-pki-api;
  user = evaluated.config.users.users.${cfg.user};
  serviceEnvironment = service.environment;

  readWritePaths = map toString service.serviceConfig.ReadWritePaths;
  expectedReadWritePaths = map toString [
    cfg.stateDir
    cfg.profileDir
    cfg.tokenDir
    cfg.workspaceDir
    cfg.bundleDir
    cfg.repositoryRoot
  ];

  summary = builtins.toJSON {
    user = cfg.user;
    group = cfg.group;
    listenAddress = cfg.listenAddress;
    port = cfg.port;
    workingDirectory = toString service.serviceConfig.WorkingDirectory;
    execStart = service.serviceConfig.ExecStart;
    webRootName = serviceEnvironment.PD_PKI_WEB_ROOT_NAME;
    readWritePaths = readWritePaths;
  };
in
assert cfg.enable;
assert user.isSystemUser;
assert toString user.home == toString cfg.stateDir;
assert service.wantedBy == [ "multi-user.target" ];
assert service.serviceConfig.User == cfg.user;
assert service.serviceConfig.Group == cfg.group;
assert serviceEnvironment.PD_PKI_WEB_LOCK_CONFIG == "1";
assert serviceEnvironment.PD_PKI_WEB_WORKFLOW_ROOT == toString cfg.stateDir;
assert serviceEnvironment.PD_PKI_WEB_PROFILE_DIR == toString cfg.profileDir;
assert serviceEnvironment.PD_PKI_WEB_TOKEN_DIR == toString cfg.tokenDir;
assert serviceEnvironment.PD_PKI_WEB_WORKSPACE_DIR == toString cfg.workspaceDir;
assert serviceEnvironment.PD_PKI_WEB_BUNDLE_DIR == toString cfg.bundleDir;
assert serviceEnvironment.PD_PKI_WEB_REPOSITORY_ROOT == toString cfg.repositoryRoot;
assert serviceEnvironment.PD_PKI_WEB_ROOT_NAME == cfg.web.rootName;
assert builtins.all (path: builtins.elem path readWritePaths) expectedReadWritePaths;
pkgs.runCommand "pd-pki-module-eval" { } ''
  cat > "$out" <<'EOF'
  ${summary}
  EOF
''
