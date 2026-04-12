{ config, lib, pkgs, ... }:
let
  runtimeDefaults = import ./runtime-defaults.nix;
  roleModule = import ./mk-role-module.nix {
    roleId = "openvpn-client-leaf";
    optionName = "openvpnClientLeaf";
    packagePath = ../packages/openvpn-client-leaf.nix;
  };
  cfg = config.services.pd-pki.roles.openvpnClientLeaf;
  sanSpec = builtins.concatStringsSep "," cfg.subjectAltNames;
  refreshSourcePaths = builtins.filter (path: path != null) [
    cfg.keySourcePath
    cfg.csrSourcePath
    cfg.certificateSourcePath
    cfg.chainSourcePath
    cfg.crlSourcePath
    cfg.metadataSourcePath
  ];
  runtimePaths = {
    directory = cfg.stateDir;
    key = "${cfg.stateDir}/client.key.pem";
    csr = "${cfg.stateDir}/client.csr.pem";
    request = "${cfg.stateDir}/issuance-request.json";
    identityManifest = "${cfg.stateDir}/identity-manifest.json";
    certificate = "${cfg.stateDir}/client.cert.pem";
    chain = "${cfg.stateDir}/chain.pem";
    crl = "${cfg.stateDir}/crl.pem";
    metadata = "${cfg.stateDir}/certificate-metadata.json";
  };
  initScript = pkgs.writeShellScript "pd-pki-openvpn-client-leaf-init" ''
    set -euo pipefail
    umask 077

    source ${../packages/pki-workflow-lib.sh}

    state_dir=${lib.escapeShellArg cfg.stateDir}
    lock_file=${lib.escapeShellArg "${runtimeDefaults.baseStateDir}/.runtime-init.lock"}
    key_path=${lib.escapeShellArg runtimePaths.key}
    csr_path=${lib.escapeShellArg runtimePaths.csr}
    request_path=${lib.escapeShellArg runtimePaths.request}
    identity_manifest_path=${lib.escapeShellArg runtimePaths.identityManifest}
    cert_path=${lib.escapeShellArg runtimePaths.certificate}
    chain_path=${lib.escapeShellArg runtimePaths.chain}
    crl_path=${lib.escapeShellArg runtimePaths.crl}
    metadata_path=${lib.escapeShellArg runtimePaths.metadata}
    key_source_path=${lib.escapeShellArg (if cfg.keySourcePath == null then "" else cfg.keySourcePath)}
    csr_source_path=${lib.escapeShellArg (if cfg.csrSourcePath == null then "" else cfg.csrSourcePath)}
    certificate_source_path=${lib.escapeShellArg (if cfg.certificateSourcePath == null then "" else cfg.certificateSourcePath)}
    chain_source_path=${lib.escapeShellArg (if cfg.chainSourcePath == null then "" else cfg.chainSourcePath)}
    crl_source_path=${lib.escapeShellArg (if cfg.crlSourcePath == null then "" else cfg.crlSourcePath)}
    metadata_source_path=${lib.escapeShellArg (if cfg.metadataSourcePath == null then "" else cfg.metadataSourcePath)}
    consumer_reload_mode=${lib.escapeShellArg cfg.reloadMode}
    managed_digest_before=""
    managed_digest_after=""
    consumer_units=(${lib.concatMapStringsSep " " lib.escapeShellArg cfg.reloadUnits})

    request_workdir=""
    import_workdir=""
    trap 'rm -rf "$request_workdir" "$import_workdir"' EXIT

    mkdir -p ${lib.escapeShellArg runtimeDefaults.baseStateDir}
    exec 9>"$lock_file"
    flock 9

    mkdir -p "$state_dir"
    chmod 700 "$state_dir"

    jq -n \
      --arg identity ${lib.escapeShellArg cfg.commonName} \
      --argjson subjectAltNames ${lib.escapeShellArg (builtins.toJSON cfg.subjectAltNames)} \
      '{
        identity: $identity,
        subjectAltNames: $subjectAltNames
      }' > "$identity_manifest_path"
    chmod 644 "$identity_manifest_path"

    jq -n \
      --arg schemaVersion "1" \
      --arg roleId "openvpn-client-leaf" \
      --arg requestKind "tls-leaf" \
      --arg basename ${lib.escapeShellArg runtimeDefaults.client.basename} \
      --arg commonName ${lib.escapeShellArg cfg.commonName} \
      --argjson subjectAltNames ${lib.escapeShellArg (builtins.toJSON cfg.subjectAltNames)} \
      --arg requestedProfile ${lib.escapeShellArg runtimeDefaults.client.profile} \
      --arg requestedDays ${lib.escapeShellArg runtimeDefaults.client.days} \
      --arg csrFile "$(basename "$csr_path")" \
      '{
        schemaVersion: ($schemaVersion | tonumber),
        roleId: $roleId,
        requestKind: $requestKind,
        basename: $basename,
        commonName: $commonName,
        subjectAltNames: $subjectAltNames,
        requestedProfile: $requestedProfile,
        requestedDays: ($requestedDays | tonumber),
        csrFile: $csrFile
      }' > "$request_path"
    chmod 644 "$request_path"

    request_workdir="$(mktemp -d)"
    request_material_dir="$request_workdir/client-request"
    candidate_key_path="$request_material_dir/client.key.pem"
    candidate_csr_path="$request_material_dir/client.csr.pem"
    request_generation_key_path=""
    csr_from_source=0

    prepare_candidate_artifact "$key_path" "$key_source_path" "$candidate_key_path" 600
    prepare_candidate_artifact "$csr_path" "$csr_source_path" "$candidate_csr_path" 644

    if [ -n "$csr_source_path" ] && [ -f "$csr_source_path" ]; then
      csr_from_source=1
    fi

    if [ -f "$candidate_key_path" ] && [ -f "$candidate_csr_path" ]; then
      if ! private_key_matches_csr "$candidate_key_path" "$candidate_csr_path"; then
        if [ "$csr_from_source" = "1" ]; then
          printf '%s\n' "Provided client CSR does not match the staged private key" >&2
          exit 1
        fi
        rm -f "$candidate_csr_path"
      fi
    fi

    if [ -f "$candidate_csr_path" ] && ! validate_tls_csr_matches_request "$candidate_csr_path" "$request_path"; then
      if [ "$csr_from_source" = "1" ]; then
        printf '%s\n' "Provided client CSR does not match issuance-request.json" >&2
        exit 1
      fi
      if [ -f "$candidate_key_path" ]; then
        rm -f "$candidate_csr_path"
      else
        printf '%s\n' "Staged client CSR does not match issuance-request.json and cannot be regenerated without a private key" >&2
        exit 1
      fi
    fi

    if [ -f "$candidate_key_path" ]; then
      request_generation_key_path="$candidate_key_path"
    elif [ -n "$key_source_path" ] && [ -f "$key_source_path" ]; then
      request_generation_key_path="$key_source_path"
    fi

    if [ -n "$request_generation_key_path" ] && [ ! -f "$candidate_csr_path" ]; then
      generate_tls_request \
        "$request_material_dir" \
        ${lib.escapeShellArg runtimeDefaults.client.basename} \
        ${lib.escapeShellArg cfg.commonName} \
        ${lib.escapeShellArg sanSpec} \
        ${lib.escapeShellArg runtimeDefaults.client.profile} \
        "$request_generation_key_path"
    elif [ ! -f "$candidate_csr_path" ]; then
      printf '%s\n' "Client runtime state is missing request material; provide keySourcePath, csrSourcePath, or seed the runtime state first" >&2
      exit 1
    fi

    [ -f "$candidate_csr_path" ] ||
      { printf '%s\n' "Client runtime state is missing a CSR" >&2; exit 1; }
    if [ -f "$candidate_key_path" ]; then
      private_key_matches_csr "$candidate_key_path" "$candidate_csr_path" ||
        { printf '%s\n' "Client private key does not match the staged CSR" >&2; exit 1; }
    fi
    validate_tls_csr_matches_request "$candidate_csr_path" "$request_path" ||
      { printf '%s\n' "Client CSR does not match issuance-request.json" >&2; exit 1; }

    import_workdir="$(mktemp -d)"
    candidate_dir="$import_workdir/client"
    candidate_cert_path="$candidate_dir/client.cert.pem"
    candidate_chain_path="$candidate_dir/chain.pem"
    candidate_crl_path="$candidate_dir/crl.pem"
    candidate_metadata_path="$candidate_dir/certificate-metadata.json"
    managed_digest_before="$(artifact_set_digest "$cert_path" "$chain_path" "$crl_path" "$metadata_path")"

    prepare_candidate_artifact "$cert_path" "$certificate_source_path" "$candidate_cert_path" 644
    prepare_candidate_artifact "$chain_path" "$chain_source_path" "$candidate_chain_path" 644
    prepare_candidate_artifact "$crl_path" "$crl_source_path" "$candidate_crl_path" 644
    prepare_candidate_artifact "$metadata_path" "$metadata_source_path" "$candidate_metadata_path" 644

    if [ -f "$candidate_cert_path" ] && [ -z "$metadata_source_path" ] && { [ ! -f "$candidate_metadata_path" ] || [ -n "$certificate_source_path" ]; }; then
      write_certificate_metadata "$candidate_cert_path" "$candidate_metadata_path" "openvpn-client-imported"
      chmod 644 "$candidate_metadata_path"
    fi

    validate_tls_runtime_import_state \
      "OpenVPN client" \
      "$candidate_csr_path" \
      "$request_path" \
      "$candidate_cert_path" \
      "$candidate_chain_path" \
      "$candidate_crl_path" \
      "$candidate_metadata_path"

    install_candidate_artifact "$candidate_key_path" "$key_path" 600
    install_candidate_artifact "$candidate_csr_path" "$csr_path" 644
    install_candidate_artifact "$candidate_cert_path" "$cert_path" 644
    install_candidate_artifact "$candidate_chain_path" "$chain_path" 644
    install_candidate_artifact "$candidate_crl_path" "$crl_path" 644
    install_candidate_artifact "$candidate_metadata_path" "$metadata_path" 644

    managed_digest_after="$(artifact_set_digest "$cert_path" "$chain_path" "$crl_path" "$metadata_path")"
    if [ "$managed_digest_before" != "$managed_digest_after" ] && [ "''${#consumer_units[@]}" -gt 0 ]; then
      reload_systemd_units "$consumer_reload_mode" "''${consumer_units[@]}"
    fi
  '';
