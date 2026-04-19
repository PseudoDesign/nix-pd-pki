{ lib, ... }:
let
  ceremonyUser = "pdpki";
  ceremonyHome = "/var/lib/pd-pki";
  ceremonySecretsDirectory = "${ceremonyHome}/secrets";
  rootPolicyFile = "${ceremonyHome}/policy/root-policy.json";
  rootInventoryRoot = "${ceremonyHome}/inventory/root-ca";
  rootCertFile = "${ceremonyHome}/authorities/root/root-ca.cert.pem";
  rootSignerStateDir = "${ceremonyHome}/signer-state/root";
in
{
  imports = [ ./rpi5-root-ca-base.nix ];

  image.baseName = lib.mkForce "pd-pki-rpi5-root-intermediate-signer";
  networking.hostName = "rpi5-root-intermediate-signer";

  environment.shellInit = ''
    if [ "''${USER:-}" = ${lib.escapeShellArg ceremonyUser} ] && [ "''${HOME:-}" = ${lib.escapeShellArg ceremonyHome} ]; then
      umask 077
      export PIN_FILE="$HOME/secrets/root-pin.txt"
      export ROOT_POLICY_FILE=${lib.escapeShellArg rootPolicyFile}
      export ROOT_INVENTORY_ROOT=${lib.escapeShellArg rootInventoryRoot}
      export ROOT_CERT_FILE=${lib.escapeShellArg rootCertFile}
      export ROOT_SIGNER_STATE_DIR=${lib.escapeShellArg rootSignerStateDir}
    fi
  '';

  programs.bash.loginShellInit = lib.mkAfter ''
    if [ "''${USER:-}" = ${lib.escapeShellArg ceremonyUser} ] \
      && [ "''${HOME:-}" = ${lib.escapeShellArg ceremonyHome} ] \
      && [ -z "''${SSH_TTY:-}" ] \
      && [ -z "''${PD_PKI_SKIP_AUTO_WIZARD:-}" ] \
      && [ -t 0 ] \
      && [ -t 1 ]; then
      case "$(tty 2>/dev/null || true)" in
        /dev/tty1)
          pd-pki-operator --workflow root-intermediate-signer || true
          ;;
      esac
    fi
  '';

  environment.etc."motd".text = ''
    Pseudo Design offline root CA intermediate signer

    Ceremony shell defaults:
      umask 077
      PIN_FILE=${ceremonySecretsDirectory}/root-pin.txt
      ROOT_POLICY_FILE=${rootPolicyFile}
      ROOT_INVENTORY_ROOT=${rootInventoryRoot}
      ROOT_CERT_FILE=${rootCertFile}
      ROOT_SIGNER_STATE_DIR=${rootSignerStateDir}

    The appliance launches the guided root-intermediate signing wizard automatically on local console login.

    Guided ceremony flow:
      1. Review the on-screen process overview and proceed
      2. Insert the request USB drive and copy the intermediate CSR bundle locally
      3. Remove the request USB drive and confirm the CSR details
      4. Insert the root CA YubiKey and verify it against committed root inventory
      5. Approve and sign the intermediate CSR
      6. Remove the YubiKey, insert a fresh USB drive, and let the wizard reformat it for the signed bundle export

    Temporary debug access is enabled on this image:
      - wired DHCP networking
      - OpenSSH on TCP 22
      - adam account with imported authorized_keys

    Local console autologin is enabled for the dedicated ${ceremonyUser} system session account by default.
    Set PD_PKI_SKIP_AUTO_WIZARD=1 before starting a new login shell if you need to bypass the ceremony wizard locally.
    Review and harden the login policy before using this image in production.
  '';

  system.nixos.tags = [
    "offline-root-ca"
    "raspberry-pi-5"
    "root-intermediate-signer"
  ];
}
