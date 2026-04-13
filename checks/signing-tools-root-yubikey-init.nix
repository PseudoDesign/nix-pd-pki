{ pkgs, packages }:
pkgs.runCommand "pd-pki-signing-tools-root-yubikey-init-check"
  {
    nativeBuildInputs = [
      pkgs.coreutils
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

    mkdir -p "$workdir/secrets"
    printf '%s\n' '654321' > "$workdir/secrets/pin.txt"
    printf '%s\n' '87654321' > "$workdir/secrets/puk.txt"
    printf '%s\n' 'A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1' > "$workdir/secrets/management-key.txt"
    chmod 600 "$workdir/secrets/pin.txt" "$workdir/secrets/puk.txt" "$workdir/secrets/management-key.txt"

    if pd-pki-signing-tools init-root-yubikey \
      --profile "$workdir/profile.json" \
      --yubikey-serial 51515151 \
      --work-dir "$workdir/no-reviewed-plan" \
      --pin-file "$workdir/secrets/pin.txt" \
      --puk-file "$workdir/secrets/puk.txt" \
      --management-key-file "$workdir/secrets/management-key.txt" \
      --force-reset \
      >"$workdir/no-reviewed-plan.stdout" 2>"$workdir/no-reviewed-plan.stderr"; then
      printf '%s\n' "[signing-tools-root-yubikey-init] expected apply without a reviewed dry-run plan to fail" >&2
      exit 1
    fi
    grep -F 'Reviewed dry-run plan not found in --work-dir' "$workdir/no-reviewed-plan.stderr"

    reviewed_dir="$workdir/reviewed"
    pd-pki-signing-tools init-root-yubikey \
      --profile "$workdir/profile.json" \
      --yubikey-serial 62626262 \
      --work-dir "$reviewed_dir" \
      --dry-run
    reviewed_plan_hash_before="$(sha256sum "$reviewed_dir/root-yubikey-init-plan.json" | cut -d' ' -f1)"

    printf '%s\n' '123456' > "$workdir/secrets/default-pin.txt"
    chmod 600 "$workdir/secrets/default-pin.txt"
    if pd-pki-signing-tools init-root-yubikey \
      --profile "$workdir/profile.json" \
      --yubikey-serial 62626262 \
      --work-dir "$reviewed_dir" \
      --pin-file "$workdir/secrets/default-pin.txt" \
      --puk-file "$workdir/secrets/puk.txt" \
      --management-key-file "$workdir/secrets/management-key.txt" \
      --force-reset \
      >"$workdir/default-pin.stdout" 2>"$workdir/default-pin.stderr"; then
      printf '%s\n' "[signing-tools-root-yubikey-init] expected apply with the factory-default PIN to fail" >&2
      exit 1
    fi
    grep -F 'PIN must not use the factory-default value' "$workdir/default-pin.stderr"
    [ "$reviewed_plan_hash_before" = "$(sha256sum "$reviewed_dir/root-yubikey-init-plan.json" | cut -d' ' -f1)" ]

    insecure_dir="$workdir/insecure-secret"
    pd-pki-signing-tools init-root-yubikey \
      --profile "$workdir/profile.json" \
      --yubikey-serial 73737373 \
      --work-dir "$insecure_dir" \
      --dry-run
    printf '%s\n' '654321' > "$workdir/secrets/insecure-pin.txt"
    chmod 644 "$workdir/secrets/insecure-pin.txt"
    if pd-pki-signing-tools init-root-yubikey \
      --profile "$workdir/profile.json" \
      --yubikey-serial 73737373 \
      --work-dir "$insecure_dir" \
      --pin-file "$workdir/secrets/insecure-pin.txt" \
      --puk-file "$workdir/secrets/puk.txt" \
      --management-key-file "$workdir/secrets/management-key.txt" \
      --force-reset \
      >"$workdir/insecure-pin.stdout" 2>"$workdir/insecure-pin.stderr"; then
      printf '%s\n' "[signing-tools-root-yubikey-init] expected apply with insecure secret file permissions to fail" >&2
      exit 1
    fi
    grep -F 'PIN file permissions are too broad' "$workdir/insecure-pin.stderr"

    existing_install_path="$workdir/existing/root-ca.cert.pem"
    mkdir -p "$(dirname "$existing_install_path")"
    printf '%s\n' 'existing-root' > "$existing_install_path"
    guarded_dir="$workdir/existing-install"
    pd-pki-signing-tools init-root-yubikey \
      --profile "$workdir/profile.json" \
      --yubikey-serial 84848484 \
      --work-dir "$guarded_dir" \
      --certificate-install-path "$existing_install_path" \
      --dry-run
    if pd-pki-signing-tools init-root-yubikey \
      --profile "$workdir/profile.json" \
      --yubikey-serial 84848484 \
      --work-dir "$guarded_dir" \
      --certificate-install-path "$existing_install_path" \
      --pin-file "$workdir/secrets/pin.txt" \
      --puk-file "$workdir/secrets/puk.txt" \
      --management-key-file "$workdir/secrets/management-key.txt" \
      --force-reset \
      >"$workdir/existing-install.stdout" 2>"$workdir/existing-install.stderr"; then
      printf '%s\n' "[signing-tools-root-yubikey-init] expected apply with a pre-existing install target to fail" >&2
      exit 1
    fi
    grep -F 'Certificate install path already exists' "$workdir/existing-install.stderr"

    printf '%s\n' "[signing-tools-root-yubikey-init] root YubiKey init dry-run check passed"
    touch "$out"
  ''
