{
  pkgs,
  definitions,
  packages,
  nixosModules,
}:
let
  inherit (pkgs.lib)
    concatMapStringsSep
    listToAttrs
    setAttrByPath
    ;

  helpers = import ./common.nix {
    inherit pkgs;
    packages = { };
  };

  roleNodeConfig = {
    "root-certificate-authority" = {
      nodeName = "root";
      optionName = "rootCertificateAuthority";
    };
    "intermediate-signing-authority" = {
      nodeName = "intermediate";
      optionName = "intermediateSigningAuthority";
    };
    "openvpn-server-leaf" = {
      nodeName = "server";
      optionName = "openvpnServerLeaf";
    };
    "openvpn-client-leaf" = {
      nodeName = "client";
      optionName = "openvpnClientLeaf";
    };
  };

  mkRoleNode = role:
    let
      roleConfig = roleNodeConfig.${role.id};
    in
    {
      name = roleConfig.nodeName;
      value =
        { lib, pkgs, ... }:
        {
          imports = [ nixosModules.${role.id} ];

          networking.hostName = roleConfig.nodeName;
          environment.systemPackages = [
            pkgs.jq
            pkgs.openssl
          ];
          system.stateVersion = lib.mkDefault "24.11";
        }
        // setAttrByPath [
          "services"
          "pd-pki"
          "roles"
          roleConfig.optionName
          "enable"
        ] true
        // setAttrByPath [
          "services"
          "pd-pki"
          "roles"
          roleConfig.optionName
          "installPackage"
        ] true;
    };

  roleScript = role:
    let
      rolePath = toString packages.${role.id};
    in
    pkgs.writeShellScript "check-${role.id}" ''
      set -euo pipefail
      ${helpers.roleCheckCommands role rolePath}
    '';

  stepScript = role: step:
    let
      stepPath = "${packages.${role.id}}/steps/${step.id}";
    in
    pkgs.writeShellScript "check-${role.id}-${step.id}" ''
      set -euo pipefail
      ${helpers.stepCheckCommands role step stepPath}
    '';

  topologyTest = pkgs.testers.runNixOSTest {
    name = "pd-pki-role-topology";
    nodes = listToAttrs (map mkRoleNode definitions.roles);

    testScript =
      let
        bootCommands = concatMapStringsSep "\n" (role:
          let
            roleConfig = roleNodeConfig.${role.id};
          in
          ''
            ${roleConfig.nodeName}.wait_for_unit("multi-user.target")
          ''
        ) definitions.roles;

        validationCommands = concatMapStringsSep "\n" (role:
          let
            roleConfig = roleNodeConfig.${role.id};
            roleChecks = ''
              ${roleConfig.nodeName}.succeed(${builtins.toJSON (toString (roleScript role))})
            '';
            stepChecks = concatMapStringsSep "\n" (step: ''
              ${roleConfig.nodeName}.succeed(${builtins.toJSON (toString (stepScript role step))})
            '') role.steps;
          in
          ''
            ${roleChecks}
            ${stepChecks}
          ''
        ) definitions.roles;
      in
      # python
      ''
        start_all()
        ${bootCommands}
        ${validationCommands}
      '';
  };

  checkNames =
    map (role: role.id) definitions.roles
    ++ builtins.concatLists (map (role: map (step: "${role.id}-${step.id}") role.steps) definitions.roles);
in
listToAttrs (map (name: {
  inherit name;
  value = topologyTest;
}) checkNames)
