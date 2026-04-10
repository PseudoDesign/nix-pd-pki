{
  description = "PKI Infrastructure for Pseudo Design";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      definitions = import ./packages/definitions.nix;
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

      lib = {
        roles = definitions.roleMap;
        roleCount = definitions.roleCount;
        stepCount = definitions.stepCount;
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
          inherit pkgs definitions packages;
        }
      );
    };
}
