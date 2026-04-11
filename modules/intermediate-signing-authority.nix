{ config, lib, pkgs, ... }:
let
  runtimeDefaults = import ./runtime-defaults.nix;
  roleModule = import ./mk-role-module.nix {
    roleId = "intermediate-signing-authority";
    optionName = "intermediateSigningAuthority";
    packagePath = ../packages/intermediate-signing-authority.nix;
  };
  cfg = config.services.pd-pki.roles.intermediateSigningAuthority;
  refreshSourcePaths = builtins.filter (path: path != null) [
    cfg.keySourcePath
    cfg.certificateSourcePath
    cfg.chainSourcePath
    cfg.crlSourcePath
    cfg.metadataSourcePath
  ];
  runtimePaths = {
    directory = cfg.stateDir;
    key = "${cfg.stateDir}/intermediate-ca.key.pem";
    csr = "${cfg.stateDir}/intermediate-ca.csr.pem";
    request = "${cfg.stateDir}/signing-request.json";
    certificate = "${cfg.stateDir}/intermediate-ca.cert.pem";
    chain = "${cfg.stateDir}/chain.pem";
    crl = "${cfg.stateDir}/crl.pem";
    metadata = "${cfg.stateDir}/signer-metadata.json";
  };
  initScript = pkgs.writeShellScript "pd-pki-intermediate-signing-authority-init" ''
    set -euo pipefail
    umask 077

    source ${../packages/pki-workflow-lib.sh}

    state_dir=${lib.escapeShellArg cfg.stateDir}
    lock_file=${lib.escapeShellArg "${runtimeDefaults.baseStateDir}/.runtime-init.lock"}
    key_path=${lib.escapeShellArg runtimePaths.key}
    csr_path=${lib.escapeShellArg runtimePaths.csr}
    request_path=${lib.escapeShellArg runtimePaths.request}
    cert_path=${lib.escapeShellArg runtimePaths.certificate}
    chain_path=${lib.escapeShellArg runtimePaths.chain}
    crl_path=${lib.escapeShellArg runtimePaths.crl}
    metadata_path=${lib.escapeShellArg runtimePaths.metadata}
    key_source_path=${lib.escapeShellArg (if cfg.keySourcePath == null then "" else cfg.keySourcePath)}
    certificate_source_path=${lib.escapeShellArg (if cfg.certificateSourcePath == null then "" else cfg.certificateSourcePath)}
    chain_source_path=${lib.escapeShellArg (if cfg.chainSourcePath == null then "" else cfg.chainSourcePath)}
    crl_source_path=${lib.escapeShellArg (if cfg.crlSourcePath == null then "" else cfg.crlSourcePath)}
    metadata_source_path=${lib.escapeShellArg (if cfg.metadataSourcePath == null then "" else cfg.metadataSourcePath)}
    allow_local_key_generation=${if cfg.allowLocalKeyGeneration then "1" else "0"}
    consumer_reload_mode=${lib.escapeShellArg cfg.reloadMode}
    managed_digest_before=""
    managed_digest_after=""
    consumer_units=(${lib.concatMapStringsSep " " lib.escapeShellArg cfg.reloadUnits})

    intermediate_workdir=""
    import_workdir=""
    trap 'rm -rf "$intermediate_workdir" "$import_workdir"' EXIT

    mkdir -p ${lib.escapeShellArg runtimeDefaults.baseStateDir}
    exec 9>"$lock_file"
    flock 9

    mkdir -p "$state_dir"
    chmod 700 "$state_dir"

    jq -n \
      --arg schemaVersion "1" \
      --arg roleId "intermediate-signing-authority" \
      --arg requestKind "intermediate-ca" \
      --arg basename ${lib.escapeShellArg runtimeDefaults.intermediate.basename} \
      --arg commonName ${lib.escapeShellArg cfg.commonName} \
      --arg pathLen ${lib.escapeShellArg cfg.pathLen} \
      --arg requestedKeyAlgorithm ${lib.escapeShellArg cfg.keyAlgorithm} \
      --arg requestedRsaKeyBits ${lib.escapeShellArg (toString cfg.rsaKeyBits)} \
      --arg requestedDays ${lib.escapeShellArg runtimeDefaults.intermediate.days} \
      --arg csrFile "$(basename "$csr_path")" \
      '{
        schemaVersion: ($schemaVersion | tonumber),
        roleId: $roleId,
        requestKind: $requestKind,
        basename: $basename,
        commonName: $commonName,
        pathLen: ($pathLen | tonumber),
        requestedKeyAlgorithm: $requestedKeyAlgorithm,
        requestedRsaKeyBits: (if $requestedKeyAlgorithm == "rsa" then ($requestedRsaKeyBits | tonumber) else null end),
        requestedDays: ($requestedDays | tonumber),
        csrFile: $csrFile
      }' > "$request_path"
    chmod 644 "$request_path"

    intermediate_workdir="$(mktemp -d)"
    request_material_dir="$intermediate_workdir/intermediate-request"
    candidate_key_path="$request_material_dir/intermediate-ca.key.pem"
    candidate_csr_path="$request_material_dir/intermediate-ca.csr.pem"
    request_generation_key_path=""

    prepare_candidate_artifact "$key_path" "$key_source_path" "$candidate_key_path" 600
    prepare_candidate_artifact "$csr_path" "" "$candidate_csr_path" 644

    if [ -f "$candidate_key_path" ] && [ -f "$candidate_csr_path" ]; then
      if ! private_key_matches_csr "$candidate_key_path" "$candidate_csr_path" || ! validate_intermediate_csr_matches_request "$candidate_csr_path" "$request_path"; then
        rm -f "$candidate_csr_path"
      fi
    fi

    if [ -f "$candidate_key_path" ]; then
      request_generation_key_path="$candidate_key_path"
    elif [ -n "$key_source_path" ] && [ -f "$key_source_path" ]; then
      request_generation_key_path="$key_source_path"
    fi

    if [ -n "$request_generation_key_path" ] && [ ! -f "$candidate_csr_path" ]; then
      generate_ca_request \
        "$request_material_dir" \
        ${lib.escapeShellArg runtimeDefaults.intermediate.basename} \
        ${lib.escapeShellArg cfg.commonName} \
        ${lib.escapeShellArg cfg.pathLen} \
        ${lib.escapeShellArg cfg.keyAlgorithm} \
        ${lib.escapeShellArg (toString cfg.rsaKeyBits)} \
        "$request_generation_key_path"
    elif [ ! -f "$candidate_key_path" ] && [ ! -f "$candidate_csr_path" ]; then
      if [ "$allow_local_key_generation" != "1" ]; then
        printf '%s\n' "Refusing to generate an intermediate key locally; provide keySourcePath or seed the runtime state first" >&2
        exit 1
      fi
      generate_ca_request \
        "$request_material_dir" \
        ${lib.escapeShellArg runtimeDefaults.intermediate.basename} \
        ${lib.escapeShellArg cfg.commonName} \
        ${lib.escapeShellArg cfg.pathLen} \
        ${lib.escapeShellArg cfg.keyAlgorithm} \
        ${lib.escapeShellArg (toString cfg.rsaKeyBits)}
    elif [ ! -f "$candidate_key_path" ] && [ -f "$candidate_csr_path" ] && [ "$allow_local_key_generation" = "1" ] && [ -z "$certificate_source_path" ] && [ ! -f "$cert_path" ]; then
      rm -f "$candidate_csr_path"
      generate_ca_request \
        "$request_material_dir" \
        ${lib.escapeShellArg runtimeDefaults.intermediate.basename} \
        ${lib.escapeShellArg cfg.commonName} \
        ${lib.escapeShellArg cfg.pathLen} \
        ${lib.escapeShellArg cfg.keyAlgorithm} \
        ${lib.escapeShellArg (toString cfg.rsaKeyBits)}
    elif [ ! -f "$candidate_key_path" ] && [ -f "$candidate_csr_path" ]; then
      printf '%s\n' "Refusing to keep an intermediate CSR without a matching private key in $state_dir" >&2
      exit 1
    fi

    private_key_matches_csr "$candidate_key_path" "$candidate_csr_path" ||
      { printf '%s\n' "Intermediate private key does not match the staged CSR" >&2; exit 1; }
    validate_intermediate_csr_matches_request "$candidate_csr_path" "$request_path" ||
      { printf '%s\n' "Intermediate CSR does not match signing-request.json" >&2; exit 1; }

    import_workdir="$(mktemp -d)"
    candidate_dir="$import_workdir/intermediate"
    candidate_cert_path="$candidate_dir/intermediate-ca.cert.pem"
    candidate_chain_path="$candidate_dir/chain.pem"
    candidate_crl_path="$candidate_dir/crl.pem"
    candidate_metadata_path="$candidate_dir/signer-metadata.json"
    managed_digest_before="$(artifact_set_digest "$cert_path" "$chain_path" "$crl_path" "$metadata_path")"

    prepare_candidate_artifact "$cert_path" "$certificate_source_path" "$candidate_cert_path" 644
    prepare_candidate_artifact "$chain_path" "$chain_source_path" "$candidate_chain_path" 644
    prepare_candidate_artifact "$crl_path" "$crl_source_path" "$candidate_crl_path" 644
    prepare_candidate_artifact "$metadata_path" "$metadata_source_path" "$candidate_metadata_path" 644

    if [ -f "$candidate_cert_path" ] && [ -z "$metadata_source_path" ] && { [ ! -f "$candidate_metadata_path" ] || [ -n "$certificate_source_path" ]; }; then
      write_certificate_metadata "$candidate_cert_path" "$candidate_metadata_path" "intermediate-ca-imported"
      chmod 644 "$candidate_metadata_path"
    fi

    validate_intermediate_runtime_import_state \
      "$candidate_key_path" \
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

  options.services.pd-pki.roles.intermediateSigningAuthority = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.intermediate.stateDir;
      description = ''
        Mutable directory where the runtime intermediate CA keypair and metadata live.
      '';
    };

    commonName = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.intermediate.commonName;
      description = ''
        Common name to embed in the runtime intermediate CA certificate signing request.
      '';
    };

    pathLen = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.intermediate.pathLen;
      description = ''
        Path length constraint requested for the runtime intermediate CA certificate.
      '';
    };

    keyAlgorithm = lib.mkOption {
      type = lib.types.enum [
        "rsa"
        "ec-p256"
        "ec-p384"
      ];
      default = runtimeDefaults.intermediate.keyAlgorithm;
      description = ''
        Private key algorithm used when generating the runtime intermediate CSR locally.
      '';
    };

    rsaKeyBits = lib.mkOption {
      type = lib.types.ints.positive;
      default = runtimeDefaults.intermediate.rsaKeyBits;
      description = ''
        RSA modulus size used for locally generated runtime intermediate keys when `keyAlgorithm`
        is `rsa`.
      '';
    };

    generateRuntimeSecrets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to run the runtime initialization service for the intermediate role.
      '';
    };

    allowLocalKeyGeneration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the module may generate a runtime intermediate private key locally when no key is
        provided through `keySourcePath` or the existing runtime state.
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
        Optional systemd units to reload or restart after new validated intermediate artifacts are staged.
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
        Optional host path to an externally signed intermediate certificate to stage into the
        runtime state directory.
      '';
    };

    keySourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an externally managed intermediate private key to stage into the
        runtime state directory before generating or validating the CSR.
      '';
    };

    chainSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an intermediate certificate chain to stage into the runtime state
        directory.
      '';
    };

    crlSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an intermediate-issued CRL to stage into the runtime state
        directory.
      '';
    };

    metadataSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to intermediate metadata JSON to stage into the runtime state directory.
      '';
    };

    runtimePaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = runtimePaths;
      description = ''
        Runtime paths for the mutable intermediate CA artifacts stored outside the Nix store.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.generateRuntimeSecrets) {
    systemd.services.pd-pki-intermediate-signing-authority-init = {
      description = "Initialize runtime intermediate CA artifacts for pd-pki";
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

    systemd.services.pd-pki-intermediate-signing-authority-refresh = lib.mkIf (refreshSourcePaths != [ ] && cfg.refreshInterval != null) {
      description = "Refresh runtime intermediate CA artifacts for pd-pki";
      after = [ "pd-pki-intermediate-signing-authority-init.service" ];
      requires = [ "pd-pki-intermediate-signing-authority-init.service" ];
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

    systemd.timers.pd-pki-intermediate-signing-authority-refresh = lib.mkIf (refreshSourcePaths != [ ] && cfg.refreshInterval != null) {
      description = "Periodically reconcile imported intermediate CA artifacts for pd-pki";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.refreshInterval;
        OnUnitInactiveSec = cfg.refreshInterval;
        Persistent = true;
        Unit = "pd-pki-intermediate-signing-authority-refresh.service";
      };
    };
  };
}
