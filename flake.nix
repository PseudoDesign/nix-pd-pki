{
  description = "NixOS integration for the pd-pki Python workflow application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/25.11";
    pd-pki-python = {
      url = "github:PseudoDesign/pd-pki-python";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, pd-pki-python, ... }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        lib.genAttrs supportedSystems (system: f (import nixpkgs { inherit system; }));

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
          pkgs = import nixpkgs { inherit system; };
        in
        lib.nixosSystem {
          inherit system modules;
          specialArgs = {
            inherit pd-pki-python;
            pd-pki-package = mkPdPkiPackage pkgs;
          };
        };
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
        }
      );

      inherit nixosModules;

      nixosConfigurations = {
        hardware-lab = mkSystem "x86_64-linux" [ ./systems/hardware-lab.nix ];
      };
    };
}
