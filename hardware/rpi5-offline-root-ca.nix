{
  lib,
  nixos-raspberrypi,
  pkgs,
  ...
}:
let
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
    with nixos-raspberrypi.nixosModules;
    [
      sd-image
      raspberry-pi-5.base
      raspberry-pi-5.page-size-16k
    ];

  image.baseName = lib.mkDefault "pd-pki-rpi5-offline-root-ca";

  boot.loader.raspberry-pi.bootloader = "kernel";
  boot.blacklistedKernelModules = disabledRadioKernelModules;

  networking.networkmanager.enable = false;
  networking.useDHCP = lib.mkForce true;
  networking.wireless.enable = false;
  networking.firewall.enable = true;

  services.avahi.enable = false;
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
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

  # Temporary development access for Raspberry Pi image bring-up.
  users.users.adam = {
    isNormalUser = true;
    shell = pkgs.bashInteractive;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJMjtOqSWLDq79t/9XljmBrfBVm8deQJdOQmTV7c45Ni adam@malak"
    ];
  };

  system.nixos.tags = [
    "offline-root-ca"
    "raspberry-pi-5"
    "temporary-dev-access"
  ];
  system.stateVersion = "25.11";
}
