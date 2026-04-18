{
  pkgs,
  pd-pki-python,
  pd-pki-package,
}:
if pkgs.stdenv.hostPlatform.isLinux then
  pkgs.testers.runNixOSTest {
    name = "pd-pki-vm-smoke";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [ ../systems/hardware-lab.nix ];

        _module.args = {
          inherit pd-pki-python;
          inherit pd-pki-package;
        };

        environment.systemPackages = [ pkgs.curl ];
        virtualisation.memorySize = 1536;
      };

    testScript = ''
      start_all()

      machine.wait_for_unit("pd-pki-api.service")
      machine.wait_until_succeeds(
          "curl --fail --silent http://127.0.0.1:8000/healthz | grep -F '{\"status\":\"ok\"}'"
      )
      machine.wait_until_succeeds(
          "curl --fail --silent http://127.0.0.1:8000/gui | grep -F 'pd-pki Workflow Console'"
      )

      machine.succeed("test -d /var/lib/pd-pki/profile")
      machine.succeed("test -d /var/lib/pd-pki/token")
      machine.succeed("test -d /var/lib/pd-pki/workspace")
      machine.succeed("test -d /var/lib/pd-pki/bundle")
      machine.succeed("test -d /var/lib/pd-pki/repository")
      machine.succeed("stat -c '%U:%G' /var/lib/pd-pki/workspace | grep -Fx 'pdpki:pdpki'")
      machine.succeed("su -s /bin/sh -c 'touch /var/lib/pd-pki/workspace/vm-smoke' pdpki")
    '';
  }
else
  pkgs.runCommand "pd-pki-vm-smoke-unsupported" { } ''
    printf '%s\n' "vm-smoke requires a Linux host with NixOS test support" > "$out"
  ''
