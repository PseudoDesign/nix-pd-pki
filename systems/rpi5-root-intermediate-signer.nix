{ lib, ... }:
let
  ceremonyUser = "pdpki";
  ceremonyHome = "/var/lib/pd-pki";
  ceremonySecretsDirectory = "${ceremonyHome}/secrets";
in
{
  imports = [ ./rpi5-root-ca-base.nix ];

  image.baseName = lib.mkForce "pd-pki-rpi5-root-intermediate-signer";
  networking.hostName = "rpi5-root-intermediate-signer";

  environment.shellInit = ''
    if [ "''${USER:-}" = ${lib.escapeShellArg ceremonyUser} ] && [ "''${HOME:-}" = ${lib.escapeShellArg ceremonyHome} ]; then
      umask 077
      export PIN_FILE="$HOME/secrets/root-pin.txt"
      export ROOT_POLICY_FILE="$HOME/policy/root-policy.json"
      export ROOT_INVENTORY_ROOT="$HOME/inventory/root-ca"
    fi
  '';

  environment.etc."motd".text = ''
    Pseudo Design offline root CA intermediate signer

    Ceremony shell defaults:
      umask 077
      PIN_FILE=${ceremonySecretsDirectory}/root-pin.txt
      ROOT_POLICY_FILE=${ceremonyHome}/policy/root-policy.json
      ROOT_INVENTORY_ROOT=${ceremonyHome}/inventory/root-ca

    Suggested ceremony flow:
      1. Confirm the committed root inventory has been copied onto the workstation
      2. Mount the removable media carrying the intermediate request bundle
      3. Run pd-pki-operator and choose the root PKCS#11 signing flow for the intermediate request bundle
      4. The operator flow will require committed root inventory selection and verify the inserted root CA YubiKey before signing
      5. Export the signed intermediate bundle back to removable media

    Temporary debug access is enabled on this image:
      - wired DHCP networking
      - OpenSSH on TCP 22
      - adam account with imported authorized_keys

    Local console autologin is enabled for the dedicated ${ceremonyUser} appliance session account by default.
    Review and harden the login policy before using this image in production.
  '';

  system.nixos.tags = [
    "offline-root-ca"
    "raspberry-pi-5"
    "root-intermediate-signer"
  ];
}
