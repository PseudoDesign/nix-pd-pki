{
  description = "PKI Infrastructure for Pseudo Design";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      definitions = import ./packages/definitions.nix;
      nixosModules = import ./modules;
      moduleCheckNames =
        [ "nixos-module-default" ]
        ++ map (role: "nixos-module-${role.id}") definitions.roles;
      checkNames =
        [
          "define-contract"
          "pd-pki"
        ]
        ++ map (role: role.id) definitions.roles
        ++ builtins.concatLists (map (role: map (step: "${role.id}-${step.id}") role.steps) definitions.roles)
        ++ moduleCheckNames;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      define = definitions;

      inherit nixosModules;

      lib = {
        roles = definitions.roleMap;
        roleCount = definitions.roleCount;
        stepCount = definitions.stepCount;
        inherit checkNames;
      };

      packages = forAllSystems (
        pkgs:
        import ./packages {
          inherit pkgs definitions;
        }
      );

      checks = forAllSystems (
        pkgs:
        let
          packages = import ./packages {
            inherit pkgs definitions;
          };
        in
        import ./checks {
          inherit pkgs definitions packages nixosModules;
        }
      );

      apps = forAllSystems (
        pkgs:
        let
          appPackages = import ./apps {
            inherit pkgs definitions checkNames;
          };
        in
        {
          test-report = {
            type = "app";
            program = "${appPackages.testReport}/bin/test-report";
          };
        }
      );
    };
}
