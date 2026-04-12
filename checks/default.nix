{
  pkgs,
  definitions,
  packages,
  nixosModules,
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

  roleChecks =
    rootChecks
    // intermediateChecks
    // serverChecks
    // clientChecks;

  moduleChecks = import ./nixos-modules.nix {
    inherit pkgs definitions packages nixosModules;
  };

  sharedChecks = listToAttrs [
    {
      name = "module-runtime-artifacts";
      value = import ./module-runtime-artifacts.nix {
        inherit pkgs packages nixosModules;
      };
    }
    {
      name = "openvpn-daemon";
      value = import ./openvpn-daemon.nix {
        inherit pkgs packages nixosModules;
      };
    }
    {
      name = "role-topology";
      value =
        if pkgs.stdenv.hostPlatform.isLinux then
          import ./nixos-role-topology.nix {
            inherit pkgs definitions packages nixosModules;
          }
        else
          pkgs.runCommand "pd-pki-role-topology-unsupported" { } ''
            printf '%s\n' "[role-topology] skipped: requires Linux NixOS test support"
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
    {
      name = "signing-tools-pkcs11";
      value = import ./signing-tools-pkcs11.nix {
        inherit pkgs packages;
      };
    }
  ];
in
# Aggregate the shared checks plus one imported check set per role.
sharedChecks
// roleChecks
// moduleChecks
