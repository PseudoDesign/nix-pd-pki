{
  pkgs,
  packages,
}:
if pkgs.stdenv.hostPlatform.isLinux then
  let
    serverBundle = "${packages.openvpn-server-leaf}/steps/package-openvpn-server-deployment-bundle/artifacts/deployment-bundle";
    clientBundle = "${packages.openvpn-client-leaf}/steps/package-openvpn-client-credential-bundle/artifacts/credential-bundle";
  in
  pkgs.testers.runNixOSTest {
    name = "openvpn-mutual-auth";

    nodes = {
      vpn =
        { lib, ... }:
        {
          networking.hostName = "vpn";

          systemd.tmpfiles.rules = [ "d /run/openvpn-mutual-auth 0755 root root -" ];

          services.openvpn.servers.mutual-auth-server = {
            config = ''
              # Keep the control channel local to the VM so the check focuses on TLS auth.
              local 127.0.0.1
              port 1194
              proto udp4
              # Use a dedicated tun device because the client runs in the same guest.
              dev-type tun
              dev ovpnsrv
              topology subnet
              server 10.8.0.0 255.255.255.0
              tls-server
              # Require a real client certificate instead of allowing anonymous access.
              verify-client-cert require
              keepalive 10 60
              persist-key
              persist-tun
              data-ciphers AES-256-GCM:AES-128-GCM
              tls-version-min 1.2
              dh none
              # Reuse the server bundle produced by the PKI workflow under test.
              ca ${serverBundle}/chain.pem
              cert ${serverBundle}/server.cert.pem
              key ${serverBundle}/server.key.pem
              # Record connected client identities so the test can assert mutual auth.
              status /run/openvpn-mutual-auth/status.log
              status-version 2
              verb 3
            '';
          };

          services.openvpn.servers.mutual-auth-client = {
            config = ''
              client
              # Use a separate tun device so client and server can coexist in one VM.
              dev-type tun
              dev ovpncli
              proto udp4
              remote 127.0.0.1 1194
              nobind
              tls-client
              persist-key
              persist-tun
              data-ciphers AES-256-GCM:AES-128-GCM
              tls-version-min 1.2
              # Reuse the client bundle produced by the PKI workflow under test.
              ca ${clientBundle}/chain.pem
              cert ${clientBundle}/client.cert.pem
              key ${clientBundle}/client.key.pem
              # Require the expected server usage and identity, not just any trusted cert.
              remote-cert-tls server
              verify-x509-name vpn.pseudo.test name
              verb 3
            '';
          };

          systemd.services."openvpn-mutual-auth-client" = {
            after = [ "openvpn-mutual-auth-server.service" ];
            requires = [ "openvpn-mutual-auth-server.service" ];
          };

          system.stateVersion = lib.mkDefault "24.11";
        };
    };

    testScript =
      # python
      ''
        start_all()

        vpn.wait_for_unit("openvpn-mutual-auth-server.service")
        vpn.wait_for_unit("openvpn-mutual-auth-client.service")

        vpn.wait_until_succeeds("grep -F 'CLIENT_LIST,client-01.pseudo.test,' /run/openvpn-mutual-auth/status.log")
        vpn.wait_until_succeeds("ip -o -4 addr show dev ovpnsrv | grep -F '10.8.0.1/'")
        vpn.wait_until_succeeds("ip -o -4 addr show dev ovpncli | grep -F '10.8.0.'")
      '';
  }
else
  pkgs.runCommand "openvpn-mutual-auth-unsupported" { } ''
    printf '%s\n' "openvpn mutual-auth check is only available on Linux hosts" > "$out"
  ''
