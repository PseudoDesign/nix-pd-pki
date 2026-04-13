{ pkgs ? null }:
let
  baseStateDir = "/var/lib/pd-pki";
  rootPkcs11ModulePath =
    if pkgs == null then
      "/run/current-system/sw/lib/libykcs11.so"
    else
      "${pkgs.yubico-piv-tool}/lib/libykcs11.so";
  rootPkcs11ProviderDirectory =
    if pkgs == null then
      "/run/current-system/sw/lib/ossl-module"
    else
      "${pkgs.libp11}/lib/ossl-module";
in
{
  inherit baseStateDir;

  root = {
    basename = "root-ca";
    commonName = "Pseudo Design Runtime Root CA";
    subject = "/CN=Pseudo Design Runtime Root CA";
    serial = "7001";
    days = "3650";
    pathLen = "1";
    slot = "9c";
    algorithm = "ECCP384";
    pinPolicy = "always";
    touchPolicy = "always";
    pkcs11ModulePath = rootPkcs11ModulePath;
    pkcs11ProviderDirectory = rootPkcs11ProviderDirectory;
    archiveBaseDirectory = "${baseStateDir}/yubikey-inventory";
    stateDir = "${baseStateDir}/authorities/root";
  };

  intermediate = {
    basename = "intermediate-ca";
    commonName = "Pseudo Design Runtime Intermediate Signing Authority";
    serial = "7101";
    days = "1825";
    pathLen = "0";
    stateDir = "${baseStateDir}/authorities/intermediate";
  };

  server = {
    basename = "server";
    commonName = "vpn.pseudo.test";
    serial = "8101";
    days = "825";
    profile = "serverAuth";
    stateDir = "${baseStateDir}/openvpn-server-leaf";
    subjectAltNames = [
      "DNS:vpn.pseudo.test"
      "DNS:openvpn.pseudo.test"
      "IP:127.0.0.1"
    ];
  };

  client = {
    basename = "client";
    commonName = "client-01.pseudo.test";
    serial = "8201";
    days = "825";
    profile = "clientAuth";
    stateDir = "${baseStateDir}/openvpn-client-leaf";
    subjectAltNames = [ "DNS:client-01.pseudo.test" ];
  };
}
