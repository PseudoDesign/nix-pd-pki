{ lib, pkgs, nixos-raspberrypi, ... }:
let
  ceremonyUser = "pdpki";
  ceremonyHome = "/var/lib/pd-pki";
  definitions = import ../packages/definitions.nix;
  pdPkiPackages = import ../packages {
    inherit pkgs definitions;
  };
  adamAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJMjtOqSWLDq79t/9XljmBrfBVm8deQJdOQmTV7c45Ni adam@malak"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIojZ/xu4CVq5TbY51CMUlRiWnSdkS7ZN9xL10gNrFux black@plagueis"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIDVEuyPwmcEybp5d1/FEdCPOjCfuRZ2vp7tYGqe64mg adamschafer@starkiller"
  ];
  disabledRadioKernelModules = [
    "bluetooth"
    "brcmfmac"
    "brcmutil"
    "btbcm"
    "cfg80211"
    "hci_uart"
  ];
  usbGuardRules = ''
    allow id 1050:*
    allow with-interface one-of { 08:*:* }
    allow with-interface one-of { 03:01:01 }
  '';
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

  image.baseName = lib.mkDefault "pd-pki-rpi5-root-ca";

  boot.loader.raspberry-pi.bootloader = "kernel";
  boot.blacklistedKernelModules = disabledRadioKernelModules;

  networking.hostName = lib.mkDefault "rpi5-root-ca";
  networking.useDHCP = lib.mkForce true;
  networking.networkmanager.enable = false;
  networking.wireless.enable = false;
  networking.firewall.enable = true;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
  services.avahi.enable = false;
  services.pcscd.enable = true;
  services.usbguard = {
    enable = true;
    implicitPolicyTarget = "reject";
    rules = usbGuardRules;
  };
  hardware.bluetooth.enable = false;
  hardware.raspberry-pi.config.all.dt-overlays = {
    disable-bt = {
      enable = true;
      params = { };
    };
    disable-wifi = {
      enable = true;
      params = { };
    };
  };

  services.getty.autologinUser = ceremonyUser;

  users.groups.${ceremonyUser} = { };

  users.users.${ceremonyUser} = {
    isSystemUser = true;
    description = "Offline Root CA Ceremony Session";
    extraGroups = [ "wheel" ];
    group = ceremonyUser;
    createHome = true;
    home = ceremonyHome;
    shell = pkgs.bashInteractive;
  };

  users.users.adam = {
    isNormalUser = true;
    description = "Temporary debug SSH account for Adam Schafer";
    extraGroups = [ "wheel" ];
    createHome = true;
    home = "/home/adam";
    openssh.authorizedKeys.keys = adamAuthorizedKeys;
  };

  security.sudo.wheelNeedsPassword = false;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.shellInit = lib.mkDefault ''
    if [ "''${USER:-}" = ${ceremonyUser} ] && [ "''${HOME:-}" = ${ceremonyHome} ]; then
      umask 077
    fi
  '';

  environment.systemPackages = [
    pdPkiPackages.pd-pki-operator
    pdPkiPackages.pd-pki-signing-tools
    pdPkiPackages.root-certificate-authority
    pkgs.git
    pkgs.jq
    pkgs.libp11
    pkgs.opensc
    pkgs.openssl
    pkgs.pkcs11-provider
    pkgs.tmux
    pkgs.tree
    pkgs.yubico-piv-tool
    pkgs.yubikey-manager
  ];

  environment.etc."motd".text = lib.mkDefault ''
    Pseudo Design offline root CA workstation

    Temporary debug access is enabled on this image:
      - wired DHCP networking
      - OpenSSH on TCP 22
      - adam account with imported authorized_keys

    Local console autologin is enabled for the ${ceremonyUser} system account by default.
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
