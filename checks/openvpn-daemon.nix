{
  pkgs,
  packages,
  nixosModules,
}:
let
  rootFixture = pkgs.runCommand "pd-pki-root-openvpn-daemon-fixture" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    set -euo pipefail
    source ${../packages/pki-workflow-lib.sh}

    mkdir -p "$out"
    generate_self_signed_ca "$out" "root-ca" "Pseudo Design Imported Root CA" 9001 3650 1
  '';

  intermediateKeyFixture = pkgs.runCommand "pd-pki-intermediate-openvpn-daemon-key-fixture" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    set -euo pipefail
    mkdir -p "$out"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$out/intermediate-ca.key.pem"
  '';

  serverKeyFixture = pkgs.runCommand "pd-pki-server-openvpn-daemon-key-fixture" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    set -euo pipefail
    mkdir -p "$out"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$out/server.key.pem"
  '';

  clientKeyFixture = pkgs.runCommand "pd-pki-client-openvpn-daemon-key-fixture" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    set -euo pipefail
    mkdir -p "$out"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$out/client.key.pem"
  '';
in
if pkgs.stdenv.hostPlatform.isLinux then
  pkgs.testers.runNixOSTest {
    name = "openvpn-daemon";

    nodes = {
      root_imported =
        { lib, ... }:
        {
          imports = [ nixosModules.root-certificate-authority ];

          virtualisation.vlans = [ 1 ];
          networking.hostName = "root-imported";
          networking.usePredictableInterfaceNames = false;
          networking.interfaces.eth1.ipv4.addresses = [
            {
              address = "192.168.1.2";
              prefixLength = 24;
            }
          ];
          networking.firewall.enable = false;
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

          virtualisation.vlans = [ 1 ];
          networking.hostName = "intermediate";
          networking.usePredictableInterfaceNames = false;
          networking.interfaces.eth1.ipv4.addresses = [
            {
              address = "192.168.1.3";
              prefixLength = 24;
            }
          ];
          networking.firewall.enable = false;
          environment.systemPackages = [
            pkgs.jq
            pkgs.openssl
            packages.pd-pki-signing-tools
          ];
          services.pd-pki.roles.intermediateSigningAuthority = {
            enable = true;
            refreshInterval = "1h";
            keySourcePath = "${intermediateKeyFixture}/intermediate-ca.key.pem";
            certificateSourcePath = "/var/lib/pd-pki/imports/intermediate.cert.pem";
            chainSourcePath = "/var/lib/pd-pki/imports/intermediate.chain.pem";
            metadataSourcePath = "/var/lib/pd-pki/imports/intermediate.metadata.json";
          };
          system.stateVersion = lib.mkDefault "24.11";
        };

      server =
        { lib, ... }:
        {
          imports = [ nixosModules.openvpn-server-leaf ];

          virtualisation.vlans = [ 1 ];
          networking.hostName = "server";
          networking.usePredictableInterfaceNames = false;
          networking.interfaces.eth1.ipv4.addresses = [
            {
              address = "192.168.1.10";
              prefixLength = 24;
            }
          ];
          networking.firewall.enable = false;
          environment.systemPackages = [
            pkgs.iproute2
            pkgs.iputils
            pkgs.jq
            pkgs.openssl
            packages.pd-pki-signing-tools
          ];
          systemd.tmpfiles.rules = [
            "d /run/openvpn 0755 root root - -"
          ];
          services.pd-pki.roles.openvpnServerLeaf = {
            enable = true;
            refreshInterval = "1h";
            keySourcePath = "${serverKeyFixture}/server.key.pem";
            certificateSourcePath = "/var/lib/pd-pki/imports/server.cert.pem";
            chainSourcePath = "/var/lib/pd-pki/imports/server.chain.pem";
            crlSourcePath = "/var/lib/pd-pki/imports/intermediate.crl.pem";
            metadataSourcePath = "/var/lib/pd-pki/imports/server.metadata.json";
            reloadUnits = [ "openvpn-server.service" ];
          };
          services.openvpn.servers.server = {
            autoStart = false;
            config = ''
              dev tun0
              proto udp
              port 1194
              server 10.8.0.0 255.255.255.0
              topology subnet
              tls-server
              dh none
              keepalive 1 5
              persist-key
              persist-tun
              auth SHA256
              data-ciphers AES-256-GCM:AES-128-GCM
              data-ciphers-fallback AES-256-CBC
              verify-client-cert require
              status /run/openvpn/server.status 1
              status-version 2
              ca /var/lib/pd-pki/openvpn-server-leaf/chain.pem
              cert /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem
              key /var/lib/pd-pki/openvpn-server-leaf/server.key.pem
              crl-verify /var/lib/pd-pki/openvpn-server-leaf/crl.pem
              verb 3
            '';
          };
          systemd.services.openvpn-server = {
            after = [ "pd-pki-openvpn-server-leaf-init.service" ];
            requires = [ "pd-pki-openvpn-server-leaf-init.service" ];
            serviceConfig.Restart = lib.mkForce "no";
          };
          system.stateVersion = lib.mkDefault "24.11";
        };

      client =
        { lib, ... }:
        {
          imports = [ nixosModules.openvpn-client-leaf ];

          virtualisation.vlans = [ 1 ];
          networking.hostName = "client";
          networking.usePredictableInterfaceNames = false;
          networking.interfaces.eth1.ipv4.addresses = [
            {
              address = "192.168.1.11";
              prefixLength = 24;
            }
          ];
          networking.firewall.enable = false;
          environment.systemPackages = [
            pkgs.iproute2
            pkgs.iputils
            pkgs.jq
            pkgs.openssl
            packages.pd-pki-signing-tools
          ];
          systemd.tmpfiles.rules = [
            "d /run/openvpn 0755 root root - -"
          ];
          services.pd-pki.roles.openvpnClientLeaf = {
            enable = true;
            refreshInterval = "1h";
            keySourcePath = "${clientKeyFixture}/client.key.pem";
            certificateSourcePath = "/var/lib/pd-pki/imports/client.cert.pem";
            chainSourcePath = "/var/lib/pd-pki/imports/client.chain.pem";
            crlSourcePath = "/var/lib/pd-pki/imports/intermediate.crl.pem";
            metadataSourcePath = "/var/lib/pd-pki/imports/client.metadata.json";
            reloadUnits = [ "openvpn-client.service" ];
          };
          services.openvpn.servers.client = {
            autoStart = false;
            config = ''
              client
              dev tun0
              proto udp
              remote 192.168.1.10 1194
              nobind
              tls-client
              remote-cert-tls server
              verify-x509-name vpn.pseudo.test name
              persist-key
              persist-tun
              auth SHA256
              data-ciphers AES-256-GCM:AES-128-GCM
              data-ciphers-fallback AES-256-CBC
              status /run/openvpn/client.status 1
              status-version 2
              ca /var/lib/pd-pki/openvpn-client-leaf/chain.pem
              cert /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem
              key /var/lib/pd-pki/openvpn-client-leaf/client.key.pem
              crl-verify /var/lib/pd-pki/openvpn-client-leaf/crl.pem
              verb 3
            '';
          };
          systemd.services.openvpn-client = {
            after = [ "pd-pki-openvpn-client-leaf-init.service" ];
            requires = [ "pd-pki-openvpn-client-leaf-init.service" ];
            serviceConfig.Restart = lib.mkForce "no";
          };
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

        root_imported.wait_for_unit("pd-pki-root-certificate-authority-init.service")
        intermediate.wait_for_unit("pd-pki-intermediate-signing-authority-init.service")
        server.wait_for_unit("pd-pki-openvpn-server-leaf-init.service")
        client.wait_for_unit("pd-pki-openvpn-client-leaf-init.service")

        server.succeed("ping -c 1 192.168.1.11")
        client.succeed("ping -c 1 192.168.1.10")

        root_imported.succeed("""jq -n '
        {
          schemaVersion: 1,
          roles: {
            "intermediate-signing-authority": {
              defaultDays: 1825,
              maxDays: 1825,
              allowedKeyAlgorithms: ["RSA"],
              minimumRsaBits: 3072,
              crlDistributionPoints: [
                "https://pki.pseudo.test/root.crl"
              ],
              commonNamePatterns: [
                "^Pseudo Design Runtime Intermediate Signing Authority$"
              ],
              allowedPathLens: [0]
            }
          }
        }' > /tmp/root-policy.json""")

        intermediate.succeed("""jq -n '
        {
          schemaVersion: 1,
          roles: {
            "openvpn-server-leaf": {
              defaultDays: 825,
              maxDays: 825,
              allowedKeyAlgorithms: ["RSA"],
              minimumRsaBits: 3072,
              allowedProfiles: ["serverAuth"],
              crlDistributionPoints: [
                "https://pki.pseudo.test/intermediate.crl"
              ],
              commonNamePatterns: [
                "^[A-Za-z0-9.-]+$"
              ],
              subjectAltNamePatterns: [
                "^DNS:[A-Za-z0-9.-]+$",
                "^IP:[0-9.]+$"
              ]
            },
            "openvpn-client-leaf": {
              defaultDays: 825,
              maxDays: 825,
              allowedKeyAlgorithms: ["RSA"],
              minimumRsaBits: 3072,
              allowedProfiles: ["clientAuth"],
              crlDistributionPoints: [
                "https://pki.pseudo.test/intermediate.crl"
              ],
              commonNamePatterns: [
                "^[A-Za-z0-9.-]+$"
              ],
              subjectAltNamePatterns: [
                "^DNS:[A-Za-z0-9.-]+$"
              ]
            }
          }
        }' > /tmp/intermediate-policy.json""")

        intermediate.succeed("pd-pki-signing-tools export-request --role intermediate-signing-authority --state-dir /var/lib/pd-pki/authorities/intermediate --out-dir /tmp/intermediate-request")
        intermediate.copy_from_vm("/tmp/intermediate-request")
        root_imported.copy_from_host(str(Path(out_dir, "intermediate-request")), "/tmp/intermediate-request")
        root_imported.succeed("pd-pki-signing-tools sign-request --request-dir /tmp/intermediate-request --out-dir /tmp/intermediate-signed --issuer-key /var/lib/pd-pki/authorities/root/root-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/root/root-ca.cert.pem --signer-state-dir /var/lib/pd-pki/signer-state/root --policy-file /tmp/root-policy.json --approved-by operator-root")
        root_imported.copy_from_vm("/tmp/intermediate-signed")
        intermediate.copy_from_host(str(Path(out_dir, "intermediate-signed")), "/tmp/intermediate-signed")
        intermediate.succeed("mkdir -p /var/lib/pd-pki/imports")
        intermediate.succeed("cp /tmp/intermediate-signed/intermediate-ca.cert.pem /var/lib/pd-pki/imports/intermediate.cert.pem")
        intermediate.succeed("cp /tmp/intermediate-signed/chain.pem /var/lib/pd-pki/imports/intermediate.chain.pem")
        intermediate.succeed("cp /tmp/intermediate-signed/metadata.json /var/lib/pd-pki/imports/intermediate.metadata.json")
        intermediate.succeed("systemctl start pd-pki-intermediate-signing-authority-refresh.service")
        intermediate.wait_until_succeeds("test -f /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem")
        intermediate.wait_until_succeeds("test -f /var/lib/pd-pki/authorities/intermediate/chain.pem")

        server.succeed("pd-pki-signing-tools export-request --role openvpn-server-leaf --state-dir /var/lib/pd-pki/openvpn-server-leaf --out-dir /tmp/server-request")
        client.succeed("pd-pki-signing-tools export-request --role openvpn-client-leaf --state-dir /var/lib/pd-pki/openvpn-client-leaf --out-dir /tmp/client-request")
        server.copy_from_vm("/tmp/server-request")
        client.copy_from_vm("/tmp/client-request")
        intermediate.copy_from_host(str(Path(out_dir, "server-request")), "/tmp/server-request")
        intermediate.copy_from_host(str(Path(out_dir, "client-request")), "/tmp/client-request")
        intermediate.succeed("pd-pki-signing-tools sign-request --request-dir /tmp/server-request --out-dir /tmp/server-signed --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem --issuer-chain /var/lib/pd-pki/authorities/intermediate/chain.pem --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --policy-file /tmp/intermediate-policy.json --approved-by operator-server")
        intermediate.succeed("pd-pki-signing-tools sign-request --request-dir /tmp/client-request --out-dir /tmp/client-signed --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem --issuer-chain /var/lib/pd-pki/authorities/intermediate/chain.pem --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --policy-file /tmp/intermediate-policy.json --approved-by operator-client")
        client_serial = intermediate.succeed("jq -r '.serial' /tmp/client-signed/metadata.json").strip()
        intermediate.succeed("pd-pki-signing-tools generate-crl --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem --out-dir /tmp/intermediate-crl --days 30")

        intermediate.copy_from_vm("/tmp/server-signed")
        intermediate.copy_from_vm("/tmp/client-signed")
        intermediate.copy_from_vm("/tmp/intermediate-crl")

        server.copy_from_host(str(Path(out_dir, "server-signed")), "/tmp/server-signed")
        server.copy_from_host(str(Path(out_dir, "intermediate-crl")), "/tmp/intermediate-crl")
        server.succeed("mkdir -p /var/lib/pd-pki/imports")
        server.succeed("cp /tmp/server-signed/server.cert.pem /var/lib/pd-pki/imports/server.cert.pem")
        server.succeed("cp /tmp/server-signed/chain.pem /var/lib/pd-pki/imports/server.chain.pem")
        server.succeed("cp /tmp/server-signed/metadata.json /var/lib/pd-pki/imports/server.metadata.json")
        server.succeed("cp /tmp/intermediate-crl/crl.pem /var/lib/pd-pki/imports/intermediate.crl.pem")
        server.succeed("systemctl start pd-pki-openvpn-server-leaf-refresh.service")

        client.copy_from_host(str(Path(out_dir, "client-signed")), "/tmp/client-signed")
        client.copy_from_host(str(Path(out_dir, "intermediate-crl")), "/tmp/intermediate-crl")
        client.succeed("mkdir -p /var/lib/pd-pki/imports")
        client.succeed("cp /tmp/client-signed/client.cert.pem /var/lib/pd-pki/imports/client.cert.pem")
        client.succeed("cp /tmp/client-signed/chain.pem /var/lib/pd-pki/imports/client.chain.pem")
        client.succeed("cp /tmp/client-signed/metadata.json /var/lib/pd-pki/imports/client.metadata.json")
        client.succeed("cp /tmp/intermediate-crl/crl.pem /var/lib/pd-pki/imports/intermediate.crl.pem")
        client.succeed("systemctl start pd-pki-openvpn-client-leaf-refresh.service")

        server.wait_until_succeeds("test -f /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem")
        server.wait_until_succeeds("test -f /var/lib/pd-pki/openvpn-server-leaf/chain.pem")
        server.wait_until_succeeds("test -f /var/lib/pd-pki/openvpn-server-leaf/crl.pem")
        client.wait_until_succeeds("test -f /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem")
        client.wait_until_succeeds("test -f /var/lib/pd-pki/openvpn-client-leaf/chain.pem")
        client.wait_until_succeeds("test -f /var/lib/pd-pki/openvpn-client-leaf/crl.pem")

        server.succeed("systemctl start openvpn-server.service")
        server.wait_for_unit("openvpn-server.service")
        server.wait_until_succeeds("ss -lunH | grep -E '(^|[[:space:]])0\\.0\\.0\\.0:1194([[:space:]]|$)'")
        client.succeed("systemctl start openvpn-client.service")
        client.wait_for_unit("openvpn-client.service")

        client.wait_until_succeeds("journalctl -u openvpn-client.service | grep -F 'Initialization Sequence Completed'")
        server.wait_until_succeeds("grep -F 'client-01.pseudo.test' /run/openvpn/server.status")
        client.wait_until_succeeds("ip -j addr show dev tun0 | jq -e '.[0].addr_info[] | select(.family == \"inet\") | (.local | startswith(\"10.8.0.\"))' >/dev/null")
        client.succeed("ping -c 1 10.8.0.1")
        client_tunnel_ip = client.succeed("ip -j addr show dev tun0 | jq -r '.[0].addr_info[] | select(.family == \"inet\") | .local' | head -n1").strip()
        server.succeed(f"ping -c 1 {client_tunnel_ip}")
        server_openvpn_pid = server.succeed("systemctl show -p MainPID --value openvpn-server.service").strip()

        intermediate.succeed(f"pd-pki-signing-tools revoke-issued --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --serial {client_serial} --reason keyCompromise --revoked-by operator-security")
        intermediate.succeed("pd-pki-signing-tools generate-crl --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem --out-dir /tmp/intermediate-crl-revoked --days 30")
        intermediate.copy_from_vm("/tmp/intermediate-crl-revoked")

        server.copy_from_host(str(Path(out_dir, "intermediate-crl-revoked")), "/tmp/intermediate-crl-revoked")
        client.copy_from_host(str(Path(out_dir, "intermediate-crl-revoked")), "/tmp/intermediate-crl-revoked")
        server.succeed("cp /tmp/intermediate-crl-revoked/crl.pem /var/lib/pd-pki/imports/intermediate.crl.pem")
        client.succeed("cp /tmp/intermediate-crl-revoked/crl.pem /var/lib/pd-pki/imports/intermediate.crl.pem")
        server.succeed("systemctl start pd-pki-openvpn-server-leaf-refresh.service")
        client.succeed("systemctl start pd-pki-openvpn-client-leaf-refresh.service")

        server.wait_until_succeeds(f'test "$(systemctl show -p MainPID --value openvpn-server.service)" != "{server_openvpn_pid}"')
        server.wait_for_unit("openvpn-server.service")
        server.wait_until_succeeds("if grep -F 'client-01.pseudo.test' /run/openvpn/server.status >/dev/null 2>&1; then exit 1; else exit 0; fi")
        server.wait_until_succeeds("journalctl -u openvpn-server.service | grep -F 'certificate revoked'")

        client.wait_until_succeeds("journalctl -u openvpn-client.service | grep -F 'TLS Error: TLS handshake failed'")
        client.wait_until_succeeds("if ip link show tun0 >/dev/null 2>&1; then if ip -j addr show dev tun0 | jq -e '.[0].addr_info[]? | select(.family == \"inet\") | (.local | startswith(\"10.8.0.\"))' >/dev/null 2>&1; then exit 1; else exit 0; fi; else exit 0; fi")
        client.succeed("if ping -c 1 -W 1 10.8.0.1 >/dev/null 2>&1; then exit 1; else exit 0; fi")
      '';
  }
else
  pkgs.runCommand "openvpn-daemon-unsupported" { } ''
    printf '%s\n' "openvpn daemon check is only available on Linux hosts" > "$out"
  ''
