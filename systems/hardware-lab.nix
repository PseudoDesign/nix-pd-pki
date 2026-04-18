{
  lib,
  ...
}:
{
  imports = [ ../modules/pd-pki-workflow.nix ];

  networking.hostName = "pd-pki-lab";

  boot.loader.grub.device = "/dev/vda";

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  services.pd-pki-workflow = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 8000;
  };

  system.stateVersion = lib.mkDefault "25.11";
}
