{ config, lib, pkgs, ... }:
let
  runtimeDefaults = import ./runtime-defaults.nix { inherit pkgs; };
  roleModule = import ./mk-role-module.nix {
    roleId = "openvpn-server-leaf";
    optionName = "openvpnServerLeaf";
    packagePath = ../packages/openvpn-server-leaf.nix;
  };
  cfg = config.services.pd-pki.roles.openvpnServerLeaf;
  optionPath = [
    "services"
    "pd-pki"
    "roles"
    "openvpnServerLeaf"
  ];
  requestOptionPath = optionPath ++ [ "request" ];
  sanSpec = builtins.concatStringsSep "," cfg.request.subjectAltNames;
  refreshInputs = builtins.filter (value: value != null) [
    cfg.keySourcePath
    cfg.keyCredentialPath
    cfg.csrSourcePath
    cfg.csrCredentialPath
    cfg.certificateSourcePath
    cfg.certificateCredentialPath
    cfg.chainSourcePath
    cfg.chainCredentialPath
    cfg.crlSourcePath
    cfg.crlCredentialPath
    cfg.metadataSourcePath
    cfg.metadataCredentialPath
  ];
  credentialNames = {
    key = "server-key-source";
    csr = "server-csr-source";
    certificate = "server-certificate-source";
    chain = "server-chain-source";
    crl = "server-crl-source";
    metadata = "server-metadata-source";
  };
  loadCredentials = builtins.filter (entry: entry != null) [
    (if cfg.keyCredentialPath == null then null else "${credentialNames.key}:${cfg.keyCredentialPath}")
    (if cfg.csrCredentialPath == null then null else "${credentialNames.csr}:${cfg.csrCredentialPath}")
    (if cfg.certificateCredentialPath == null then null else "${credentialNames.certificate}:${cfg.certificateCredentialPath}")
    (if cfg.chainCredentialPath == null then null else "${credentialNames.chain}:${cfg.chainCredentialPath}")
    (if cfg.crlCredentialPath == null then null else "${credentialNames.crl}:${cfg.crlCredentialPath}")
    (if cfg.metadataCredentialPath == null then null else "${credentialNames.metadata}:${cfg.metadataCredentialPath}")
  ];
  sourceConflictAssertions = [
    {
      assertion = !(cfg.keySourcePath != null && cfg.keyCredentialPath != null);
      message = "openvpnServerLeaf.keySourcePath and openvpnServerLeaf.keyCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.csrSourcePath != null && cfg.csrCredentialPath != null);
      message = "openvpnServerLeaf.csrSourcePath and openvpnServerLeaf.csrCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.certificateSourcePath != null && cfg.certificateCredentialPath != null);
      message = "openvpnServerLeaf.certificateSourcePath and openvpnServerLeaf.certificateCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.chainSourcePath != null && cfg.chainCredentialPath != null);
      message = "openvpnServerLeaf.chainSourcePath and openvpnServerLeaf.chainCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.crlSourcePath != null && cfg.crlCredentialPath != null);
      message = "openvpnServerLeaf.crlSourcePath and openvpnServerLeaf.crlCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.metadataSourcePath != null && cfg.metadataCredentialPath != null);
      message = "openvpnServerLeaf.metadataSourcePath and openvpnServerLeaf.metadataCredentialPath are mutually exclusive";
    }
  ];
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
    key_source_path=${lib.escapeShellArg (if cfg.keySourcePath == null then "" else cfg.keySourcePath)}
    key_credential_name=${lib.escapeShellArg (if cfg.keyCredentialPath == null then "" else credentialNames.key)}
    csr_source_path=${lib.escapeShellArg (if cfg.csrSourcePath == null then "" else cfg.csrSourcePath)}
    csr_credential_name=${lib.escapeShellArg (if cfg.csrCredentialPath == null then "" else credentialNames.csr)}
    certificate_source_path=${lib.escapeShellArg (if cfg.certificateSourcePath == null then "" else cfg.certificateSourcePath)}
    certificate_credential_name=${lib.escapeShellArg (if cfg.certificateCredentialPath == null then "" else credentialNames.certificate)}
    chain_source_path=${lib.escapeShellArg (if cfg.chainSourcePath == null then "" else cfg.chainSourcePath)}
    chain_credential_name=${lib.escapeShellArg (if cfg.chainCredentialPath == null then "" else credentialNames.chain)}
    crl_source_path=${lib.escapeShellArg (if cfg.crlSourcePath == null then "" else cfg.crlSourcePath)}
    crl_credential_name=${lib.escapeShellArg (if cfg.crlCredentialPath == null then "" else credentialNames.crl)}
    metadata_source_path=${lib.escapeShellArg (if cfg.metadataSourcePath == null then "" else cfg.metadataSourcePath)}
    metadata_credential_name=${lib.escapeShellArg (if cfg.metadataCredentialPath == null then "" else credentialNames.metadata)}
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

    key_source_path="$(resolve_artifact_source_path "$key_source_path" "$key_credential_name")"
    csr_source_path="$(resolve_artifact_source_path "$csr_source_path" "$csr_credential_name")"
    certificate_source_path="$(resolve_artifact_source_path "$certificate_source_path" "$certificate_credential_name")"
    chain_source_path="$(resolve_artifact_source_path "$chain_source_path" "$chain_credential_name")"
    crl_source_path="$(resolve_artifact_source_path "$crl_source_path" "$crl_credential_name")"
    metadata_source_path="$(resolve_artifact_source_path "$metadata_source_path" "$metadata_credential_name")"

    mkdir -p "$state_dir"
    chmod 700 "$state_dir"

    jq -n \
      --arg commonName ${lib.escapeShellArg cfg.request.commonName} \
      --argjson sans ${lib.escapeShellArg (builtins.toJSON cfg.request.subjectAltNames)} \
      '{
        commonName: $commonName,
        sans: $sans
      }' > "$san_manifest_path"
    chmod 644 "$san_manifest_path"

    jq -n \
      --arg schemaVersion "1" \
      --arg roleId "openvpn-server-leaf" \
      --arg requestKind "tls-leaf" \
      --arg basename ${lib.escapeShellArg cfg.request.basename} \
      --arg commonName ${lib.escapeShellArg cfg.request.commonName} \
      --argjson subjectAltNames ${lib.escapeShellArg (builtins.toJSON cfg.request.subjectAltNames)} \
      --arg requestedProfile ${lib.escapeShellArg cfg.request.requestedProfile} \
      --arg requestedDays ${lib.escapeShellArg (toString cfg.request.requestedDays)} \
      --arg csrFile ${lib.escapeShellArg "${cfg.request.basename}.csr.pem"} \
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
    request_material_dir="$request_workdir/server-request"
    candidate_key_path="$request_material_dir/${cfg.request.basename}.key.pem"
    candidate_csr_path="$request_material_dir/${cfg.request.basename}.csr.pem"
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
          printf '%s\n' "Provided server CSR does not match the staged private key" >&2
          exit 1
        fi
        rm -f "$candidate_csr_path"
      fi
    fi

    if [ -f "$candidate_csr_path" ] && ! validate_tls_csr_matches_request "$candidate_csr_path" "$request_path"; then
      if [ "$csr_from_source" = "1" ]; then
        printf '%s\n' "Provided server CSR does not match issuance-request.json" >&2
        exit 1
      fi
      if [ -f "$candidate_key_path" ]; then
        rm -f "$candidate_csr_path"
      else
        printf '%s\n' "Staged server CSR does not match issuance-request.json and cannot be regenerated without a private key" >&2
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
        ${lib.escapeShellArg cfg.request.basename} \
        ${lib.escapeShellArg cfg.request.commonName} \
        ${lib.escapeShellArg sanSpec} \
        ${lib.escapeShellArg cfg.request.requestedProfile} \
        "$request_generation_key_path"
    elif [ ! -f "$candidate_csr_path" ]; then
      printf '%s\n' "Server runtime state is missing request material; provide keySourcePath, keyCredentialPath, csrSourcePath, csrCredentialPath, or seed the runtime state first" >&2
      exit 1
    fi

    [ -f "$candidate_csr_path" ] ||
      { printf '%s\n' "Server runtime state is missing a CSR" >&2; exit 1; }
    if [ -f "$candidate_key_path" ]; then
      private_key_matches_csr "$candidate_key_path" "$candidate_csr_path" ||
        { printf '%s\n' "Server private key does not match the staged CSR" >&2; exit 1; }
    fi
    validate_tls_csr_matches_request "$candidate_csr_path" "$request_path" ||
      { printf '%s\n' "Server CSR does not match issuance-request.json" >&2; exit 1; }

    import_workdir="$(mktemp -d)"
    candidate_dir="$import_workdir/server"
    candidate_cert_path="$candidate_dir/server.cert.pem"
    candidate_chain_path="$candidate_dir/chain.pem"
    candidate_crl_path="$candidate_dir/crl.pem"
    candidate_metadata_path="$candidate_dir/certificate-metadata.json"
    managed_digest_before="$(artifact_set_digest "$cert_path" "$chain_path" "$crl_path" "$metadata_path")"

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
  imports = [
    roleModule
    (lib.mkAliasOptionModule (optionPath ++ [ "commonName" ]) (requestOptionPath ++ [ "commonName" ]))
    (lib.mkAliasOptionModule (optionPath ++ [ "subjectAltNames" ]) (requestOptionPath ++ [ "subjectAltNames" ]))
  ];

  options.services.pd-pki.roles.openvpnServerLeaf = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.server.stateDir;
      description = ''
        Mutable directory where the runtime OpenVPN server keypair and certificate chain live.
      '';
    };

    request = lib.mkOption {
      default = { };
      description = ''
        Declarative OpenVPN server request contract. These settings define the exported request
        bundle basename, certificate identity, requested profile, and requested lifetime that
        pd-pki validates before importing a signed server certificate.
      '';
      type = lib.types.submodule {
        options = {
          basename = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.server.basename;
            description = ''
              Public artifact label for the OpenVPN server request bundle. This controls the CSR
              filename and signed certificate basename exchanged with the signer.
            '';
          };

          commonName = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.server.commonName;
            description = ''
              Common name requested for the OpenVPN server certificate.
            '';
          };

          extraSubjectAltNames = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = runtimeDefaults.server.extraSubjectAltNames;
            description = ''
              Additional SAN entries appended to the default `DNS:<commonName>` SAN when
              `subjectAltNames` is not explicitly set.
            '';
          };

          subjectAltNames = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "DNS:${cfg.request.commonName}" ] ++ cfg.request.extraSubjectAltNames;
            description = ''
              Subject alternative names requested for the OpenVPN server certificate. By default
              pd-pki derives this from `commonName` and `extraSubjectAltNames`.
            '';
          };

          requestedProfile = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.server.profile;
            description = ''
              Extended key usage profile requested from the signer for the server certificate.
            '';
          };

          requestedDays = lib.mkOption {
            type = lib.types.ints.positive;
            default = builtins.fromJSON runtimeDefaults.server.days;
            description = ''
              Requested certificate lifetime for the server certificate. Signer policy may shorten
              or reject this request.
            '';
          };
        };
      };
    };

    generateRuntimeSecrets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to run the runtime initialization service for the OpenVPN server role.
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
        Optional systemd units to reload or restart after new validated server artifacts are staged.
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

    provisioningUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Optional systemd units to start and wait for before pd-pki validates and stages runtime
        server artifacts. Use this to order pd-pki after external secret, CSR, or certificate
        provisioning services.
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

    certificateCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to load as a systemd credential containing the server certificate.
      '';
    };

    keySourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an externally managed server private key to stage into the runtime
        state directory before generating or validating the CSR.
      '';
    };

    keyCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to load as a systemd credential containing the server private key.
      '';
    };

    csrSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an externally managed server CSR to stage into the runtime state
        directory. This supports deployments where the server private key is provisioned or held by
        another system and pd-pki should manage only the CSR, certificate chain, and CRL imports.
      '';
    };

    csrCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to load as a systemd credential containing the server CSR.
      '';
    };

    chainSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to a server certificate chain to stage into the runtime state directory.
      '';
    };

    chainCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to load as a systemd credential containing the server certificate chain.
      '';
    };

    crlSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to the issuing CA CRL to stage into the runtime state directory.
      '';
    };

    crlCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to load as a systemd credential containing the issuing CA CRL.
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

    metadataCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to load as a systemd credential containing imported server certificate
        metadata JSON.
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

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = sourceConflictAssertions;
    }
    (lib.mkIf cfg.generateRuntimeSecrets {
      systemd.services.pd-pki-openvpn-server-leaf-init = {
        description = "Initialize runtime OpenVPN server leaf artifacts for pd-pki";
        wantedBy = [ "multi-user.target" ];
        before = [ "multi-user.target" ];
        wants = cfg.provisioningUnits;
        after = cfg.provisioningUnits;
        path = [
          pkgs.coreutils
          pkgs.jq
          pkgs.openssl
          pkgs.systemd
          pkgs.util-linux
        ];
        script = "${initScript}";
        serviceConfig =
          {
            Type = "oneshot";
            RemainAfterExit = true;
          }
          // lib.optionalAttrs (loadCredentials != [ ]) {
            LoadCredential = loadCredentials;
          };
      };

      systemd.services.pd-pki-openvpn-server-leaf-refresh = lib.mkIf (refreshInputs != [ ] && cfg.refreshInterval != null) {
        description = "Refresh runtime OpenVPN server leaf artifacts for pd-pki";
        wants = cfg.provisioningUnits;
        after = [ "pd-pki-openvpn-server-leaf-init.service" ] ++ cfg.provisioningUnits;
        requires = [ "pd-pki-openvpn-server-leaf-init.service" ];
        path = [
          pkgs.coreutils
          pkgs.jq
          pkgs.openssl
          pkgs.systemd
          pkgs.util-linux
        ];
        script = "${initScript}";
        serviceConfig =
          {
            Type = "oneshot";
          }
          // lib.optionalAttrs (loadCredentials != [ ]) {
            LoadCredential = loadCredentials;
          };
      };

      systemd.timers.pd-pki-openvpn-server-leaf-refresh = lib.mkIf (refreshInputs != [ ] && cfg.refreshInterval != null) {
        description = "Periodically reconcile imported OpenVPN server artifacts for pd-pki";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cfg.refreshInterval;
          OnUnitInactiveSec = cfg.refreshInterval;
          Persistent = true;
          Unit = "pd-pki-openvpn-server-leaf-refresh.service";
        };
      };
    })
  ]);
}
