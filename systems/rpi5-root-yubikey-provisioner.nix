{ lib, pkgs, definitions, nixos-raspberrypi, ... }:
let
  operatorHome = "/home/operator";
  operatorSecretsDirectory = "${operatorHome}/secrets";
  rootYubiKeyProfilePath = "/etc/pd-pki/root-yubikey-init-profile.json";
  pdPkiPackages = import ../packages {
    inherit pkgs definitions;
  };
in
{
  imports = [
    ./rpi5-root-ca-base.nix
    nixos-raspberrypi.nixosModules.raspberry-pi-5.display-vc4
  ];

  image.baseName = lib.mkForce "pd-pki-rpi5-root-yubikey-provisioner";
  networking.hostName = "rpi5-root-yubikey-provisioner";

  environment.shellInit = ''
    if [ "''${USER:-}" = operator ] && [ "''${HOME:-}" = ${lib.escapeShellArg operatorHome} ]; then
      umask 077
      export PROFILE=${lib.escapeShellArg rootYubiKeyProfilePath}
      export PIN_FILE="$HOME/secrets/root-pin.txt"
      export PUK_FILE="$HOME/secrets/root-puk.txt"
      export MANAGEMENT_KEY_FILE="$HOME/secrets/root-management-key.txt"
    fi
  '';

  environment.etc."motd".text = ''
    Pseudo Design offline root CA YubiKey provisioner

    Root YubiKey profile:
      ${rootYubiKeyProfilePath}

    Operator shell defaults:
      umask 077
      PROFILE=${rootYubiKeyProfilePath}
      PIN_FILE=${operatorSecretsDirectory}/root-pin.txt
      PUK_FILE=${operatorSecretsDirectory}/root-puk.txt
      MANAGEMENT_KEY_FILE=${operatorSecretsDirectory}/root-management-key.txt

    The appliance launches the graphical provisioning wizard automatically on boot.

    Suggested ceremony flow:
      1. Follow the on-screen provisioning wizard
      2. Export two custodian secret-share bundles to separate flash drives
      3. Export root inventory from the archived public ceremony directory to removable media
      4. Normalize it on the development machine with pd-pki-signing-tools normalize-root-inventory

    Temporary debug access is enabled on this image:
      - wired DHCP networking
      - OpenSSH on TCP 22
      - adam account with imported authorized_keys

    The operator account auto-logs into the local graphical wizard session.
    Switch to another VT or use SSH for terminal-based debug access when needed.
  '';

  services.getty.autologinUser = lib.mkForce null;

  services.displayManager = {
    autoLogin.enable = true;
    autoLogin.user = "operator";
    defaultSession = "none+openbox";
  };

  security.sudo.extraRules = lib.mkAfter [
    {
      users = [
        "operator"
        "adam"
      ];
      commands = [
        {
          command = "ALL";
          options = [
            "NOPASSWD"
            "SETENV"
          ];
        }
      ];
    }
  ];

  services.xserver = {
    enable = true;
    videoDrivers = [ "modesetting" ];
    displayManager.lightdm.enable = true;
    displayManager.sessionCommands = ''
      ${pkgs.xorg.xsetroot}/bin/xsetroot -solid "#16202a"
      ${pkgs.xorg.xset}/bin/xset s off -dpms
      ${pdPkiPackages.pd-pki-root-yubikey-provisioner-wizard}/bin/pd-pki-root-yubikey-provisioner-wizard &
    '';
    windowManager.openbox.enable = true;
  };

  services.devmon.enable = true;
  services.udisks2.mountOnMedia = true;

  system.nixos.tags = [
    "offline-root-ca"
    "raspberry-pi-5"
    "root-yubikey-provisioner"
  ];
}
