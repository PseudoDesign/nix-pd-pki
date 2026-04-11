{ config, lib, pkgs, ... }:
let
  runtimeDefaults = import ./runtime-defaults.nix;
  roleModule = import ./mk-role-module.nix {
    roleId = "intermediate-signing-authority";
    optionName = "intermediateSigningAuthority";
    packagePath = ../packages/intermediate-signing-authority.nix;
  };
  cfg = config.services.pd-pki.roles.intermediateSigningAuthority;
  runtimePaths = {
    directory = cfg.stateDir;
    key = "${cfg.stateDir}/intermediate-ca.key.pem";
    csr = "${cfg.stateDir}/intermediate-ca.csr.pem";
    request = "${cfg.stateDir}/signing-request.json";
    certificate = "${cfg.stateDir}/intermediate-ca.cert.pem";
    chain = "${cfg.stateDir}/chain.pem";
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
    metadata_path=${lib.escapeShellArg runtimePaths.metadata}
    certificate_source_path=${lib.escapeShellArg (if cfg.certificateSourcePath == null then "" else cfg.certificateSourcePath)}
    chain_source_path=${lib.escapeShellArg (if cfg.chainSourcePath == null then "" else cfg.chainSourcePath)}
    metadata_source_path=${lib.escapeShellArg (if cfg.metadataSourcePath == null then "" else cfg.metadataSourcePath)}

    intermediate_workdir=""
    trap 'rm -rf "$intermediate_workdir"' EXIT

    mkdir -p ${lib.escapeShellArg runtimeDefaults.baseStateDir}
    exec 9>"$lock_file"
    flock 9

    mkdir -p "$state_dir"
    chmod 700 "$state_dir"

    if [ -f "$key_path" ] && [ -f "$csr_path" ]; then
      :
    elif [ ! -e "$key_path" ] && [ ! -e "$csr_path" ]; then
      intermediate_workdir="$(mktemp -d)"
      generate_ca_request \
        "$intermediate_workdir" \
        ${lib.escapeShellArg runtimeDefaults.intermediate.basename} \
        ${lib.escapeShellArg cfg.commonName} \
        ${lib.escapeShellArg cfg.pathLen}
      cp "$intermediate_workdir/intermediate-ca.key.pem" "$key_path"
      cp "$intermediate_workdir/intermediate-ca.csr.pem" "$csr_path"
      chmod 600 "$key_path"
      chmod 644 "$csr_path"
    else
      printf '%s\n' "Refusing to regenerate an intermediate request from partial state in $state_dir" >&2
      exit 1
    fi

    jq -n \
      --arg schemaVersion "1" \
      --arg roleId "intermediate-signing-authority" \
      --arg requestKind "intermediate-ca" \
      --arg basename ${lib.escapeShellArg runtimeDefaults.intermediate.basename} \
      --arg commonName ${lib.escapeShellArg cfg.commonName} \
      --arg pathLen ${lib.escapeShellArg cfg.pathLen} \
      --arg requestedDays ${lib.escapeShellArg runtimeDefaults.intermediate.days} \
      --arg csrFile "$(basename "$csr_path")" \
      '{
        schemaVersion: ($schemaVersion | tonumber),
        roleId: $roleId,
        requestKind: $requestKind,
        basename: $basename,
        commonName: $commonName,
        pathLen: ($pathLen | tonumber),
        requestedDays: ($requestedDays | tonumber),
        csrFile: $csrFile
      }' > "$request_path"
    chmod 644 "$request_path"

    copy_optional_artifact "$certificate_source_path" "$cert_path" 644
    copy_optional_artifact "$chain_source_path" "$chain_path" 644

    if [ -n "$metadata_source_path" ]; then
      copy_optional_artifact "$metadata_source_path" "$metadata_path" 644
    elif [ -f "$cert_path" ]; then
      write_certificate_metadata "$cert_path" "$metadata_path" "intermediate-ca-imported"
      chmod 644 "$metadata_path"
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

    generateRuntimeSecrets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to run the runtime initialization service for the intermediate role.
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

    chainSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an intermediate certificate chain to stage into the runtime state
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
