{ lib, pkgs, nixos-raspberrypi, ... }:
let
  definitions = import ../packages/definitions.nix;
  pdPkiPackages = import ../packages {
    inherit pkgs definitions;
  };
in
{
  imports =
    [
      ../modules/root-certificate-authority.nix
    ]
    ++ (with nixos-raspberrypi.nixosModules; [
      sd-image
      raspberry-pi-5.base
      raspberry-pi-5.page-size-16k
    ]);

  image.baseName = lib.mkForce "pd-pki-rpi5-root-ca";

  boot.loader.raspberry-pi.bootloader = "kernel";

  networking.hostName = "rpi5-root-ca";
  networking.useDHCP = lib.mkForce false;
  networking.networkmanager.enable = false;
  networking.wireless.enable = false;
  networking.firewall.enable = true;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  services.openssh.enable = false;
  services.avahi.enable = false;
  services.pcscd.enable = true;
  hardware.bluetooth.enable = false;

  services.getty.autologinUser = "operator";

  users.users.operator = {
    isNormalUser = true;
    description = "Offline Root CA Operator";
    extraGroups = [ "wheel" ];
    createHome = true;
    home = "/home/operator";
  };

  security.sudo.wheelNeedsPassword = false;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = [
    pdPkiPackages.pd-pki-operator
    pdPkiPackages.pd-pki-signing-tools
    pdPkiPackages.root-certificate-authority
    pkgs.git
    pkgs.jq
    pkgs.opensc
    pkgs.openssl
    pkgs.tmux
    pkgs.tree
    pkgs.yubikey-manager
  ];

  environment.etc."motd".text = ''
    Pseudo Design offline root CA workstation

    Root YubiKey profile:
      /etc/pd-pki/root-yubikey-init-profile.json

    Suggested ceremony flow:
      1. Review the exported profile JSON
      2. Run pd-pki-signing-tools init-root-yubikey --dry-run
      3. Review root-yubikey-init-plan.json in the chosen work directory
      4. Run the matching apply command with --force-reset and the secret files

    Local console autologin is enabled for the operator account by default.
    Review and harden the login policy before using this image in production.
  '';

  services.pd-pki.roles.rootCertificateAuthority = {
    enable = true;
    installPackage = true;
    refreshInterval = null;
  };

  system.nixos.tags = [
    "offline-root-ca"
    "raspberry-pi-5"
  ];
  system.stateVersion = "24.11";
}
