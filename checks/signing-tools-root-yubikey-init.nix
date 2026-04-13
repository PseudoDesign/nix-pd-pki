{ pkgs, packages }:
pkgs.runCommand "pd-pki-signing-tools-root-yubikey-init-check"
  {
    nativeBuildInputs = [
      packages.pd-pki-signing-tools
      pkgs.gnugrep
      pkgs.jq
    ];
  }
  ''
    set -euo pipefail

    printf '%s\n' "[signing-tools-root-yubikey-init] starting root YubiKey init dry-run check"

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    jq -n '
      {
        schemaVersion: 1,
        profileKind: "root-yubikey-initialization",
        roleId: "root-certificate-authority",
        subject: "/CN=Pseudo Design Dry Run Root CA",
        validityDays: 7300,
        slot: "9c",
        algorithm: "ECCP384",
        pinPolicy: "always",
        touchPolicy: "always",
        pkcs11ModulePath: "/run/current-system/sw/lib/libykcs11.so",
        pkcs11ProviderDirectory: "/run/current-system/sw/lib/ossl-module",
        certificateInstallPath: "/var/lib/pd-pki/authorities/root/root-ca.cert.pem",
        archiveBaseDirectory: "/var/lib/pd-pki/yubikey-inventory"
      }
    ' > "$workdir/profile.json"

    pd-pki-signing-tools init-root-yubikey \
      --profile "$workdir/profile.json" \
      --yubikey-serial 42424242 \
      --work-dir "$workdir/out" \
      --dry-run

    test -f "$workdir/out/root-yubikey-init-plan.json"
    test -f "$workdir/out/root-ca-openssl.cnf"
    test -f "$workdir/out/root-key-uri.txt"
    test -f "$workdir/out/root-yubikey-profile.json"

    jq -r '.command' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx 'init-root-yubikey'
    jq -r '.mode' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx 'dry-run'
    jq -r '.subject' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx '/CN=Pseudo Design Dry Run Root CA'
    jq -r '.validityDays' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx '7300'
    jq -r '.slot' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx '9c'
    jq -r '.routineKeyUri' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx 'pkcs11:token=YubiKey%20PIV;id=%02;type=private'
    jq -r '.archiveDirectory' "$workdir/out/root-yubikey-init-plan.json" | grep -Fx '/var/lib/pd-pki/yubikey-inventory/root-42424242'
    grep -F 'basicConstraints = critical, CA:true' "$workdir/out/root-ca-openssl.cnf"

    printf '%s\n' "[signing-tools-root-yubikey-init] root YubiKey init dry-run check passed"
    touch "$out"
  ''
