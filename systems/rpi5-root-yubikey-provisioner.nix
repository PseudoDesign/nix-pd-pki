{ lib, ... }:
let
  operatorHome = "/home/operator";
  operatorSecretsDirectory = "${operatorHome}/secrets";
  rootYubiKeyProfilePath = "/etc/pd-pki/root-yubikey-init-profile.json";
in
{
  imports = [ ./rpi5-root-ca-base.nix ];

  image.baseName = lib.mkForce "pd-pki-rpi5-root-yubikey-provisioner";
  networking.hostName = "rpi5-root-yubikey-provisioner";

  environment.shellInit = ''
    if [ "''${USER:-}" = operator ] && [ "''${HOME:-}" = ${lib.escapeShellArg operatorHome} ]; then
      umask 077
      export PROFILE=${lib.escapeShellArg rootYubiKeyProfilePath}
      export PIN_FILE="$HOME/secrets/root-pin.txt"
      export PUK_FILE="$HOME/secrets/root-puk.txt"
      export MANAGEMENT_KEY_FILE="$HOME/secrets/root-management-key.txt"
    fi
  '';

  environment.etc."motd".text = ''
    Pseudo Design offline root CA YubiKey provisioner

    Root YubiKey profile:
      ${rootYubiKeyProfilePath}

    Operator shell defaults:
      umask 077
      PROFILE=${rootYubiKeyProfilePath}
      PIN_FILE=${operatorSecretsDirectory}/root-pin.txt
      PUK_FILE=${operatorSecretsDirectory}/root-puk.txt
      MANAGEMENT_KEY_FILE=${operatorSecretsDirectory}/root-management-key.txt

    Suggested ceremony flow:
      1. Review the exported profile JSON
      2. Run pd-pki-signing-tools init-root-yubikey --dry-run
      3. Review root-yubikey-init-plan.json in the chosen work directory
      4. Run the matching apply command with --force-reset and the secret files
      5. Run pd-pki-signing-tools export-root-inventory from the archived public ceremony directory to removable media
      6. Normalize it on the development machine with pd-pki-signing-tools normalize-root-inventory

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
    "root-yubikey-provisioner"
  ];
}
