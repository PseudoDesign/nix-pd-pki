{
  pkgs,
  pd-pki-python,
  pd-pki-package,
}:
if pkgs.stdenv.hostPlatform.isLinux then
  pkgs.testers.runNixOSTest {
    name = "pd-pki-offline-profiles";

    nodes = {
      provisioner =
        { pkgs, ... }:
        {
          imports = [
            ../hardware/vm-offline-root-ca.nix
            ../profiles/root-yubikey-provisioner.nix
          ];

          _module.args = {
            inherit pd-pki-python pd-pki-package;
          };

          environment.systemPackages = [ pkgs.curl ];
          virtualisation.memorySize = 1536;
        };

      signer =
        { pkgs, ... }:
        {
          imports = [
            ../hardware/vm-offline-root-ca.nix
            ../profiles/root-intermediate-signer.nix
          ];

          _module.args = {
            inherit pd-pki-python pd-pki-package;
          };

          environment.systemPackages = [ pkgs.curl ];
          virtualisation.memorySize = 1536;
        };
    };

    testScript = ''
      start_all()

      provisioner.wait_for_unit("pd-pki-api.service")
      signer.wait_for_unit("pd-pki-api.service")
      provisioner.wait_for_unit("pcscd.socket")
      signer.wait_for_unit("pcscd.socket")

      provisioner.wait_until_succeeds(
          "curl --fail --silent http://127.0.0.1:8000/healthz | grep -F '{\"status\":\"ok\"}'"
      )
      signer.wait_until_succeeds(
          "curl --fail --silent http://127.0.0.1:8000/healthz | grep -F '{\"status\":\"ok\"}'"
      )

      provisioner.succeed("systemctl is-active --quiet pcscd.socket")
      signer.succeed("systemctl is-active --quiet pcscd.socket")

      provisioner.succeed("command -v pd-pki-root-provision")
      provisioner.succeed("command -v pd-pki-root-inventory-export")
      signer.succeed("command -v pd-pki-root-inventory-verify")
      signer.succeed("command -v pd-pki-root-sign-intermediate")

      provisioner.succeed("test -d /var/lib/pd-pki/workspace/plan")
      provisioner.succeed("test -d /var/lib/pd-pki/workspace/archive")
      provisioner.succeed("test -d /var/lib/pd-pki/bundle/root-inventory")
      signer.succeed("test -d /var/lib/pd-pki/bundle/request")
      signer.succeed("test -d /var/lib/pd-pki/bundle/signed")
      signer.succeed("test -d /var/lib/pd-pki/repository/inventory/root-ca")
      signer.succeed("test -d /var/lib/pd-pki/repository/policy/intermediate-ca")
    '';
  }
else
  pkgs.runCommand "pd-pki-offline-profiles-unsupported" { } ''
    printf '%s\n' "offline profile VM checks require a Linux host with NixOS test support" > "$out"
  ''
