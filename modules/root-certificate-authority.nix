{ config, lib, pkgs, ... }:
let
  runtimeDefaults = import ./runtime-defaults.nix;
  roleModule = import ./mk-role-module.nix {
    roleId = "root-certificate-authority";
    optionName = "rootCertificateAuthority";
    packagePath = ../packages/root-certificate-authority.nix;
  };
  cfg = config.services.pd-pki.roles.rootCertificateAuthority;
  runtimePaths = {
    directory = cfg.stateDir;
    key = "${cfg.stateDir}/root-ca.key.pem";
    csr = "${cfg.stateDir}/root-ca.csr.pem";
    certificate = "${cfg.stateDir}/root-ca.cert.pem";
    metadata = "${cfg.stateDir}/root-ca.metadata.json";
  };
  initScript = pkgs.writeShellScript "pd-pki-root-certificate-authority-init" ''
    set -euo pipefail
    umask 077

    source ${../packages/pki-workflow-lib.sh}

    state_dir=${lib.escapeShellArg cfg.stateDir}
    lock_file=${lib.escapeShellArg "${runtimeDefaults.baseStateDir}/.runtime-init.lock"}
    key_path=${lib.escapeShellArg runtimePaths.key}
    csr_path=${lib.escapeShellArg runtimePaths.csr}
    cert_path=${lib.escapeShellArg runtimePaths.certificate}
    metadata_path=${lib.escapeShellArg runtimePaths.metadata}

    mkdir -p ${lib.escapeShellArg runtimeDefaults.baseStateDir}
    exec 9>"$lock_file"
    flock 9

    mkdir -p "$state_dir"
    chmod 700 "$state_dir"

    if [ -f "$key_path" ] && [ -f "$cert_path" ] && [ -f "$csr_path" ] && [ -f "$metadata_path" ]; then
      exit 0
    fi

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    generate_self_signed_ca \
      "$workdir" \
      ${lib.escapeShellArg runtimeDefaults.root.basename} \
      ${lib.escapeShellArg runtimeDefaults.root.commonName} \
      ${lib.escapeShellArg runtimeDefaults.root.serial} \
      ${lib.escapeShellArg runtimeDefaults.root.days} \
      ${lib.escapeShellArg runtimeDefaults.root.pathLen}

    cp "$workdir/root-ca.key.pem" "$key_path"
    cp "$workdir/root-ca.csr.pem" "$csr_path"
    cp "$workdir/root-ca.cert.pem" "$cert_path"
    chmod 600 "$key_path"
    chmod 644 "$csr_path" "$cert_path"
    write_certificate_metadata "$cert_path" "$metadata_path" "root-ca-runtime"
    chmod 644 "$metadata_path"
  '';
in
{
  imports = [ roleModule ];

  options.services.pd-pki.roles.rootCertificateAuthority = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.root.stateDir;
      description = ''
        Mutable directory where the runtime root CA keypair and metadata live.
      '';
    };

    generateRuntimeSecrets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to generate simulated runtime root CA material under the mutable state directory.
      '';
    };

    runtimePaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = runtimePaths;
      description = ''
        Runtime paths for the mutable root CA artifacts stored outside the Nix store.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.generateRuntimeSecrets) {
    systemd.services.pd-pki-root-certificate-authority-init = {
      description = "Initialize runtime root CA artifacts for pd-pki";
      wantedBy = [ "multi-user.target" ];
      before = [ "multi-user.target" ];
      path = [
        pkgs.coreutils
        pkgs.jq
        pkgs.openssl
        pkgs.util-linux
      ];
      script = "${initScript}";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };
  };
}
