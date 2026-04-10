{
  pkgs,
  definitions,
  packages,
}:
let
  inherit (pkgs.lib) listToAttrs;

  rootChecks = import ./root-certificate-authority.nix {
    inherit pkgs definitions packages;
  };

  intermediateChecks = import ./intermediate-signing-authority.nix {
    inherit pkgs definitions packages;
  };

  serverChecks = import ./openvpn-server-leaf.nix {
    inherit pkgs definitions packages;
  };

  clientChecks = import ./openvpn-client-leaf.nix {
    inherit pkgs definitions packages;
  };

  sharedChecks = listToAttrs [
    {
      name = "define-contract";
      value = pkgs.runCommand "define-contract-check" {
        nativeBuildInputs = [ pkgs.jq ];
      } ''
        set -euo pipefail

        printf '%s\n' "[define-contract] starting check"
        # Confirm the top-level definition contract serializes to valid JSON.
        jq empty ${pkgs.writeText "pd-pki-define.json" (builtins.toJSON definitions)}
        printf '%s\n' "[define-contract] check passed"
        touch "$out"
      '';
    }
    {
      name = "pd-pki";
      value = pkgs.runCommand "pd-pki-check" { } ''
        set -euo pipefail

        printf '%s\n' "[pd-pki] starting aggregate package check"
        # Confirm the aggregate package links all role packages together.
        test -d "${packages.pd-pki}"
        test -e "${packages.pd-pki}/root-certificate-authority"
        test -e "${packages.pd-pki}/intermediate-signing-authority"
        test -e "${packages.pd-pki}/openvpn-server-leaf"
        test -e "${packages.pd-pki}/openvpn-client-leaf"
        printf '%s\n' "[pd-pki] aggregate package check passed"
        touch "$out"
      '';
    }
  ];
in
# Aggregate the shared checks plus one imported check set per role.
sharedChecks
// rootChecks
// intermediateChecks
// serverChecks
// clientChecks
