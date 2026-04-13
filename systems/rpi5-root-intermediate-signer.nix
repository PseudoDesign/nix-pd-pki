{ lib, ... }:
let
  operatorHome = "/home/operator";
  operatorSecretsDirectory = "${operatorHome}/secrets";
in
{
  imports = [ ./rpi5-root-ca-base.nix ];

  image.baseName = lib.mkForce "pd-pki-rpi5-root-intermediate-signer";
  networking.hostName = "rpi5-root-intermediate-signer";

  environment.shellInit = ''
    if [ "''${USER:-}" = operator ] && [ "''${HOME:-}" = ${lib.escapeShellArg operatorHome} ]; then
      umask 077
      export PIN_FILE="$HOME/secrets/root-pin.txt"
      export ROOT_POLICY_FILE="$HOME/policy/root-policy.json"
      export ROOT_INVENTORY_ROOT="$HOME/inventory/root-ca"
    fi
  '';

  environment.etc."motd".text = ''
    Pseudo Design offline root CA intermediate signer

    Operator shell defaults:
      umask 077
      PIN_FILE=${operatorSecretsDirectory}/root-pin.txt
      ROOT_POLICY_FILE=/home/operator/policy/root-policy.json
      ROOT_INVENTORY_ROOT=/home/operator/inventory/root-ca

    Suggested ceremony flow:
      1. Confirm the committed root inventory has been copied onto the workstation
      2. Mount the removable media carrying the intermediate request bundle
      3. Verify the inserted token against the committed root inventory
      4. Run pd-pki-signing-tools sign-request with the root CA YubiKey backend
      5. Export the signed intermediate bundle back to removable media

    Temporary debug access is enabled on this image:
      - wired DHCP networking
      - OpenSSH on TCP 22
      - adam account with imported authorized_keys

    Local console autologin is enabled for the operator account by default.
    Review and harden the login policy before using this image in production.
  '';

  system.nixos.tags = [
    "offline-root-ca"
    "raspberry-pi-5"
    "root-intermediate-signer"
  ];
}
