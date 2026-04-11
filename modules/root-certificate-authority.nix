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
    crl = "${cfg.stateDir}/crl.pem";
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
    crl_path=${lib.escapeShellArg runtimePaths.crl}
    metadata_path=${lib.escapeShellArg runtimePaths.metadata}
    key_source_path=${lib.escapeShellArg (if cfg.keySourcePath == null then "" else cfg.keySourcePath)}
    csr_source_path=${lib.escapeShellArg (if cfg.csrSourcePath == null then "" else cfg.csrSourcePath)}
    certificate_source_path=${lib.escapeShellArg (if cfg.certificateSourcePath == null then "" else cfg.certificateSourcePath)}
    crl_source_path=${lib.escapeShellArg (if cfg.crlSourcePath == null then "" else cfg.crlSourcePath)}
    metadata_source_path=${lib.escapeShellArg (if cfg.metadataSourcePath == null then "" else cfg.metadataSourcePath)}

    mkdir -p ${lib.escapeShellArg runtimeDefaults.baseStateDir}
    exec 9>"$lock_file"
    flock 9

    mkdir -p "$state_dir"
    chmod 700 "$state_dir"

    copy_optional_artifact "$key_source_path" "$key_path" 600
    copy_optional_artifact "$csr_source_path" "$csr_path" 644
    copy_optional_artifact "$certificate_source_path" "$cert_path" 644
    copy_optional_artifact "$crl_source_path" "$crl_path" 644

    if [ -n "$metadata_source_path" ]; then
      copy_optional_artifact "$metadata_source_path" "$metadata_path" 644
    elif [ -f "$cert_path" ]; then
      write_certificate_metadata "$cert_path" "$metadata_path" "root-ca-imported"
      chmod 644 "$metadata_path"
    fi
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
        Whether to run the runtime initialization service for the root role.
      '';
    };

    keySourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an existing root private key to stage into the runtime state directory.
      '';
    };

    csrSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an existing root certificate signing request to stage into the runtime
        state directory.
      '';
    };

    certificateSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an existing root certificate to stage into the runtime state directory.
      '';
    };

    crlSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to a root-issued CRL to stage into the runtime state directory.
      '';
    };

    metadataSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to root metadata JSON to stage into the runtime state directory.
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
