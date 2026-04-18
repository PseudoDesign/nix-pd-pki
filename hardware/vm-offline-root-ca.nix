{ lib, ... }:
{
  boot.loader.grub.device = "/dev/vda";

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  networking.useDHCP = lib.mkDefault true;
  networking.firewall.enable = false;

  system.stateVersion = lib.mkDefault "25.11";
}
