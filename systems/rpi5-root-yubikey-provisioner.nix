{ lib, ... }:
{
  imports = [
    ../hardware/rpi5-offline-root-ca.nix
    ../profiles/root-yubikey-provisioner.nix
  ];

  image.baseName = lib.mkForce "pd-pki-rpi5-root-yubikey-provisioner";
  networking.hostName = "rpi5-root-yubikey-provisioner";
}
