{
  description = "PKI Infrastructure for Pseudo Design";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/25.11";
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
      toolingCheckNames = [
        "signing-tools-pkcs11"
        "signing-tools-root-yubikey-init"
      ];
      e2eCheckNames = [
        "e2e-root-yubikey-provisioning-contract"
        "e2e-root-yubikey-inventory-normalization"
        "e2e-root-yubikey-identity-verification"
        "e2e-root-intermediate-request-bundle-contract"
        "e2e-root-intermediate-signed-bundle-contract"
        "e2e-root-intermediate-airgap-handoff"
      ];
      checkNames =
        [
          "module-runtime-artifacts"
          "openvpn-daemon"
          "rpi5-root-ca-hardening"
          "role-topology"
          "pd-pki"
        ]
        ++ toolingCheckNames
        ++ e2eCheckNames
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

      rpi5RootYubiKeyProvisioner = nixos-raspberrypi.lib.nixosSystem {
        inherit nixpkgs;
        trustCaches = false;
        specialArgs = inputs // {
          inherit definitions nixosModules;
        };
        modules = [ ./systems/rpi5-root-yubikey-provisioner.nix ];
      };

      rpi5RootIntermediateSigner = nixos-raspberrypi.lib.nixosSystem {
        inherit nixpkgs;
        trustCaches = false;
        specialArgs = inputs // {
          inherit definitions nixosModules;
        };
        modules = [ ./systems/rpi5-root-intermediate-signer.nix ];
      };

      rpi5RootCa = rpi5RootYubiKeyProvisioner;
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
        // nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-linux") {
          rpi5-root-ca-sd-image = rpi5RootCa.config.system.build.sdImage;
          rpi5-root-yubikey-provisioner-sd-image = rpi5RootYubiKeyProvisioner.config.system.build.sdImage;
          rpi5-root-intermediate-signer-sd-image = rpi5RootIntermediateSigner.config.system.build.sdImage;
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
          inherit pkgs definitions packages nixosModules rpi5RootCa;
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
        rpi5-root-yubikey-provisioner = rpi5RootYubiKeyProvisioner;
        rpi5-root-intermediate-signer = rpi5RootIntermediateSigner;
      };
    };
}
