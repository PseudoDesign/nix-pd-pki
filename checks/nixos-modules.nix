{
  pkgs,
  definitions,
  packages,
  nixosModules,
}:
let
  inherit (pkgs.lib)
    getAttrFromPath
    listToAttrs
    recursiveUpdate
    setAttrByPath
    ;

  roleOptionNames = {
    "root-certificate-authority" = "rootCertificateAuthority";
    "intermediate-signing-authority" = "intermediateSigningAuthority";
    "openvpn-server-leaf" = "openvpnServerLeaf";
    "openvpn-client-leaf" = "openvpnClientLeaf";
  };

  roleServiceNames = {
    "root-certificate-authority" = "pd-pki-root-certificate-authority-init";
    "intermediate-signing-authority" = "pd-pki-intermediate-signing-authority-init";
    "openvpn-server-leaf" = "pd-pki-openvpn-server-leaf-init";
    "openvpn-client-leaf" = "pd-pki-openvpn-client-leaf-init";
  };

  baseModule = { lib, ... }: {
    options.assertions = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
    };

    options.environment = {
      systemPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };

      etc = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule ({ lib, ... }: {
          options.source = lib.mkOption {
            type = lib.types.oneOf [
              lib.types.path
              lib.types.package
            ];
          };
        }));
        default = { };
      };
    };

    options.systemd = {
      services = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };

      timers = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
    };
  };

  enableRoleModule = role:
    let
      optionName = roleOptionNames.${role.id};
    in
    recursiveUpdate
      (setAttrByPath [
        "services"
        "pd-pki"
        "roles"
        optionName
        "enable"
      ] true)
      (setAttrByPath [
        "services"
        "pd-pki"
        "roles"
        optionName
        "installPackage"
      ] true);

  evalRoleModule = role:
    pkgs.lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        baseModule
        nixosModules.${role.id}
        (enableRoleModule role)
      ];
    };

  mkRoleModuleCheck = role:
    let
      optionName = roleOptionNames.${role.id};
      serviceName = roleServiceNames.${role.id};
      evaluated = evalRoleModule role;
      cfg = getAttrFromPath [
        "services"
        "pd-pki"
        "roles"
        optionName
      ] evaluated.config;
      etcSource = getAttrFromPath [
        "environment"
        "etc"
        "pd-pki/${role.id}"
        "source"
      ] evaluated.config;
      yubiKeyProfileSource =
        if role.id == "root-certificate-authority" then
          getAttrFromPath [
            "environment"
            "etc"
            cfg.yubiKeyProfileEtcPath
            "source"
          ] evaluated.config
        else
          null;
      runtimePathDirectory = cfg.runtimePaths.directory;
      packagePaths = map toString evaluated.config.environment.systemPackages;
      expectedPackage = toString packages.${role.id};
      expectedSteps = map (step: step.id) role.steps;
      checksPassed =
        cfg.enable
        && cfg.definition.id == role.id
        && cfg.stepIds == expectedSteps
        && toString cfg.package == expectedPackage
        && toString etcSource == expectedPackage
        && builtins.match "/var/lib/pd-pki/.*" runtimePathDirectory != null
        && (if role.id == "root-certificate-authority" then
          cfg.yubiKeyProfile.roleId == role.id
          && cfg.yubiKeyProfilePath == "/etc/${cfg.yubiKeyProfileEtcPath}"
          && yubiKeyProfileSource != null
        else
          true)
        && builtins.hasAttr serviceName evaluated.config.systemd.services
        && builtins.elem expectedPackage packagePaths;
    in
    {
      name = "nixos-module-${role.id}";
      value =
        assert checksPassed;
        pkgs.runCommand "nixos-module-${role.id}-check" { } ''
          touch "$out"
        '';
    };

  enableAllRoles =
    builtins.foldl'
      recursiveUpdate
      { }
      (map enableRoleModule definitions.roles);

  evaluatedDefaultModule = pkgs.lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      baseModule
      nixosModules.default
      enableAllRoles
    ];
  };

  evaluatedLegacyRootAliasModule = pkgs.lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      baseModule
      nixosModules.root-certificate-authority
      (enableRoleModule definitions.roleMap."root-certificate-authority")
      {
        services.pd-pki.roles.rootCertificateAuthority.yubiKey.subject = "/CN=Legacy Alias Root CA";
        services.pd-pki.roles.rootCertificateAuthority.yubiKey.validityDays = 7300;
        services.pd-pki.roles.rootCertificateAuthority.yubiKey.slot = "9c";
        services.pd-pki.roles.rootCertificateAuthority.yubiKey.archiveBaseDirectory =
          "/var/lib/pd-pki/legacy-yubikey-inventory";
      }
    ];
  };

  legacyRootAliasChecksPassed =
    let
      cfg = getAttrFromPath [
        "services"
        "pd-pki"
        "roles"
        "rootCertificateAuthority"
      ] evaluatedLegacyRootAliasModule.config;
    in
    cfg.ceremony.subject == "/CN=Legacy Alias Root CA"
    && cfg.ceremony.validityDays == 7300
    && cfg.ceremony.key.slot == "9c"
    && cfg.ceremony.outputs.archiveBaseDirectory == "/var/lib/pd-pki/legacy-yubikey-inventory"
    && cfg.yubiKeyProfile.subject == "/CN=Legacy Alias Root CA"
    && cfg.yubiKeyProfile.validityDays == 7300;

  defaultModuleChecksPassed =
    builtins.all
      (role:
        let
          optionName = roleOptionNames.${role.id};
          cfg = getAttrFromPath [
            "services"
            "pd-pki"
            "roles"
            optionName
          ] evaluatedDefaultModule.config;
          etcSource = getAttrFromPath [
            "environment"
            "etc"
            "pd-pki/${role.id}"
            "source"
          ] evaluatedDefaultModule.config;
          yubiKeyProfileSource =
            if role.id == "root-certificate-authority" then
              getAttrFromPath [
                "environment"
                "etc"
                cfg.yubiKeyProfileEtcPath
                "source"
              ] evaluatedDefaultModule.config
            else
              null;
          serviceName = roleServiceNames.${role.id};
        in
        cfg.enable
        && toString etcSource == toString packages.${role.id}
        && builtins.match "/var/lib/pd-pki/.*" cfg.runtimePaths.directory != null
        && (if role.id == "root-certificate-authority" then
          cfg.yubiKeyProfile.roleId == role.id
          && cfg.yubiKeyProfilePath == "/etc/${cfg.yubiKeyProfileEtcPath}"
          && yubiKeyProfileSource != null
        else
          true)
        && builtins.hasAttr serviceName evaluatedDefaultModule.config.systemd.services
      )
      definitions.roles;
in
listToAttrs (
  [
    {
      name = "nixos-module-default";
      value =
        assert defaultModuleChecksPassed;
        pkgs.runCommand "nixos-module-default-check" { } ''
          touch "$out"
        '';
    }
    {
      name = "nixos-module-root-certificate-authority-legacy-aliases";
      value =
        assert legacyRootAliasChecksPassed;
        pkgs.runCommand "nixos-module-root-certificate-authority-legacy-aliases-check" { } ''
          touch "$out"
        '';
    }
  ]
  ++ map mkRoleModuleCheck definitions.roles
)
