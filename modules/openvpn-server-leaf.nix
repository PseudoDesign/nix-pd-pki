{ config, lib, pkgs, ... }:
let
  runtimeDefaults = import ./runtime-defaults.nix;
  roleModule = import ./mk-role-module.nix {
    roleId = "openvpn-server-leaf";
    optionName = "openvpnServerLeaf";
    packagePath = ../packages/openvpn-server-leaf.nix;
  };
  cfg = config.services.pd-pki.roles.openvpnServerLeaf;
  sanSpec = builtins.concatStringsSep "," cfg.subjectAltNames;
  runtimePaths = {
    directory = cfg.stateDir;
    key = "${cfg.stateDir}/server.key.pem";
    csr = "${cfg.stateDir}/server.csr.pem";
    request = "${cfg.stateDir}/issuance-request.json";
    sanManifest = "${cfg.stateDir}/san-manifest.json";
    certificate = "${cfg.stateDir}/server.cert.pem";
    chain = "${cfg.stateDir}/chain.pem";
    crl = "${cfg.stateDir}/crl.pem";
    metadata = "${cfg.stateDir}/certificate-metadata.json";
  };
  initScript = pkgs.writeShellScript "pd-pki-openvpn-server-leaf-init" ''
    set -euo pipefail
    umask 077

    source ${../packages/pki-workflow-lib.sh}

    state_dir=${lib.escapeShellArg cfg.stateDir}
    lock_file=${lib.escapeShellArg "${runtimeDefaults.baseStateDir}/.runtime-init.lock"}
    key_path=${lib.escapeShellArg runtimePaths.key}
    csr_path=${lib.escapeShellArg runtimePaths.csr}
    request_path=${lib.escapeShellArg runtimePaths.request}
    san_manifest_path=${lib.escapeShellArg runtimePaths.sanManifest}
    cert_path=${lib.escapeShellArg runtimePaths.certificate}
    chain_path=${lib.escapeShellArg runtimePaths.chain}
    crl_path=${lib.escapeShellArg runtimePaths.crl}
    metadata_path=${lib.escapeShellArg runtimePaths.metadata}
    certificate_source_path=${lib.escapeShellArg (if cfg.certificateSourcePath == null then "" else cfg.certificateSourcePath)}
    chain_source_path=${lib.escapeShellArg (if cfg.chainSourcePath == null then "" else cfg.chainSourcePath)}
    crl_source_path=${lib.escapeShellArg (if cfg.crlSourcePath == null then "" else cfg.crlSourcePath)}
    metadata_source_path=${lib.escapeShellArg (if cfg.metadataSourcePath == null then "" else cfg.metadataSourcePath)}

    request_workdir=""
    import_workdir=""
    trap 'rm -rf "$request_workdir" "$import_workdir"' EXIT

    mkdir -p ${lib.escapeShellArg runtimeDefaults.baseStateDir}
    exec 9>"$lock_file"
    flock 9

    mkdir -p "$state_dir"
    chmod 700 "$state_dir"

    if [ -f "$key_path" ] && [ -f "$csr_path" ]; then
      :
    elif [ ! -e "$key_path" ] && [ ! -e "$csr_path" ]; then
      request_workdir="$(mktemp -d)"
      generate_tls_request \
        "$request_workdir" \
        ${lib.escapeShellArg runtimeDefaults.server.basename} \
        ${lib.escapeShellArg cfg.commonName} \
        ${lib.escapeShellArg sanSpec} \
        ${lib.escapeShellArg runtimeDefaults.server.profile}
      cp "$request_workdir/server.key.pem" "$key_path"
      cp "$request_workdir/server.csr.pem" "$csr_path"
      chmod 600 "$key_path"
      chmod 644 "$csr_path"
    else
      printf '%s\n' "Refusing to regenerate a server request from partial state in $state_dir" >&2
      exit 1
    fi

    jq -n \
      --arg commonName ${lib.escapeShellArg cfg.commonName} \
      --argjson sans ${lib.escapeShellArg (builtins.toJSON cfg.subjectAltNames)} \
      '{
        commonName: $commonName,
        sans: $sans
      }' > "$san_manifest_path"
    chmod 644 "$san_manifest_path"

    jq -n \
      --arg schemaVersion "1" \
      --arg roleId "openvpn-server-leaf" \
      --arg requestKind "tls-leaf" \
      --arg basename ${lib.escapeShellArg runtimeDefaults.server.basename} \
      --arg commonName ${lib.escapeShellArg cfg.commonName} \
      --argjson subjectAltNames ${lib.escapeShellArg (builtins.toJSON cfg.subjectAltNames)} \
      --arg requestedProfile ${lib.escapeShellArg runtimeDefaults.server.profile} \
      --arg requestedDays ${lib.escapeShellArg runtimeDefaults.server.days} \
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

    import_workdir="$(mktemp -d)"
    candidate_dir="$import_workdir/server"
    candidate_cert_path="$candidate_dir/server.cert.pem"
    candidate_chain_path="$candidate_dir/chain.pem"
    candidate_crl_path="$candidate_dir/crl.pem"
    candidate_metadata_path="$candidate_dir/certificate-metadata.json"

    prepare_candidate_artifact "$cert_path" "$certificate_source_path" "$candidate_cert_path" 644
    prepare_candidate_artifact "$chain_path" "$chain_source_path" "$candidate_chain_path" 644
    prepare_candidate_artifact "$crl_path" "$crl_source_path" "$candidate_crl_path" 644
    prepare_candidate_artifact "$metadata_path" "$metadata_source_path" "$candidate_metadata_path" 644

    if [ -f "$candidate_cert_path" ] && [ -z "$metadata_source_path" ] && { [ ! -f "$candidate_metadata_path" ] || [ -n "$certificate_source_path" ]; }; then
      write_certificate_metadata "$candidate_cert_path" "$candidate_metadata_path" "openvpn-server-imported"
      chmod 644 "$candidate_metadata_path"
    fi

    validate_tls_runtime_import_state \
      "OpenVPN server" \
      "$csr_path" \
      "$request_path" \
      "$candidate_cert_path" \
      "$candidate_chain_path" \
      "$candidate_crl_path" \
      "$candidate_metadata_path"

    install_candidate_artifact "$candidate_cert_path" "$cert_path" 644
    install_candidate_artifact "$candidate_chain_path" "$chain_path" 644
    install_candidate_artifact "$candidate_crl_path" "$crl_path" 644
    install_candidate_artifact "$candidate_metadata_path" "$metadata_path" 644
  '';
in
{
  imports = [ roleModule ];

  options.services.pd-pki.roles.openvpnServerLeaf = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.server.stateDir;
      description = ''
        Mutable directory where the runtime OpenVPN server keypair and certificate chain live.
      '';
    };

    commonName = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.server.commonName;
      description = ''
        Common name to embed in the runtime OpenVPN server certificate.
      '';
    };

    subjectAltNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = runtimeDefaults.server.subjectAltNames;
      description = ''
        Subject alternative names to embed in the runtime OpenVPN server certificate.
      '';
    };

    generateRuntimeSecrets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to run the runtime initialization service for the OpenVPN server role.
      '';
    };

    certificateSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an externally signed server certificate to stage into the runtime
        state directory.
      '';
    };

    chainSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to a server certificate chain to stage into the runtime state directory.
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
        Optional host path to imported server certificate metadata JSON to stage into the runtime
        state directory.
      '';
    };

    runtimePaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = runtimePaths;
      description = ''
        Runtime paths for the mutable OpenVPN server keypair and chain stored outside the Nix store.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.generateRuntimeSecrets) {
    systemd.services.pd-pki-openvpn-server-leaf-init = {
      description = "Initialize runtime OpenVPN server leaf artifacts for pd-pki";
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
