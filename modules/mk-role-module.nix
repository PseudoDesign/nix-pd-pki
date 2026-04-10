{
  roleId,
  optionName,
  packagePath,
}:
{ config, lib, pkgs, ... }:
let
  definitions = import ../packages/definitions.nix;
  role = definitions.roleMap.${roleId};
  optionPath = [
    "services"
    "pd-pki"
    "roles"
    optionName
  ];
  cfg = lib.getAttrFromPath optionPath config;
  defaultPackage = import packagePath {
    inherit pkgs definitions;
  };
in
{
  options = lib.setAttrByPath optionPath {
    enable = lib.mkEnableOption "${role.title} role artifacts";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = ''
        Package that provides the ${role.title} role artifacts and metadata.
      '';
    };

    installPackage = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to add the ${role.id} package to environment.systemPackages.
      '';
    };

    etcPath = lib.mkOption {
      type = lib.types.str;
      default = "pd-pki/${role.id}";
      description = ''
        Relative path under /etc where the role package should be exposed.
      '';
    };

    definition = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = role;
      description = ''
        Machine-readable role definition exported from packages/definitions.nix.
      '';
    };

    stepIds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = map (step: step.id) role.steps;
      description = ''
        Ordered step identifiers for the role workflow.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = lib.optionals cfg.installPackage [ cfg.package ];
    }
    (lib.setAttrByPath [
      "environment"
      "etc"
      cfg.etcPath
    ] {
      source = cfg.package;
    })
  ]);
}
