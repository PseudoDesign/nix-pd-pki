{
  description = "NixOS integration for the pd-pki Python workflow application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/25.11";
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pd-pki-python = {
      url = "github:PseudoDesign/pd-pki-python";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixos-raspberrypi, pd-pki-python, ... }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      mkPkgs = system: import nixpkgs { inherit system; };

      forAllSystems = f:
        lib.genAttrs supportedSystems (system: f (mkPkgs system));

      nixosModules = import ./modules;

      mkPdPkiPackage =
        pkgs:
        pd-pki-python.packages.${pkgs.stdenv.hostPlatform.system}.pd-pki.overrideAttrs
          (old: {
            postPatch = (old.postPatch or "") + ''
              substituteInPlace src/pd_pki_workflow/api.py \
                --replace-fail "HTTP_422_UNPROCESSABLE_CONTENT" "HTTP_422_UNPROCESSABLE_ENTITY"
              substituteInPlace src/pd_pki_workflow/mock_api.py \
                --replace-fail "HTTP_422_UNPROCESSABLE_CONTENT" "HTTP_422_UNPROCESSABLE_ENTITY"
            '';
          });

      mkSpecialArgs = pkgs: {
        inherit nixos-raspberrypi pd-pki-python;
        pd-pki-package = mkPdPkiPackage pkgs;
      };

      mkApp = package: program: description: {
        type = "app";
        program = "${package}/bin/${program}";
        meta = {
          inherit description;
        };
      };

      mkSystem =
        system: modules:
        let
          pkgs = mkPkgs system;
        in
        lib.nixosSystem {
          inherit system modules;
          specialArgs = mkSpecialArgs pkgs;
        };

      mkRpi5System =
        modules:
        nixos-raspberrypi.lib.nixosSystem {
          inherit nixpkgs;
          trustCaches = false;
          specialArgs = mkSpecialArgs (mkPkgs "aarch64-linux");
          inherit modules;
        };

      rpi5RootYubiKeyProvisioner = mkRpi5System [ ./systems/rpi5-root-yubikey-provisioner.nix ];
      rpi5RootIntermediateSigner = mkRpi5System [ ./systems/rpi5-root-intermediate-signer.nix ];
    in
    {
      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);

      packages = forAllSystems (
        pkgs:
        let
          package = mkPdPkiPackage pkgs;
        in
        {
          default = package;
          pd-pki = package;
        }
        // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-linux") {
          rpi5-root-yubikey-provisioner-sd-image =
            rpi5RootYubiKeyProvisioner.config.system.build.sdImage;
          rpi5-root-intermediate-signer-sd-image =
            rpi5RootIntermediateSigner.config.system.build.sdImage;
        }
      );

      apps = forAllSystems (
        pkgs:
        let
          package = mkPdPkiPackage pkgs;
        in
        {
          default = mkApp package "pd-pki-api" "Run the pd-pki FastAPI service.";
          pd-pki-api = mkApp package "pd-pki-api" "Run the pd-pki FastAPI service.";
          pd-pki-mock-api = mkApp package "pd-pki-mock-api" "Run the pd-pki mock API.";
          pd-pki-workflow = mkApp package "pd-pki-workflow" "Run the pd-pki workflow CLI.";
        }
      );

      checks = forAllSystems (
        pkgs:
        import ./checks {
          inherit pkgs nixpkgs pd-pki-python;
          pd-pki-package = mkPdPkiPackage pkgs;
          offlineSystems = {
            inherit rpi5RootYubiKeyProvisioner rpi5RootIntermediateSigner;
          };
        }
      );

      inherit nixosModules;

      nixosConfigurations = {
        hardware-lab = mkSystem "x86_64-linux" [ ./systems/hardware-lab.nix ];
        rpi5-root-yubikey-provisioner = rpi5RootYubiKeyProvisioner;
        rpi5-root-intermediate-signer = rpi5RootIntermediateSigner;
      };
    };
}
