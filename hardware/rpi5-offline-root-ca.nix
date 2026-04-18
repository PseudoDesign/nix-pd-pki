{ lib, nixos-raspberrypi, ... }:
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
    enable = lib.mkDefault false;
    openFirewall = lib.mkDefault false;
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

  system.nixos.tags = [
    "offline-root-ca"
    "raspberry-pi-5"
  ];
  system.stateVersion = "25.11";
}