in
{
  imports = [ roleModule ];

  options.services.pd-pki.roles.openvpnClientLeaf = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.client.stateDir;
      description = ''
        Mutable directory where the runtime OpenVPN client keypair and certificate chain live.
      '';
    };

    commonName = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.client.commonName;
      description = ''
        Common name to embed in the runtime OpenVPN client certificate.
      '';
    };

    subjectAltNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = runtimeDefaults.client.subjectAltNames;
      description = ''
        Subject alternative names to embed in the runtime OpenVPN client certificate.
      '';
    };

    generateRuntimeSecrets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to run the runtime initialization service for the OpenVPN client role.
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
        Optional systemd units to reload or restart after new validated client artifacts are staged.
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

    certificateSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an externally signed client certificate to stage into the runtime
        state directory.
      '';
    };

    keySourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an externally managed client private key to stage into the runtime
        state directory before generating or validating the CSR.
      '';
    };

    csrSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an externally managed client CSR to stage into the runtime state
        directory. This supports deployments where the client private key is provisioned or held by
        another system and pd-pki should manage only the CSR, certificate chain, and CRL imports.
      '';
    };

    chainSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to a client certificate chain to stage into the runtime state directory.
      '';
    };

    crlSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to the issuing CA CRL to stage into the runtime state directory.
      '';
    };

    metadataSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to imported client certificate metadata JSON to stage into the runtime
        state directory.
      '';
    };

    runtimePaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = runtimePaths;
      description = ''
        Runtime paths for the mutable OpenVPN client keypair and chain stored outside the Nix store.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.generateRuntimeSecrets) {
    systemd.services.pd-pki-openvpn-client-leaf-init = {
      description = "Initialize runtime OpenVPN client leaf artifacts for pd-pki";
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

    systemd.services.pd-pki-openvpn-client-leaf-refresh = lib.mkIf (refreshSourcePaths != [ ] && cfg.refreshInterval != null) {
      description = "Refresh runtime OpenVPN client leaf artifacts for pd-pki";
      after = [ "pd-pki-openvpn-client-leaf-init.service" ];
      requires = [ "pd-pki-openvpn-client-leaf-init.service" ];
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

    systemd.timers.pd-pki-openvpn-client-leaf-refresh = lib.mkIf (refreshSourcePaths != [ ] && cfg.refreshInterval != null) {
      description = "Periodically reconcile imported OpenVPN client artifacts for pd-pki";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.refreshInterval;
        OnUnitInactiveSec = cfg.refreshInterval;
        Persistent = true;
        Unit = "pd-pki-openvpn-client-leaf-refresh.service";
      };
    };
  };
}
