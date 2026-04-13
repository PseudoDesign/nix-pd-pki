{
  description = "PKI Infrastructure for Pseudo Design";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, nixos-raspberrypi, ... }:
    let
      definitions = import ./packages/definitions.nix;
      nixosModules = import ./modules;
      moduleCheckNames =
        [ "nixos-module-default" ]
        ++ map (role: "nixos-module-${role.id}") definitions.roles;
      checkNames =
        [
          "module-runtime-artifacts"
          "openvpn-daemon"
          "role-topology"
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

      rpi5RootCa = nixos-raspberrypi.lib.nixosSystem {
        inherit nixpkgs;
        trustCaches = false;
        specialArgs = inputs // {
          inherit definitions nixosModules;
        };
        modules = [ ./systems/rpi5-root-ca.nix ];
      };
    in
    {
      inherit nixosModules;

      lib = {
        inherit definitions;
        roles = definitions.roleMap;
        roleCount = definitions.roleCount;
        stepCount = definitions.stepCount;
        inherit checkNames;
      };

      packages = forAllSystems (
        pkgs:
        let
          localPackages = import ./packages {
            inherit pkgs definitions;
          };
        in
        localPackages
        // nixpkgs.lib.optionalAttrs (pkgs.system == "aarch64-linux") {
          rpi5-root-ca-sd-image = rpi5RootCa.config.system.build.sdImage;
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
          packages = import ./packages {
            inherit pkgs definitions;
          };
          appPackages = import ./apps {
            inherit pkgs definitions checkNames packages;
          };
        in
        {
          pd-pki-operator = {
            type = "app";
            program = "${appPackages.pdPkiOperator}/bin/pd-pki-operator";
            meta = {
              description = "Run the interactive PKI operator wizard for USB-guided request export, signing, import, and CRL handoff.";
            };
          };
          test-report = {
            type = "app";
            program = "${appPackages.testReport}/bin/test-report";
            meta = {
              description = "Run all exported pd-pki checks and write Markdown/JSON test reports.";
            };
          };
        }
      );

      nixosConfigurations = {
        rpi5-root-ca = rpi5RootCa;
      };
    };
}
