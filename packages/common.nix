{ pkgs, definitions }:
let
  inherit (pkgs.lib)
    concatMapStringsSep
    listToAttrs
    ;
in
rec {
  roleById = id: definitions.roleMap.${id};

  stepPackagesForRole =
    {
      role,
      rolePackage,
    }:
    listToAttrs (map (step: {
      name = "${role.id}-${step.id}";
      value = pkgs.runCommand "${role.id}-${step.id}" { } ''
        ln -s ${rolePackage}/steps/${step.id} "$out"
      '';
    }) role.steps);

  mkRolePackage =
    {
      role,
      buildScript,
      nativeBuildInputs ? [ ],
    }:
    let
      roleDefinition = pkgs.writeText "${role.id}-define.json" (builtins.toJSON role);
      stepsManifest = pkgs.writeText "${role.id}-steps.json" (builtins.toJSON (map (step: {
        inherit (step)
          id
          order
          title
          summary
          inputs
          outputs
          requiredFiles
          validations
          implementation
          ;
      }) role.steps));
      stepMetadataCommands = concatMapStringsSep "\n" (step:
        let
          defineFile = pkgs.writeText "${role.id}-${step.id}-define.json" (builtins.toJSON step);
          checksFile = pkgs.writeText "${role.id}-${step.id}-checks.json" (builtins.toJSON {
            inherit (step)
              requiredFiles
              validations
              implementation
              ;
          });
        in
        ''
          mkdir -p "$out/steps/${step.id}/artifacts"
          cp ${defineFile} "$out/steps/${step.id}/define.json"
          cp ${checksFile} "$out/steps/${step.id}/checks.json"
        ''
      ) role.steps;
    in
    pkgs.runCommand role.id { inherit nativeBuildInputs; } ''
      set -euo pipefail
      export PD_PKI_ROLE_ID='${role.id}'
      printf '%s\n' "[package/${role.id}] starting role package build"
      mkdir -p "$out/steps"
      cp ${roleDefinition} "$out/role.json"
      cp ${stepsManifest} "$out/steps.json"
      ${stepMetadataCommands}
      source ${./pki-workflow-lib.sh}
      ${buildScript}
      printf '%s\n' "[package/${role.id}] role package build passed"
    '';
}
