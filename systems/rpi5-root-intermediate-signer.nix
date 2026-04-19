{ lib, pkgs, definitions, nixos-raspberrypi, ... }:
let
  ceremonyUser = "pdpki";
  ceremonyHome = "/var/lib/pd-pki";
  ceremonySecretsDirectory = "${ceremonyHome}/secrets";
  rootPolicyRoot = "${ceremonyHome}/policy/root-ca";
  rootInventoryRoot = "${ceremonyHome}/inventory/root-ca";
  rootCertFile = "${ceremonyHome}/authorities/root/root-ca.cert.pem";
  rootSignerStateDir = "${ceremonyHome}/signer-state/root";
  pdPkiPackages = import ../packages {
    inherit pkgs definitions;
  };
in
{
  imports = [
    ./rpi5-root-ca-base.nix
    nixos-raspberrypi.nixosModules.raspberry-pi-5.display-vc4
  ];

  image.baseName = lib.mkForce "pd-pki-rpi5-root-intermediate-signer";
  networking.hostName = "rpi5-root-intermediate-signer";

  environment.shellInit = ''
    if [ "''${USER:-}" = ${lib.escapeShellArg ceremonyUser} ] && [ "''${HOME:-}" = ${lib.escapeShellArg ceremonyHome} ]; then
      umask 077
      export PIN_FILE="$HOME/secrets/root-pin.txt"
      export ROOT_POLICY_ROOT=${lib.escapeShellArg rootPolicyRoot}
      export ROOT_INVENTORY_ROOT=${lib.escapeShellArg rootInventoryRoot}
      export ROOT_CERT_FILE=${lib.escapeShellArg rootCertFile}
      export ROOT_SIGNER_STATE_DIR=${lib.escapeShellArg rootSignerStateDir}
    fi
  '';

  environment.etc."motd".text = ''
    Pseudo Design offline root CA intermediate signer

    Ceremony shell defaults:
      umask 077
      PIN_FILE=${ceremonySecretsDirectory}/root-pin.txt
        optional: the graphical signer wizard prompts on-screen if this file is absent
      ROOT_POLICY_ROOT=${rootPolicyRoot}
      ROOT_INVENTORY_ROOT=${rootInventoryRoot}
      ROOT_CERT_FILE=${rootCertFile}
      ROOT_SIGNER_STATE_DIR=${rootSignerStateDir}

    The appliance launches the graphical intermediate-signing wizard automatically on boot.

    Guided ceremony flow:
      1. Review the on-screen process overview and confirm the request media, YubiKey, and export media are ready
      2. Insert the request USB drive and copy the intermediate CSR bundle locally
      3. Remove the request USB drive and confirm the CSR details
      4. Choose the committed root inventory entry and insert the root CA YubiKey
      5. Verify the YubiKey against committed root inventory and sign the intermediate CSR
      6. Remove the YubiKey, insert a fresh USB drive, and let the wizard reformat it for the signed bundle export

    Temporary debug access is enabled on this image:
      - wired DHCP networking
      - OpenSSH on TCP 22
      - adam account with imported authorized_keys

    The dedicated ${ceremonyUser} system session account auto-logs into the local graphical wizard session.
    Switch to another VT or use SSH for terminal-based debug access when needed.
  '';

  services.getty.autologinUser = lib.mkForce null;

  services.displayManager = {
    autoLogin.enable = true;
    autoLogin.user = ceremonyUser;
    defaultSession = "none+openbox";
  };

  security.sudo.extraRules = lib.mkAfter [
    {
      users = [
        ceremonyUser
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

  services.libinput.enable = true;

  services.xserver = {
    enable = true;
    videoDrivers = [ "modesetting" ];
    displayManager.lightdm.enable = true;
    displayManager.sessionCommands = ''
      ${pkgs.xorg.xsetroot}/bin/xsetroot -solid "#16202a"
      ${pkgs.xorg.xset}/bin/xset s 900 900
      ${pkgs.xorg.xset}/bin/xset +dpms
      ${pkgs.xorg.xset}/bin/xset dpms 900 900 900
      ${pkgs.unclutter}/bin/unclutter -idle 0.1 -root &
      ${pdPkiPackages.pd-pki-root-intermediate-signer-wizard}/bin/pd-pki-root-intermediate-signer-wizard &
    '';
    windowManager.openbox.enable = true;
  };

  environment.etc."pam.d/lightdm-autologin".text = lib.mkForce ''
    auth      requisite     pam_nologin.so

    auth      required      pam_succeed_if.so user = ${ceremonyUser} quiet
    auth      required      pam_permit.so

    account   sufficient    pam_unix.so

    password  requisite     pam_unix.so nullok yescrypt

    session   optional      pam_keyinit.so revoke
    session   include       login
  '';

  system.nixos.tags = [
    "offline-root-ca"
    "raspberry-pi-5"
    "root-intermediate-signer"
  ];
}
