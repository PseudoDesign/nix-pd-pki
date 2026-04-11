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
            packages.pd-pki-signing-tools
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
            packages.pd-pki-signing-tools
          ];
          services.pd-pki.roles.intermediateSigningAuthority.enable = true;
          system.stateVersion = lib.mkDefault "24.11";
        };

      server =
        { lib, ... }:
        {
          imports = [ nixosModules.openvpn-server-leaf ];

          networking.hostName = "server";
          environment.systemPackages = [
            pkgs.openssl
            pkgs.jq
            packages.pd-pki-signing-tools
          ];
          services.pd-pki.roles.openvpnServerLeaf.enable = true;
          system.stateVersion = lib.mkDefault "24.11";
        };

      client =
        { lib, ... }:
        {
          imports = [ nixosModules.openvpn-client-leaf ];

          networking.hostName = "client";
          environment.systemPackages = [
            pkgs.openssl
            pkgs.jq
            packages.pd-pki-signing-tools
          ];
          services.pd-pki.roles.openvpnClientLeaf.enable = true;
          system.stateVersion = lib.mkDefault "24.11";
        };
    };

    testScript =
      # python
      ''
        import os
        from pathlib import Path

        start_all()

        out_dir = os.environ.get("out", os.getcwd())

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
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/signing-request.json")
        intermediate.succeed("test ! -e /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem")
        intermediate.succeed("test ! -e /var/lib/pd-pki/authorities/intermediate/chain.pem")
        intermediate.succeed("test ! -e /var/lib/pd-pki/authorities/intermediate/signer-metadata.json")
        intermediate.succeed("test \"$(stat -c %a /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem)\" = 600")
        intermediate.succeed("case \"$(readlink -f /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem)\" in /nix/store/*) exit 1 ;; *) exit 0 ;; esac")
        intermediate.succeed("openssl req -in /var/lib/pd-pki/authorities/intermediate/intermediate-ca.csr.pem -noout >/dev/null")
        intermediate.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        intermediate.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.cert.pem")

        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/server.key.pem")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/server.csr.pem")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/issuance-request.json")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/san-manifest.json")
        server.succeed("test ! -e /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem")
        server.succeed("test ! -e /var/lib/pd-pki/openvpn-server-leaf/chain.pem")
        server.succeed("test ! -e /var/lib/pd-pki/openvpn-server-leaf/certificate-metadata.json")
        server.succeed("test \"$(stat -c %a /var/lib/pd-pki/openvpn-server-leaf/server.key.pem)\" = 600")
        server.succeed("case \"$(readlink -f /var/lib/pd-pki/openvpn-server-leaf/server.key.pem)\" in /nix/store/*) exit 1 ;; *) exit 0 ;; esac")
        server.succeed("openssl req -in /var/lib/pd-pki/openvpn-server-leaf/server.csr.pem -noout >/dev/null")
        server.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        server.succeed("test ! -e /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem")

        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/client.key.pem")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/client.csr.pem")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/issuance-request.json")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/identity-manifest.json")
        client.succeed("test ! -e /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem")
        client.succeed("test ! -e /var/lib/pd-pki/openvpn-client-leaf/chain.pem")
        client.succeed("test ! -e /var/lib/pd-pki/openvpn-client-leaf/certificate-metadata.json")
        client.succeed("test \"$(stat -c %a /var/lib/pd-pki/openvpn-client-leaf/client.key.pem)\" = 600")
        client.succeed("case \"$(readlink -f /var/lib/pd-pki/openvpn-client-leaf/client.key.pem)\" in /nix/store/*) exit 1 ;; *) exit 0 ;; esac")
        client.succeed("openssl req -in /var/lib/pd-pki/openvpn-client-leaf/client.csr.pem -noout >/dev/null")
        client.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        client.succeed("test ! -e /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem")

        intermediate.succeed("pd-pki-signing-tools export-request --role intermediate-signing-authority --state-dir /var/lib/pd-pki/authorities/intermediate --out-dir /tmp/intermediate-request")
        intermediate.copy_from_vm("/tmp/intermediate-request")
        root_imported.copy_from_host(str(Path(out_dir, "intermediate-request")), "/tmp/intermediate-request")
        root_imported.succeed("pd-pki-signing-tools sign-request --request-dir /tmp/intermediate-request --out-dir /tmp/intermediate-signed --issuer-key /var/lib/pd-pki/authorities/root/root-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/root/root-ca.cert.pem --signer-state-dir /var/lib/pd-pki/signer-state/root --days 1825")
        root_imported.copy_from_vm("/tmp/intermediate-signed")
        intermediate.copy_from_host(str(Path(out_dir, "intermediate-signed")), "/tmp/intermediate-signed")
        intermediate.succeed("pd-pki-signing-tools import-signed --role intermediate-signing-authority --state-dir /var/lib/pd-pki/authorities/intermediate --signed-dir /tmp/intermediate-signed")
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem")
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/chain.pem")
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/signer-metadata.json")
        intermediate.succeed("openssl verify -CAfile /var/lib/pd-pki/authorities/intermediate/chain.pem /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem >/dev/null")
        intermediate.succeed("jq -r '.subject' /var/lib/pd-pki/authorities/intermediate/signer-metadata.json | grep -F 'Pseudo Design Runtime Intermediate Signing Authority'")
        root_imported.succeed("test -f /var/lib/pd-pki/signer-state/root/serials/next-serial")
        root_imported.succeed("test \"$(cat /var/lib/pd-pki/signer-state/root/serials/next-serial)\" = 2")
        root_imported.succeed("test -f /var/lib/pd-pki/signer-state/root/serials/allocated/1.json")
        root_imported.succeed("test -f /var/lib/pd-pki/signer-state/root/issuances/1/issuance.json")
        root_imported.succeed("jq -r '.status' /var/lib/pd-pki/signer-state/root/issuances/1/issuance.json | grep -Fx 'issued'")
        root_imported.succeed("test \"$(find /var/lib/pd-pki/signer-state/root/requests -maxdepth 1 -name '*.json' | wc -l | tr -d '[:space:]')\" = 1")

        server.succeed("pd-pki-signing-tools export-request --role openvpn-server-leaf --state-dir /var/lib/pd-pki/openvpn-server-leaf --out-dir /tmp/server-request")
        server.copy_from_vm("/tmp/server-request")
        intermediate.copy_from_host(str(Path(out_dir, "server-request")), "/tmp/server-request")
        intermediate.succeed("pd-pki-signing-tools sign-request --request-dir /tmp/server-request --out-dir /tmp/server-signed --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem --issuer-chain /var/lib/pd-pki/authorities/intermediate/chain.pem --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --days 825")
        intermediate.copy_from_vm("/tmp/server-signed")
        server.copy_from_host(str(Path(out_dir, "server-signed")), "/tmp/server-signed")
        server.succeed("pd-pki-signing-tools import-signed --role openvpn-server-leaf --state-dir /var/lib/pd-pki/openvpn-server-leaf --signed-dir /tmp/server-signed")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/chain.pem")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/certificate-metadata.json")
        server.succeed("openssl verify -CAfile /var/lib/pd-pki/openvpn-server-leaf/chain.pem /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem >/dev/null")
        server.succeed("jq -r '.subject' /var/lib/pd-pki/openvpn-server-leaf/certificate-metadata.json | grep -F 'vpn.pseudo.test'")

        client.succeed("pd-pki-signing-tools export-request --role openvpn-client-leaf --state-dir /var/lib/pd-pki/openvpn-client-leaf --out-dir /tmp/client-request")
        client.copy_from_vm("/tmp/client-request")
        intermediate.copy_from_host(str(Path(out_dir, "client-request")), "/tmp/client-request")
        intermediate.succeed("pd-pki-signing-tools sign-request --request-dir /tmp/client-request --out-dir /tmp/client-signed --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem --issuer-chain /var/lib/pd-pki/authorities/intermediate/chain.pem --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --days 825")
        intermediate.copy_from_vm("/tmp/client-signed")
        client.copy_from_host(str(Path(out_dir, "client-signed")), "/tmp/client-signed")
        client.succeed("pd-pki-signing-tools import-signed --role openvpn-client-leaf --state-dir /var/lib/pd-pki/openvpn-client-leaf --signed-dir /tmp/client-signed")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/chain.pem")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/certificate-metadata.json")
        client.succeed("openssl verify -CAfile /var/lib/pd-pki/openvpn-client-leaf/chain.pem /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem >/dev/null")
        client.succeed("jq -r '.subject' /var/lib/pd-pki/openvpn-client-leaf/certificate-metadata.json | grep -F 'client-01.pseudo.test'")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/serials/next-serial")
        intermediate.succeed("test \"$(cat /var/lib/pd-pki/signer-state/intermediate/serials/next-serial)\" = 3")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/serials/allocated/1.json")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/serials/allocated/2.json")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/issuances/1/issuance.json")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/issuances/2/issuance.json")
        intermediate.succeed("test \"$(find /var/lib/pd-pki/signer-state/intermediate/requests -maxdepth 1 -name '*.json' | wc -l | tr -d '[:space:]')\" = 2")
        intermediate.succeed("jq -r '.status' /var/lib/pd-pki/signer-state/intermediate/issuances/1/issuance.json | grep -Fx 'issued'")
        intermediate.succeed("jq -r '.status' /var/lib/pd-pki/signer-state/intermediate/issuances/2/issuance.json | grep -Fx 'issued'")
        intermediate.succeed("pd-pki-signing-tools revoke-issued --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --serial 2 --reason keyCompromise")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/revocations/2.json")
        intermediate.succeed("jq -r '.status' /var/lib/pd-pki/signer-state/intermediate/issuances/2/issuance.json | grep -Fx 'revoked'")
        intermediate.succeed("jq -r '.reason' /var/lib/pd-pki/signer-state/intermediate/revocations/2.json | grep -Fx 'keyCompromise'")
        intermediate.succeed("jq -r '.status' /var/lib/pd-pki/signer-state/intermediate/serials/allocated/2.json | grep -Fx 'revoked'")
      '';
  }
else
  pkgs.runCommand "module-runtime-artifacts-unsupported" { } ''
    printf '%s\n' "module runtime artifact check is only available on Linux hosts" > "$out"
  ''
