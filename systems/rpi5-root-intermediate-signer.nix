{ lib, ... }:
{
  imports = [
    ../hardware/rpi5-offline-root-ca.nix
    ../profiles/root-intermediate-signer.nix
  ];

  image.baseName = lib.mkForce "pd-pki-rpi5-root-intermediate-signer";
  networking.hostName = "rpi5-root-intermediate-signer";
}
