{ config, lib, pkgs, ... }:
let
  runtimeDefaults = import ./runtime-defaults.nix;
  roleModule = import ./mk-role-module.nix {
    roleId = "root-certificate-authority";
    optionName = "rootCertificateAuthority";
    packagePath = ../packages/root-certificate-authority.nix;
  };
  cfg = config.services.pd-pki.roles.rootCertificateAuthority;
  refreshSourcePaths = builtins.filter (path: path != null) [
    cfg.keySourcePath
    cfg.csrSourcePath
    cfg.certificateSourcePath
    cfg.crlSourcePath
    cfg.metadataSourcePath
  ];
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
    consumer_reload_mode=${lib.escapeShellArg cfg.reloadMode}
    managed_digest_before=""
    managed_digest_after=""
    consumer_units=(${lib.concatMapStringsSep " " lib.escapeShellArg cfg.reloadUnits})
    import_workdir=""

    trap 'rm -rf "$import_workdir"' EXIT

    mkdir -p ${lib.escapeShellArg runtimeDefaults.baseStateDir}
    exec 9>"$lock_file"
    flock 9

    mkdir -p "$state_dir"
    chmod 700 "$state_dir"

    import_workdir="$(mktemp -d)"
    candidate_dir="$import_workdir/root"
    candidate_key_path="$candidate_dir/root-ca.key.pem"
    candidate_csr_path="$candidate_dir/root-ca.csr.pem"
    candidate_cert_path="$candidate_dir/root-ca.cert.pem"
    candidate_crl_path="$candidate_dir/crl.pem"
    candidate_metadata_path="$candidate_dir/root-ca.metadata.json"
    managed_digest_before="$(artifact_set_digest "$cert_path" "$crl_path" "$metadata_path")"

    prepare_candidate_artifact "$key_path" "$key_source_path" "$candidate_key_path" 600
    prepare_candidate_artifact "$csr_path" "$csr_source_path" "$candidate_csr_path" 644
    prepare_candidate_artifact "$cert_path" "$certificate_source_path" "$candidate_cert_path" 644
    prepare_candidate_artifact "$crl_path" "$crl_source_path" "$candidate_crl_path" 644
    prepare_candidate_artifact "$metadata_path" "$metadata_source_path" "$candidate_metadata_path" 644

    if [ -f "$candidate_cert_path" ] && [ -z "$metadata_source_path" ] && { [ ! -f "$candidate_metadata_path" ] || [ -n "$certificate_source_path" ]; }; then
      write_certificate_metadata "$candidate_cert_path" "$candidate_metadata_path" "root-ca-imported"
      chmod 644 "$candidate_metadata_path"
    fi

    validate_root_runtime_import_state \
      "$candidate_key_path" \
      "$candidate_csr_path" \
      "$candidate_cert_path" \
      "$candidate_crl_path" \
      "$candidate_metadata_path"

    install_candidate_artifact "$candidate_key_path" "$key_path" 600
    install_candidate_artifact "$candidate_csr_path" "$csr_path" 644
    install_candidate_artifact "$candidate_cert_path" "$cert_path" 644
    install_candidate_artifact "$candidate_crl_path" "$crl_path" 644
    install_candidate_artifact "$candidate_metadata_path" "$metadata_path" 644

    managed_digest_after="$(artifact_set_digest "$cert_path" "$crl_path" "$metadata_path")"
    if [ "$managed_digest_before" != "$managed_digest_after" ] && [ "''${#consumer_units[@]}" -gt 0 ]; then
      reload_systemd_units "$consumer_reload_mode" "''${consumer_units[@]}"
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

    refreshInterval = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "5m";
      description = ''
        How often to re-run runtime validation and staging when imported artifacts are expected.
        Set to `null` to disable automatic refresh.
      '';
    };

    reloadUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Optional systemd units to reload or restart after new validated root artifacts are staged.
      '';
    };

    reloadMode = lib.mkOption {
      type = lib.types.enum [
        "reload"
        "restart"
        "reload-or-restart"
      ];
      default = "reload-or-restart";
      description = ''
        How to apply refreshes to units listed in `reloadUnits`.
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
        pkgs.systemd
        pkgs.util-linux
      ];
      script = "${initScript}";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };

    systemd.services.pd-pki-root-certificate-authority-refresh = lib.mkIf (refreshSourcePaths != [ ] && cfg.refreshInterval != null) {
      description = "Refresh runtime root CA artifacts for pd-pki";
      after = [ "pd-pki-root-certificate-authority-init.service" ];
      requires = [ "pd-pki-root-certificate-authority-init.service" ];
      path = [
        pkgs.coreutils
        pkgs.jq
        pkgs.openssl
        pkgs.systemd
        pkgs.util-linux
      ];
      script = "${initScript}";
      serviceConfig = {
        Type = "oneshot";
      };
    };

    systemd.timers.pd-pki-root-certificate-authority-refresh = lib.mkIf (refreshSourcePaths != [ ] && cfg.refreshInterval != null) {
      description = "Periodically reconcile imported root CA artifacts for pd-pki";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.refreshInterval;
        OnUnitInactiveSec = cfg.refreshInterval;
        Persistent = true;
        Unit = "pd-pki-root-certificate-authority-refresh.service";
      };
    };
  };
}
