{
  pkgs,
  definitions,
  packages,
  nixosModules,
  rpi5RootCa,
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

  # Keep the appliance-specific interface lockdown checked in the same tracked
  # file as the other shared flake checks so evaluation does not depend on git
  # staging newly added check files.
  rpi5RootCaHardeningCheck =
    let
      cfg = rpi5RootCa.config;
      expectedBlacklistedKernelModules = [
        "bluetooth"
        "brcmfmac"
        "brcmutil"
        "btbcm"
        "cfg80211"
        "hci_uart"
      ];
      expectedUsbGuardRules = ''
        allow id 1050:*
        allow with-interface one-of { 08:*:* }
        allow with-interface one-of { 03:01:01 }
      '';
      # Assert the image still disables the onboard radios and only admits the
      # USB device classes needed for the offline signing workflow.
      hardeningChecksPassed =
        cfg.networking.networkmanager.enable == false
        && cfg.networking.wireless.enable == false
        && cfg.hardware.bluetooth.enable == false
        && builtins.all (module: builtins.elem module cfg.boot.blacklistedKernelModules) expectedBlacklistedKernelModules
        && cfg.hardware.raspberry-pi.config.all.dt-overlays.disable-bt.enable
        && cfg.hardware.raspberry-pi.config.all.dt-overlays.disable-wifi.enable
        && cfg.services.usbguard.enable
        && cfg.services.usbguard.implicitPolicyTarget == "reject"
        && cfg.services.usbguard.rules == expectedUsbGuardRules;
    in
    assert hardeningChecksPassed;
    pkgs.runCommand "pd-pki-rpi5-root-ca-hardening-check" { } ''
      printf '%s\n' "[rpi5-root-ca-hardening] root CA image hardening configuration present"
      touch "$out"
    '';

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
      name = "rpi5-root-ca-hardening";
      value = rpi5RootCaHardeningCheck;
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
    {
      name = "signing-tools-root-yubikey-init";
      value = import ./signing-tools-root-yubikey-init.nix {
        inherit pkgs packages;
      };
    }
  ];
in
# Aggregate the shared checks plus one imported check set per role.
sharedChecks
// roleChecks
// moduleChecks
