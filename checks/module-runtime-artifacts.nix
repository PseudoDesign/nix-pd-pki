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
  intermediateKeyFixture = pkgs.runCommand "pd-pki-intermediate-runtime-key-fixture" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    set -euo pipefail
    mkdir -p "$out"
    openssl genpkey \
      -algorithm EC \
      -pkeyopt ec_paramgen_curve:secp384r1 \
      -pkeyopt ec_param_enc:named_curve \
      -out "$out/intermediate-ca.key.pem"
  '';
  serverKeyFixture = pkgs.runCommand "pd-pki-server-runtime-key-fixture" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    set -euo pipefail
    mkdir -p "$out"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$out/server.key.pem"
  '';
  clientCsrFixture = pkgs.runCommand "pd-pki-client-runtime-csr-fixture" {
    nativeBuildInputs = [
      pkgs.openssl
      pkgs.jq
    ];
  } ''
    set -euo pipefail
    source ${../packages/pki-workflow-lib.sh}

    mkdir -p "$out"
    generate_tls_request \
      "$out" \
      "client" \
      "client-01.pseudo.test" \
      "DNS:client-01.pseudo.test" \
      "clientAuth"
    rm -f "$out/client.key.pem"
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
          services.pd-pki.roles.rootCertificateAuthority = {
            enable = true;
            ceremony = {
              subject = "/CN=Pseudo Design Configured Root CA";
              validityDays = 7300;
              outputs.archiveBaseDirectory = "/var/lib/pd-pki/custom-yubikey-inventory";
            };
          };
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
            refreshInterval = "2s";
            keyCredentialPath = "${rootFixture}/root-ca.key.pem";
            csrCredentialPath = "${rootFixture}/root-ca.csr.pem";
            certificateCredentialPath = "${rootFixture}/root-ca.cert.pem";
            crlSourcePath = "/var/lib/pd-pki/imports/root.crl.pem";
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
          systemd.services.pd-pki-intermediate-provisioner = {
            description = "Provision intermediate request material for pd-pki test coverage";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              install -Dm600 ${intermediateKeyFixture}/intermediate-ca.key.pem /run/pd-pki-provisioning/intermediate-ca.key.pem
            '';
          };
          services.pd-pki.roles.intermediateSigningAuthority = {
            enable = true;
            refreshInterval = "2s";
            provisioningUnits = [ "pd-pki-intermediate-provisioner.service" ];
            request = {
              basename = "delegated-intermediate";
              requestedDays = 3650;
            };
            keySourcePath = "/run/pd-pki-provisioning/intermediate-ca.key.pem";
            certificateSourcePath = "/var/lib/pd-pki/imports/intermediate.cert.pem";
            chainSourcePath = "/var/lib/pd-pki/imports/intermediate.chain.pem";
            crlSourcePath = "/var/lib/pd-pki/imports/intermediate.crl.pem";
            metadataSourcePath = "/var/lib/pd-pki/imports/intermediate.metadata.json";
          };
          system.stateVersion = lib.mkDefault "24.11";
        };

      server =
        { lib, ... }:
        let
          reloadObserverReload = pkgs.writeShellScript "pd-pki-server-reload-observer-reload" ''
            count_file=/var/lib/pd-pki/openvpn-server-leaf/reload-observer.count
            count=0
            if [ -f "$count_file" ]; then
              count="$(${pkgs.coreutils}/bin/cat "$count_file")"
            fi
            count=$((count + 1))
            printf '%s\n' "$count" > "$count_file"
          '';
        in
        {
          imports = [ nixosModules.openvpn-server-leaf ];

          networking.hostName = "server";
          environment.systemPackages = [
            pkgs.openssl
            pkgs.jq
            packages.pd-pki-signing-tools
          ];
          services.pd-pki.roles.openvpnServerLeaf = {
            enable = true;
            request = {
              basename = "vpn-runtime-server";
              commonName = "vpn.runtime.example.test";
              extraSubjectAltNames = [
                "DNS:openvpn.runtime.example.test"
                "IP:127.0.0.1"
              ];
              requestedDays = 397;
            };
            refreshInterval = "2s";
            keySourcePath = "${serverKeyFixture}/server.key.pem";
            certificateSourcePath = "/var/lib/pd-pki/imports/server.cert.pem";
            chainSourcePath = "/var/lib/pd-pki/imports/server.chain.pem";
            crlSourcePath = "/var/lib/pd-pki/imports/intermediate.crl.pem";
            metadataSourcePath = "/var/lib/pd-pki/imports/server.metadata.json";
            reloadUnits = [ "pd-pki-server-reload-observer.service" ];
          };
          systemd.services.pd-pki-server-reload-observer = {
            description = "Observe pd-pki runtime reloads for test coverage";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "simple";
              ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
              ExecReload = reloadObserverReload;
            };
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
            pkgs.jq
            packages.pd-pki-signing-tools
          ];
          services.pd-pki.roles.openvpnClientLeaf = {
            enable = true;
            refreshInterval = "2s";
            csrSourcePath = "${clientCsrFixture}/client.csr.pem";
            certificateSourcePath = "/var/lib/pd-pki/imports/client.cert.pem";
            chainSourcePath = "/var/lib/pd-pki/imports/client.chain.pem";
            crlSourcePath = "/var/lib/pd-pki/imports/intermediate.crl.pem";
            metadataSourcePath = "/var/lib/pd-pki/imports/client.metadata.json";
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

        root_empty.wait_for_unit("pd-pki-root-certificate-authority-init.service")
        root_imported.wait_for_unit("pd-pki-root-certificate-authority-init.service")
        intermediate.wait_for_unit("pd-pki-intermediate-provisioner.service")
        intermediate.wait_for_unit("pd-pki-intermediate-signing-authority-init.service")
        server.wait_for_unit("pd-pki-openvpn-server-leaf-init.service")
        client.wait_for_unit("pd-pki-openvpn-client-leaf-init.service")

        root_empty.succeed("test -d /var/lib/pd-pki/authorities/root")
        root_empty.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        root_empty.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.csr.pem")
        root_empty.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.cert.pem")
        root_empty.succeed("test ! -e /var/lib/pd-pki/authorities/root/crl.pem")
        root_empty.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.metadata.json")
        root_empty.succeed("test -f /etc/pd-pki/root-yubikey-init-profile.json")
        root_empty.succeed("jq -r '.profileKind' /etc/pd-pki/root-yubikey-init-profile.json | grep -Fx 'root-yubikey-initialization'")
        root_empty.succeed("jq -r '.subject' /etc/pd-pki/root-yubikey-init-profile.json | grep -Fx '/CN=Pseudo Design Configured Root CA'")
        root_empty.succeed("jq -r '.validityDays' /etc/pd-pki/root-yubikey-init-profile.json | grep -Fx '7300'")
        root_empty.succeed("test -f \"$(jq -r '.pkcs11ModulePath' /etc/pd-pki/root-yubikey-init-profile.json)\"")
        root_empty.succeed("test -d \"$(jq -r '.pkcs11ProviderDirectory' /etc/pd-pki/root-yubikey-init-profile.json)\"")
        root_empty.succeed("jq -r '.certificateInstallPath' /etc/pd-pki/root-yubikey-init-profile.json | grep -Fx '/var/lib/pd-pki/authorities/root/root-ca.cert.pem'")
        root_empty.succeed("jq -r '.archiveBaseDirectory' /etc/pd-pki/root-yubikey-init-profile.json | grep -Fx '/var/lib/pd-pki/custom-yubikey-inventory'")

        root_imported.succeed("test -f /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        root_imported.succeed("test -f /var/lib/pd-pki/authorities/root/root-ca.csr.pem")
        root_imported.succeed("test -f /var/lib/pd-pki/authorities/root/root-ca.cert.pem")
        root_imported.succeed("test ! -e /var/lib/pd-pki/authorities/root/crl.pem")
        root_imported.succeed("test -f /var/lib/pd-pki/authorities/root/root-ca.metadata.json")
        root_imported.succeed("test -f /etc/pd-pki/root-yubikey-init-profile.json")
        root_imported.succeed("jq -r '.subject' /etc/pd-pki/root-yubikey-init-profile.json | grep -Fx '/CN=Pseudo Design Runtime Root CA'")
        root_imported.succeed("jq -r '.validityDays' /etc/pd-pki/root-yubikey-init-profile.json | grep -Fx '7300'")
        root_imported.succeed("jq -r '.slot' /etc/pd-pki/root-yubikey-init-profile.json | grep -Fx '9c'")
        root_imported.succeed("jq -r '.algorithm' /etc/pd-pki/root-yubikey-init-profile.json | grep -Fx 'ECCP384'")
        root_imported.succeed("test -f \"$(jq -r '.pkcs11ModulePath' /etc/pd-pki/root-yubikey-init-profile.json)\"")
        root_imported.succeed("test -d \"$(jq -r '.pkcs11ProviderDirectory' /etc/pd-pki/root-yubikey-init-profile.json)\"")
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
        intermediate.succeed("test ! -e /var/lib/pd-pki/authorities/intermediate/crl.pem")
        intermediate.succeed("test ! -e /var/lib/pd-pki/authorities/intermediate/signer-metadata.json")
        intermediate.succeed("test \"$(stat -c %a /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem)\" = 600")
        intermediate.succeed("case \"$(readlink -f /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem)\" in /nix/store/*) exit 1 ;; *) exit 0 ;; esac")
        intermediate.succeed("openssl req -in /var/lib/pd-pki/authorities/intermediate/intermediate-ca.csr.pem -noout >/dev/null")
        intermediate.succeed("openssl req -in /var/lib/pd-pki/authorities/intermediate/intermediate-ca.csr.pem -noout -text | grep -F 'ASN1 OID: secp384r1'")
        intermediate.succeed("jq -r '.basename' /var/lib/pd-pki/authorities/intermediate/signing-request.json | grep -Fx 'delegated-intermediate'")
        intermediate.succeed("jq -r '.requestedDays' /var/lib/pd-pki/authorities/intermediate/signing-request.json | grep -Fx '3650'")
        intermediate.succeed("jq -r '.csrFile' /var/lib/pd-pki/authorities/intermediate/signing-request.json | grep -Fx 'delegated-intermediate.csr.pem'")
        intermediate.succeed("test -f /run/pd-pki-provisioning/intermediate-ca.key.pem")
        intermediate.succeed("test \"$(openssl pkey -in /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem -pubout -outform der | sha256sum | cut -d' ' -f1)\" = \"$(openssl pkey -in ${intermediateKeyFixture}/intermediate-ca.key.pem -pubout -outform der | sha256sum | cut -d' ' -f1)\"")
        intermediate.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        intermediate.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.cert.pem")

        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/server.key.pem")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/server.csr.pem")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/issuance-request.json")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/san-manifest.json")
        server.succeed("test ! -e /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem")
        server.succeed("test ! -e /var/lib/pd-pki/openvpn-server-leaf/chain.pem")
        server.succeed("test ! -e /var/lib/pd-pki/openvpn-server-leaf/crl.pem")
        server.succeed("test ! -e /var/lib/pd-pki/openvpn-server-leaf/certificate-metadata.json")
        server.succeed("test \"$(stat -c %a /var/lib/pd-pki/openvpn-server-leaf/server.key.pem)\" = 600")
        server.succeed("case \"$(readlink -f /var/lib/pd-pki/openvpn-server-leaf/server.key.pem)\" in /nix/store/*) exit 1 ;; *) exit 0 ;; esac")
        server.succeed("openssl req -in /var/lib/pd-pki/openvpn-server-leaf/server.csr.pem -noout >/dev/null")
        server.succeed("jq -r '.basename' /var/lib/pd-pki/openvpn-server-leaf/issuance-request.json | grep -Fx 'vpn-runtime-server'")
        server.succeed("jq -r '.commonName' /var/lib/pd-pki/openvpn-server-leaf/issuance-request.json | grep -Fx 'vpn.runtime.example.test'")
        server.succeed("jq -r '.requestedDays' /var/lib/pd-pki/openvpn-server-leaf/issuance-request.json | grep -Fx '397'")
        server.succeed("jq -r '.csrFile' /var/lib/pd-pki/openvpn-server-leaf/issuance-request.json | grep -Fx 'vpn-runtime-server.csr.pem'")
        server.succeed("jq -r '.sans[0]' /var/lib/pd-pki/openvpn-server-leaf/san-manifest.json | grep -Fx 'DNS:vpn.runtime.example.test'")
        server.succeed("jq -r '.sans[1]' /var/lib/pd-pki/openvpn-server-leaf/san-manifest.json | grep -Fx 'DNS:openvpn.runtime.example.test'")
        server.succeed("jq -r '.sans[2]' /var/lib/pd-pki/openvpn-server-leaf/san-manifest.json | grep -Fx 'IP:127.0.0.1'")
        server.succeed("test \"$(openssl pkey -in /var/lib/pd-pki/openvpn-server-leaf/server.key.pem -pubout -outform der | sha256sum | cut -d' ' -f1)\" = \"$(openssl pkey -in ${serverKeyFixture}/server.key.pem -pubout -outform der | sha256sum | cut -d' ' -f1)\"")
        server.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        server.succeed("test ! -e /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem")

        client.succeed("test ! -e /var/lib/pd-pki/openvpn-client-leaf/client.key.pem")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/client.csr.pem")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/issuance-request.json")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/identity-manifest.json")
        client.succeed("test ! -e /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem")
        client.succeed("test ! -e /var/lib/pd-pki/openvpn-client-leaf/chain.pem")
        client.succeed("test ! -e /var/lib/pd-pki/openvpn-client-leaf/crl.pem")
        client.succeed("test ! -e /var/lib/pd-pki/openvpn-client-leaf/certificate-metadata.json")
        client.succeed("openssl req -in /var/lib/pd-pki/openvpn-client-leaf/client.csr.pem -noout >/dev/null")
        client.succeed("case \"$(readlink -f /var/lib/pd-pki/openvpn-client-leaf/client.csr.pem)\" in /nix/store/*) exit 1 ;; *) exit 0 ;; esac")
        client.succeed("test \"$(openssl req -in /var/lib/pd-pki/openvpn-client-leaf/client.csr.pem -pubkey -noout | openssl pkey -pubin -outform der | sha256sum | cut -d' ' -f1)\" = \"$(openssl req -in ${clientCsrFixture}/client.csr.pem -pubkey -noout | openssl pkey -pubin -outform der | sha256sum | cut -d' ' -f1)\"")
        client.succeed("test ! -e /var/lib/pd-pki/authorities/root/root-ca.key.pem")
        client.succeed("test ! -e /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem")

        root_imported.succeed("""jq -n '
        {
          schemaVersion: 1,
          roles: {
            "intermediate-signing-authority": {
              defaultDays: 3650,
              maxDays: 3650,
              allowedKeyAlgorithms: ["EC"],
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
        server.succeed("systemctl start pd-pki-server-reload-observer.service")
        server.wait_for_unit("pd-pki-server-reload-observer.service")
        server.succeed("test ! -e /var/lib/pd-pki/openvpn-server-leaf/reload-observer.count")

        intermediate.succeed("pd-pki-signing-tools export-request --role intermediate-signing-authority --state-dir /var/lib/pd-pki/authorities/intermediate --out-dir /tmp/intermediate-request")
        intermediate.copy_from_vm("/tmp/intermediate-request")
        root_imported.copy_from_host(str(Path(out_dir, "intermediate-request")), "/tmp/intermediate-request")
        root_imported.succeed("pd-pki-signing-tools sign-request --request-dir /tmp/intermediate-request --out-dir /tmp/intermediate-signed --issuer-key /var/lib/pd-pki/authorities/root/root-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/root/root-ca.cert.pem --signer-state-dir /var/lib/pd-pki/signer-state/root --policy-file /tmp/root-policy.json --approved-by operator-root")
        root_imported.copy_from_vm("/tmp/intermediate-signed")
        intermediate.copy_from_host(str(Path(out_dir, "intermediate-signed")), "/tmp/intermediate-signed")
        intermediate.succeed("mkdir -p /var/lib/pd-pki/imports")
        intermediate.succeed("cp /tmp/intermediate-signed/delegated-intermediate.cert.pem /var/lib/pd-pki/imports/intermediate.cert.pem")
        intermediate.succeed("cp /tmp/intermediate-signed/chain.pem /var/lib/pd-pki/imports/intermediate.chain.pem")
        intermediate.succeed("cp /tmp/intermediate-signed/metadata.json /var/lib/pd-pki/imports/intermediate.metadata.json")
        intermediate.wait_until_succeeds("test -f /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem")
        intermediate.wait_until_succeeds("systemctl is-active --quiet pd-pki-intermediate-signing-authority-init.service")
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem")
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/chain.pem")
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/signer-metadata.json")
        intermediate.succeed("openssl verify -CAfile /var/lib/pd-pki/authorities/intermediate/chain.pem /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem >/dev/null")
        intermediate.succeed("openssl x509 -in /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem -noout -text | grep -F 'ASN1 OID: secp384r1'")
        intermediate.succeed("openssl x509 -in /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem -noout -text | grep -F 'URI:https://pki.pseudo.test/root.crl'")
        intermediate.succeed("jq -r '.subject' /var/lib/pd-pki/authorities/intermediate/signer-metadata.json | grep -F 'Pseudo Design Runtime Intermediate Signing Authority'")
        root_imported.succeed("test -f /var/lib/pd-pki/signer-state/root/serials/next-serial")
        root_imported.succeed("test \"$(cat /var/lib/pd-pki/signer-state/root/serials/next-serial)\" = 2")
        root_imported.succeed("test -f /var/lib/pd-pki/signer-state/root/serials/allocated/01.json")
        root_imported.succeed("test -f /var/lib/pd-pki/signer-state/root/issuances/01/issuance.json")
        root_imported.succeed("jq -r '.status' /var/lib/pd-pki/signer-state/root/issuances/01/issuance.json | grep -Fx 'issued'")
        root_imported.succeed("test \"$(find /var/lib/pd-pki/signer-state/root/requests -maxdepth 1 -name '*.json' | wc -l | tr -d '[:space:]')\" = 1")
        root_imported.succeed("pd-pki-signing-tools generate-crl --signer-state-dir /var/lib/pd-pki/signer-state/root --issuer-key /var/lib/pd-pki/authorities/root/root-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/root/root-ca.cert.pem --out-dir /tmp/root-crl --days 30")
        root_imported.succeed("test -f /var/lib/pd-pki/signer-state/root/crls/current.pem")
        root_imported.succeed("test -f /var/lib/pd-pki/signer-state/root/crls/metadata.json")
        root_imported.succeed("jq -r '.crlNumber' /var/lib/pd-pki/signer-state/root/crls/metadata.json | grep -Fx '01'")
        root_imported.succeed("test \"$(jq '.revokedSerials | length' /var/lib/pd-pki/signer-state/root/crls/metadata.json)\" = 0")
        root_imported.succeed("mkdir -p /var/lib/pd-pki/imports")
        root_imported.succeed("cp /tmp/root-crl/crl.pem /var/lib/pd-pki/imports/root.crl.pem")
        root_imported.wait_until_succeeds("test -f /var/lib/pd-pki/authorities/root/crl.pem")
        root_imported.wait_until_succeeds("systemctl is-active --quiet pd-pki-root-certificate-authority-init.service")
        root_imported.succeed("test -f /var/lib/pd-pki/authorities/root/crl.pem")
        root_imported.succeed("openssl crl -in /var/lib/pd-pki/authorities/root/crl.pem -noout >/dev/null")

        server.succeed("pd-pki-signing-tools export-request --role openvpn-server-leaf --state-dir /var/lib/pd-pki/openvpn-server-leaf --out-dir /tmp/server-request")
        server.copy_from_vm("/tmp/server-request")
        intermediate.copy_from_host(str(Path(out_dir, "server-request")), "/tmp/server-request")
        intermediate.succeed("if pd-pki-signing-tools sign-request --request-dir /tmp/server-request --out-dir /tmp/server-too-long --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem --issuer-chain /var/lib/pd-pki/authorities/intermediate/chain.pem --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --policy-file /tmp/intermediate-policy.json --approved-by operator-server --days 900 >/tmp/server-too-long.log 2>&1; then exit 1; else exit 0; fi")
        intermediate.succeed("""mkdir -p /tmp/sign-logs
        (
          pd-pki-signing-tools sign-request \
            --request-dir /tmp/server-request \
            --out-dir /tmp/server-signed-a \
            --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem \
            --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem \
            --issuer-chain /var/lib/pd-pki/authorities/intermediate/chain.pem \
            --signer-state-dir /var/lib/pd-pki/signer-state/intermediate \
            --policy-file /tmp/intermediate-policy.json \
            --approved-by operator-server \
            >/tmp/sign-logs/server-a.log 2>&1
        ) &
        pid_a=$!
        (
          pd-pki-signing-tools sign-request \
            --request-dir /tmp/server-request \
            --out-dir /tmp/server-signed-b \
            --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem \
            --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem \
            --issuer-chain /var/lib/pd-pki/authorities/intermediate/chain.pem \
            --signer-state-dir /var/lib/pd-pki/signer-state/intermediate \
            --policy-file /tmp/intermediate-policy.json \
            --approved-by operator-server \
            >/tmp/sign-logs/server-b.log 2>&1
        ) &
        pid_b=$!
        wait "$pid_a"
        wait "$pid_b"
        cmp -s /tmp/server-signed-a/vpn-runtime-server.cert.pem /tmp/server-signed-b/vpn-runtime-server.cert.pem""")
        intermediate.succeed("test \"$(find /var/lib/pd-pki/signer-state/intermediate/requests -maxdepth 1 -name '*.json' | wc -l | tr -d '[:space:]')\" = 1")
        intermediate.succeed("test \"$(find /var/lib/pd-pki/signer-state/intermediate/issuances -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')\" = 1")
        intermediate.copy_from_vm("/tmp/server-signed-a")
        server.copy_from_host(str(Path(out_dir, "server-signed-a")), "/tmp/server-signed")
        server.succeed("mkdir -p /var/lib/pd-pki/imports")
        server.succeed("cp /tmp/server-signed/vpn-runtime-server.cert.pem /var/lib/pd-pki/imports/server.cert.pem")
        server.succeed("cp /tmp/server-signed/chain.pem /var/lib/pd-pki/imports/server.chain.pem")
        server.succeed("cp /tmp/server-signed/metadata.json /var/lib/pd-pki/imports/server.metadata.json")
        server.wait_until_succeeds("test -f /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem")
        server.wait_until_succeeds("systemctl is-active --quiet pd-pki-openvpn-server-leaf-init.service")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/chain.pem")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/certificate-metadata.json")
        server.succeed("openssl verify -CAfile /var/lib/pd-pki/openvpn-server-leaf/chain.pem /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem >/dev/null")
        server.succeed("openssl x509 -in /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem -noout -text | grep -F 'Public-Key: (3072 bit)'")
        server.succeed("openssl x509 -in /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem -noout -text | grep -F 'URI:https://pki.pseudo.test/intermediate.crl'")
        server.wait_until_succeeds("test \"$(cat /var/lib/pd-pki/openvpn-server-leaf/reload-observer.count)\" = 1")
        server.succeed("jq -r '.subject' /var/lib/pd-pki/openvpn-server-leaf/certificate-metadata.json | grep -F 'vpn.runtime.example.test'")

        client.succeed("pd-pki-signing-tools export-request --role openvpn-client-leaf --state-dir /var/lib/pd-pki/openvpn-client-leaf --out-dir /tmp/client-request")
        client.copy_from_vm("/tmp/client-request")
        intermediate.copy_from_host(str(Path(out_dir, "client-request")), "/tmp/client-request")
        intermediate.succeed("cp -R /tmp/client-request /tmp/client-request-invalid-profile")
        intermediate.succeed("tmp_request=$(mktemp) && jq '.requestedProfile = \"serverAuth\"' /tmp/client-request-invalid-profile/request.json > \"$tmp_request\" && mv \"$tmp_request\" /tmp/client-request-invalid-profile/request.json")
        intermediate.succeed("if pd-pki-signing-tools sign-request --request-dir /tmp/client-request-invalid-profile --out-dir /tmp/client-invalid-profile-signed --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem --issuer-chain /var/lib/pd-pki/authorities/intermediate/chain.pem --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --policy-file /tmp/intermediate-policy.json --approved-by operator-client >/tmp/client-invalid-profile.log 2>&1; then exit 1; else exit 0; fi")
        intermediate.succeed("pd-pki-signing-tools sign-request --request-dir /tmp/client-request --out-dir /tmp/client-signed --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem --issuer-chain /var/lib/pd-pki/authorities/intermediate/chain.pem --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --policy-file /tmp/intermediate-policy.json --approved-by operator-client")
        intermediate.copy_from_vm("/tmp/client-signed")
        client.copy_from_host(str(Path(out_dir, "client-signed")), "/tmp/client-signed")
        client.succeed("mkdir -p /var/lib/pd-pki/imports")
        client.succeed("cp /tmp/client-signed/client.cert.pem /var/lib/pd-pki/imports/client.cert.pem")
        client.succeed("cp /tmp/client-signed/chain.pem /var/lib/pd-pki/imports/client.chain.pem")
        client.succeed("cp /tmp/client-signed/metadata.json /var/lib/pd-pki/imports/client.metadata.json")
        client.wait_until_succeeds("test -f /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem")
        client.wait_until_succeeds("systemctl is-active --quiet pd-pki-openvpn-client-leaf-init.service")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/chain.pem")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/certificate-metadata.json")
        client.succeed("openssl verify -CAfile /var/lib/pd-pki/openvpn-client-leaf/chain.pem /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem >/dev/null")
        client.succeed("openssl x509 -in /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem -noout -text | grep -F 'Public-Key: (3072 bit)'")
        client.succeed("openssl x509 -in /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem -noout -text | grep -F 'URI:https://pki.pseudo.test/intermediate.crl'")
        client.succeed("jq -r '.subject' /var/lib/pd-pki/openvpn-client-leaf/certificate-metadata.json | grep -F 'client-01.pseudo.test'")
        server_cert_fingerprint = server.succeed("openssl x509 -in /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem -noout -fingerprint -sha256 | cut -d= -f2").strip()
        server.copy_from_host(str(Path(out_dir, "client-signed")), "/tmp/client-signed-bad")
        server.succeed("cp /tmp/client-signed-bad/client.cert.pem /var/lib/pd-pki/imports/server.cert.pem")
        server.succeed("cp /tmp/client-signed-bad/chain.pem /var/lib/pd-pki/imports/server.chain.pem")
        server.succeed("cp /tmp/client-signed-bad/metadata.json /var/lib/pd-pki/imports/server.metadata.json")
        server.wait_until_succeeds("systemctl show -p Result --value pd-pki-openvpn-server-leaf-refresh.service | grep -Fx 'exit-code'")
        server.succeed(f'test "$(openssl x509 -in /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem -noout -fingerprint -sha256 | cut -d= -f2)" = "{server_cert_fingerprint}"')
        server.succeed("cp /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem /var/lib/pd-pki/imports/server.cert.pem")
        server.succeed("cp /var/lib/pd-pki/openvpn-server-leaf/chain.pem /var/lib/pd-pki/imports/server.chain.pem")
        server.succeed("cp /var/lib/pd-pki/openvpn-server-leaf/certificate-metadata.json /var/lib/pd-pki/imports/server.metadata.json")
        server.wait_until_succeeds("systemctl show -p Result --value pd-pki-openvpn-server-leaf-refresh.service | grep -Fx 'success'")
        server.succeed("test \"$(cat /var/lib/pd-pki/openvpn-server-leaf/reload-observer.count)\" = 1")
        client_metadata_subject = client.succeed("jq -r '.subject' /var/lib/pd-pki/openvpn-client-leaf/certificate-metadata.json").strip()
        client.succeed("tmp_metadata=$(mktemp) && jq '.subject = \"CN=Incorrect Runtime Subject\"' /var/lib/pd-pki/imports/client.metadata.json > \"$tmp_metadata\" && mv \"$tmp_metadata\" /var/lib/pd-pki/imports/client.metadata.json")
        client.wait_until_succeeds("systemctl show -p Result --value pd-pki-openvpn-client-leaf-refresh.service | grep -Fx 'exit-code'")
        client.succeed(f'test "$(jq -r \'.subject\' /var/lib/pd-pki/openvpn-client-leaf/certificate-metadata.json)" = "{client_metadata_subject}"')
        client.succeed("cp /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem /var/lib/pd-pki/imports/client.cert.pem")
        client.succeed("cp /var/lib/pd-pki/openvpn-client-leaf/chain.pem /var/lib/pd-pki/imports/client.chain.pem")
        client.succeed("cp /var/lib/pd-pki/openvpn-client-leaf/certificate-metadata.json /var/lib/pd-pki/imports/client.metadata.json")
        client.wait_until_succeeds("systemctl show -p Result --value pd-pki-openvpn-client-leaf-refresh.service | grep -Fx 'success'")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/serials/next-serial")
        intermediate.succeed("test \"$(cat /var/lib/pd-pki/signer-state/intermediate/serials/next-serial)\" = 3")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/serials/allocated/01.json")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/serials/allocated/02.json")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/issuances/01/issuance.json")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/issuances/02/issuance.json")
        intermediate.succeed("test -d /var/lib/pd-pki/signer-state/intermediate/audit")
        intermediate.succeed("test \"$(find /var/lib/pd-pki/signer-state/intermediate/requests -maxdepth 1 -name '*.json' | wc -l | tr -d '[:space:]')\" = 2")
        intermediate.succeed("jq -r '.status' /var/lib/pd-pki/signer-state/intermediate/issuances/01/issuance.json | grep -Fx 'issued'")
        intermediate.succeed("jq -r '.status' /var/lib/pd-pki/signer-state/intermediate/issuances/02/issuance.json | grep -Fx 'issued'")
        intermediate.succeed("jq -r '.approval.approvedBy' /var/lib/pd-pki/signer-state/intermediate/issuances/02/issuance.json | grep -Fx 'operator-client'")
        intermediate.succeed("test \"$(find /var/lib/pd-pki/signer-state/intermediate/audit -maxdepth 1 -name '*-issued-*.json' | wc -l | tr -d '[:space:]')\" = 2")
        intermediate.succeed("pd-pki-signing-tools revoke-issued --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --serial 2 --reason keyCompromise --revoked-by operator-security --revocation-ticket SEC-42")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/revocations/02.json")
        intermediate.succeed("jq -r '.status' /var/lib/pd-pki/signer-state/intermediate/issuances/02/issuance.json | grep -Fx 'revoked'")
        intermediate.succeed("jq -r '.reason' /var/lib/pd-pki/signer-state/intermediate/revocations/02.json | grep -Fx 'keyCompromise'")
        intermediate.succeed("jq -r '.revocation.revokedBy' /var/lib/pd-pki/signer-state/intermediate/revocations/02.json | grep -Fx 'operator-security'")
        intermediate.succeed("jq -r '.revocation.revocationTicket' /var/lib/pd-pki/signer-state/intermediate/revocations/02.json | grep -Fx 'SEC-42'")
        intermediate.succeed("jq -r '.status' /var/lib/pd-pki/signer-state/intermediate/serials/allocated/02.json | grep -Fx 'revoked'")
        intermediate.succeed("test \"$(find /var/lib/pd-pki/signer-state/intermediate/audit -maxdepth 1 -name '*-revoked-*.json' | wc -l | tr -d '[:space:]')\" = 1")
        intermediate.succeed("if pd-pki-signing-tools sign-request --request-dir /tmp/client-request --out-dir /tmp/client-resigned --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem --issuer-chain /var/lib/pd-pki/authorities/intermediate/chain.pem --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --policy-file /tmp/intermediate-policy.json --approved-by operator-client >/tmp/client-resigned.log 2>&1; then exit 1; else exit 0; fi")
        intermediate.succeed("pd-pki-signing-tools generate-crl --signer-state-dir /var/lib/pd-pki/signer-state/intermediate --issuer-key /var/lib/pd-pki/authorities/intermediate/intermediate-ca.key.pem --issuer-cert /var/lib/pd-pki/authorities/intermediate/intermediate-ca.cert.pem --out-dir /tmp/intermediate-crl --days 30")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/crls/current.pem")
        intermediate.succeed("test -f /var/lib/pd-pki/signer-state/intermediate/crls/metadata.json")
        intermediate.succeed("jq -r '.crlNumber' /var/lib/pd-pki/signer-state/intermediate/crls/metadata.json | grep -Fx '01'")
        intermediate.succeed("jq -r '.revokedSerials[0]' /var/lib/pd-pki/signer-state/intermediate/crls/metadata.json | grep -Fx '02'")
        intermediate.succeed("openssl crl -in /var/lib/pd-pki/signer-state/intermediate/crls/current.pem -noout -text | grep -F 'Serial Number: 02'")
        intermediate.succeed("mkdir -p /var/lib/pd-pki/imports")
        intermediate.succeed("cp /tmp/intermediate-crl/crl.pem /var/lib/pd-pki/imports/intermediate.crl.pem")
        intermediate.wait_until_succeeds("test -f /var/lib/pd-pki/authorities/intermediate/crl.pem")
        intermediate.wait_until_succeeds("systemctl show -p Result --value pd-pki-intermediate-signing-authority-refresh.service | grep -Fx 'success'")
        intermediate.succeed("test -f /var/lib/pd-pki/authorities/intermediate/crl.pem")
        intermediate.succeed("openssl crl -in /var/lib/pd-pki/authorities/intermediate/crl.pem -noout >/dev/null")

        intermediate.copy_from_vm("/tmp/intermediate-crl")
        server.copy_from_host(str(Path(out_dir, "intermediate-crl")), "/tmp/intermediate-crl")
        client.copy_from_host(str(Path(out_dir, "intermediate-crl")), "/tmp/intermediate-crl")
        server.succeed("mkdir -p /var/lib/pd-pki/imports")
        server.succeed("cp /tmp/intermediate-crl/crl.pem /var/lib/pd-pki/imports/intermediate.crl.pem")
        server.wait_until_succeeds("test -f /var/lib/pd-pki/openvpn-server-leaf/crl.pem")
        server.wait_until_succeeds("systemctl show -p Result --value pd-pki-openvpn-server-leaf-refresh.service | grep -Fx 'success'")
        server.succeed("test -f /var/lib/pd-pki/openvpn-server-leaf/crl.pem")
        server.succeed("openssl crl -in /var/lib/pd-pki/openvpn-server-leaf/crl.pem -noout >/dev/null")
        server.succeed("openssl verify -crl_check -CAfile /var/lib/pd-pki/openvpn-server-leaf/chain.pem -CRLfile /var/lib/pd-pki/openvpn-server-leaf/crl.pem /var/lib/pd-pki/openvpn-server-leaf/server.cert.pem >/dev/null")
        server.wait_until_succeeds("test \"$(cat /var/lib/pd-pki/openvpn-server-leaf/reload-observer.count)\" = 2")

        client.succeed("mkdir -p /var/lib/pd-pki/imports")
        client.succeed("cp /tmp/intermediate-crl/crl.pem /var/lib/pd-pki/imports/intermediate.crl.pem")
        client.wait_until_succeeds("test -f /var/lib/pd-pki/openvpn-client-leaf/crl.pem")
        client.wait_until_succeeds("systemctl show -p Result --value pd-pki-openvpn-client-leaf-refresh.service | grep -Fx 'success'")
        client.succeed("test -f /var/lib/pd-pki/openvpn-client-leaf/crl.pem")
        client.succeed("openssl crl -in /var/lib/pd-pki/openvpn-client-leaf/crl.pem -noout >/dev/null")
        client.succeed("if openssl verify -crl_check -CAfile /var/lib/pd-pki/openvpn-client-leaf/chain.pem -CRLfile /var/lib/pd-pki/openvpn-client-leaf/crl.pem /var/lib/pd-pki/openvpn-client-leaf/client.cert.pem >/dev/null 2>&1; then exit 1; else exit 0; fi")
      '';
  }
else
  pkgs.runCommand "module-runtime-artifacts-unsupported" { } ''
    printf '%s\n' "module runtime artifact check is only available on Linux hosts" > "$out"
  ''
