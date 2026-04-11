{
  pkgs,
  packages,
  nixosModules,
}:
let
  rootFixture = pkgs.runCommand "pd-pki-root-runtime-import-fixture" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    set -euo pipefail
    source ${../packages/pki-workflow-lib.sh}

    mkdir -p "$out"
    generate_self_signed_ca "$out" "root-ca" "Pseudo Design Imported Root CA" 9001 3650 1
  '';
in
if pkgs.stdenv.hostPlatform.isLinux then
  pkgs.testers.runNixOSTest {
    name = "module-runtime-artifacts";

    nodes = {
      root_empty =
        { lib, ... }:
        {
          imports = [ nixosModules.root-certificate-authority ];

          networking.hostName = "root-empty";
          environment.systemPackages = [
            pkgs.jq
            pkgs.openssl
          ];
          services.pd-pki.roles.rootCertificateAuthority.enable = true;
          system.stateVersion = lib.mkDefault "24.11";
        };

      root_imported =
        { lib, ... }:
        {
          imports = [ nixosModules.root-certificate-authority ];

          networking.hostName = "root-imported";
          environment.systemPackages = [
            pkgs.jq
            pkgs.openssl
          ];
          services.pd-pki.roles.rootCertificateAuthority = {
            enable = true;
            keySourcePath = "${rootFixture}/root-ca.key.pem";
            csrSourcePath = "${rootFixture}/root-ca.csr.pem";
            certificateSourcePath = "${rootFixture}/root-ca.cert.pem";
          };
          system.stateVersion = lib.mkDefault "24.11";
        };

      intermediate =
        { lib, ... }:
        {
          imports = [ nixosModules.intermediate-signing-authority ];

          networking.hostName = "intermediate";
          environment.systemPackages = [
            pkgs.jq
            pkgs.openssl
          ];
          services.pd-pki.roles.intermediateSigningAuthority = {
            enable = true;
            certificateSourcePath = "${packages.intermediate-signing-authority}/steps/create-intermediate-ca/artifacts/intermediate-ca.cert.pem";
            chainSourcePath = "${packages.intermediate-signing-authority}/steps/create-intermediate-ca/artifacts/chain.pem";
          };
          system.stateVersion = lib.mkDefault "24.11";
        };

      server =
        { lib, ... }:
        {
          imports = [ nixosModules.openvpn-server-leaf ];

          networking.hostName = "server";
          environment.systemPackages = [
            pkgs.openssl
          ];
          services.pd-pki.roles.openvpnServerLeaf = {
            enable = true;
            certificateSourcePath = "${packages.openvpn-server-leaf}/steps/package-openvpn-server-deployment-bundle/artifacts/deployment-bundle/server.cert.pem";
            chainSourcePath = "${packages.openvpn-server-leaf}/steps/package-openvpn-server-deployment-bundle/artifacts/deployment-bundle/chain.pem";
          };
          system.stateVersion = lib.mkDefault "24.11";
        };

      client =
        { lib, ... }:
        {
          imports = [ nixosModules.openvpn-client-leaf ];

          networking.hostName = "client";
          environment.systemPackages = [
            pkgs.openssl
          ];
          services.pd-pki.roles.openvpnClientLeaf = {
            enable = true;
            certificateSourcePath = "${packages.openvpn-client-leaf}/steps/package-openvpn-client-credential-bundle/artifacts/credential-bundle/client.cert.pem";
            chainSourcePath = "${packages.openvpn-client-leaf}/steps/package-openvpn-client-credential-bundle/artifacts/credential-bundle/chain.pem";
          };
          system.stateVersion = lib.mkDefault "24.11";
        };
    };

    testScript =
      # python
      ''
        start_all()

        root_empty.wait_for_unit("pd-pki-root-certificate-authority-init.service")
        root_imported.wait_for_unit("pd-pki-root-certificate-authority-init.service")
        intermediate.wait_for_unit("pd-pki-intermediate-signing-authority-init.service")
        server.wait_for_unit("pd-pki-openvpn-server-leaf-init.service")
        client.wait_for_unit("pd-pki-openvpn-client-leaf-init.service")

        root_empty.succeed("test -d /var/lib/pd-pki/authorities/root")
        root_empty.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        root_empty.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.csr.pem")
        root_empty.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.cert.pem")
        root_empty.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.metadata.json")

        root_imported.succeed("test -f /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        root_imported.succeed("test -f /var/lib/pd-pki/authorities/root/root-ca.csr.pem")
        root_imported.succeed("test -f /var/lib/pd-pki/authorities/root/root-ca.cert.pem")
        root_imported.succeed("test -f /var/lib/pd-pki/authorities/root/root-ca.metadata.json")
        root_imported.succeed("test \"$(stat -c %a /var/lib/pd-pki/authorities/root/root-ca.key.pem)\" = 600")
        root_imported.succeed("case \"$(readlink -f /var/lib/pd-pki/authorities/root/root-ca.key.pem)\" in /nix/store/*) exit 1 ;; *) exit 0 ;; esac")
        root_imported.succeed("openssl x509 -in /var/lib/pd-pki/authorities/root/root-ca.cert.pem -noout >/dev/null")
        root_imported.succeed("jq -r '.profile' /var/lib/pd-pki/authorities/root/root-ca.metadata.json | grep -Fx 'root-ca-imported'")
        root_imported.succeed("jq -r '.subject' /var/lib/pd-pki/authorities/root/root-ca.metadata.json | grep -F 'Pseudo Design Imported Root CA'")

        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem")
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/intermediate-ca.csr.pem")
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem")
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/chain.pem")
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/signer-metadata.json")
        intermediate.succeed("test \"$(stat -c %a /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem)\" = 600")
        intermediate.succeed("case \"$(readlink -f /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem)\" in /nix/store/*) exit 1 ;; *) exit 0 ;; esac")
        intermediate.succeed("openssl req -in /var/lib/pd-pki/authorities/intermediate/intermediate-ca.csr.pem -noout >/dev/null")
        intermediate.succeed("openssl verify -CAfile /var/lib/pd-pki/authorities/intermediate/chain.pem /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem >/dev/null")
        intermediate.succeed("jq -r '.profile' /var/lib/pd-pki/authorities/intermediate/signer-metadata.json | grep -Fx 'intermediate-ca-imported'")
        intermediate.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        intermediate.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.cert.pem")

        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/server.key.pem")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/server.csr.pem")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/chain.pem")
        server.succeed("test \"$(stat -c %a /var/lib/pd-pki/openvpn-server-leaf/server.key.pem)\" = 600")
        server.succeed("case \"$(readlink -f /var/lib/pd-pki/openvpn-server-leaf/server.key.pem)\" in /nix/store/*) exit 1 ;; *) exit 0 ;; esac")
        server.succeed("openssl req -in /var/lib/pd-pki/openvpn-server-leaf/server.csr.pem -noout >/dev/null")
        server.succeed("openssl verify -CAfile /var/lib/pd-pki/openvpn-server-leaf/chain.pem /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem >/dev/null")
        server.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        server.succeed("test ! -e /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem")

        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/client.key.pem")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/client.csr.pem")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/chain.pem")
        client.succeed("test \"$(stat -c %a /var/lib/pd-pki/openvpn-client-leaf/client.key.pem)\" = 600")
        client.succeed("case \"$(readlink -f /var/lib/pd-pki/openvpn-client-leaf/client.key.pem)\" in /nix/store/*) exit 1 ;; *) exit 0 ;; esac")
        client.succeed("openssl req -in /var/lib/pd-pki/openvpn-client-leaf/client.csr.pem -noout >/dev/null")
        client.succeed("openssl verify -CAfile /var/lib/pd-pki/openvpn-client-leaf/chain.pem /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem >/dev/null")
        client.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        client.succeed("test ! -e /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem")
      '';
  }
else
  pkgs.runCommand "module-runtime-artifacts-unsupported" { } ''
    printf '%s\n' "module runtime artifact check is only available on Linux hosts" > "$out"
  ''
