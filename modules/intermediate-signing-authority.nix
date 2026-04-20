{ config, lib, pkgs, ... }:
let
  runtimeDefaults = import ./runtime-defaults.nix { inherit pkgs; };
  roleModule = import ./mk-role-module.nix {
    roleId = "intermediate-signing-authority";
    optionName = "intermediateSigningAuthority";
    packagePath = ../packages/intermediate-signing-authority.nix;
  };
  cfg = config.services.pd-pki.roles.intermediateSigningAuthority;
  optionPath = [
    "services"
    "pd-pki"
    "roles"
    "intermediateSigningAuthority"
  ];
  requestOptionPath = optionPath ++ [ "request" ];
  supportedRequestKeyAlgorithms = [
    "rsa"
    "ec-p256"
    "ec-p384"
  ];
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
    key = "intermediate-key-source";
    csr = "intermediate-csr-source";
    certificate = "intermediate-certificate-source";
    chain = "intermediate-chain-source";
    crl = "intermediate-crl-source";
    metadata = "intermediate-metadata-source";
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
      message = "intermediateSigningAuthority.keySourcePath and intermediateSigningAuthority.keyCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.csrSourcePath != null && cfg.csrCredentialPath != null);
      message = "intermediateSigningAuthority.csrSourcePath and intermediateSigningAuthority.csrCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.certificateSourcePath != null && cfg.certificateCredentialPath != null);
      message = "intermediateSigningAuthority.certificateSourcePath and intermediateSigningAuthority.certificateCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.chainSourcePath != null && cfg.chainCredentialPath != null);
      message = "intermediateSigningAuthority.chainSourcePath and intermediateSigningAuthority.chainCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.crlSourcePath != null && cfg.crlCredentialPath != null);
      message = "intermediateSigningAuthority.crlSourcePath and intermediateSigningAuthority.crlCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.metadataSourcePath != null && cfg.metadataCredentialPath != null);
      message = "intermediateSigningAuthority.metadataSourcePath and intermediateSigningAuthority.metadataCredentialPath are mutually exclusive";
    }
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

    intermediate_workdir=""
    import_workdir=""
    trap 'rm -rf "$intermediate_workdir" "$import_workdir"' EXIT

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
      --arg schemaVersion "1" \
      --arg roleId "intermediate-signing-authority" \
      --arg requestKind "intermediate-ca" \
      --arg basename ${lib.escapeShellArg cfg.request.basename} \
      --arg commonName ${lib.escapeShellArg cfg.request.commonName} \
      --arg pathLen ${lib.escapeShellArg (toString cfg.request.pathLen)} \
      --arg requestedDays ${lib.escapeShellArg (toString cfg.request.requestedDays)} \
      --arg csrFile ${lib.escapeShellArg "${cfg.request.basename}.csr.pem"} \
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

    intermediate_workdir="$(mktemp -d)"
    request_material_dir="$intermediate_workdir/intermediate-request"
    candidate_key_path="$request_material_dir/intermediate-ca.key.pem"
    candidate_csr_path="$request_material_dir/intermediate-ca.csr.pem"
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
          printf '%s\n' "Provided intermediate CSR does not match the staged private key" >&2
          exit 1
        fi
        rm -f "$candidate_csr_path"
      fi
    fi

    if [ -f "$candidate_csr_path" ] && ! validate_intermediate_csr_matches_request "$candidate_csr_path" "$request_path"; then
      if [ "$csr_from_source" = "1" ]; then
        printf '%s\n' "Provided intermediate CSR does not match signing-request.json" >&2
        exit 1
      fi
      if [ -f "$candidate_key_path" ]; then
        rm -f "$candidate_csr_path"
      else
        printf '%s\n' "Staged intermediate CSR does not match signing-request.json and cannot be regenerated without a private key" >&2
        exit 1
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
        ${lib.escapeShellArg cfg.request.commonName} \
        ${lib.escapeShellArg (toString cfg.request.pathLen)} \
        "$request_generation_key_path" \
        ${lib.escapeShellArg cfg.request.key.algorithm} \
        ${lib.escapeShellArg (toString cfg.request.key.rsaBits)}
    elif [ ! -f "$candidate_csr_path" ]; then
      printf '%s\n' "Intermediate runtime state is missing request material; provide keySourcePath, keyCredentialPath, csrSourcePath, csrCredentialPath, or seed the runtime state first" >&2
      exit 1
    fi

    [ -f "$candidate_csr_path" ] ||
      { printf '%s\n' "Intermediate runtime state is missing a CSR" >&2; exit 1; }
    if [ -f "$candidate_key_path" ]; then
      private_key_matches_csr "$candidate_key_path" "$candidate_csr_path" ||
        { printf '%s\n' "Intermediate private key does not match the staged CSR" >&2; exit 1; }
    fi
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
  imports = [
    roleModule
    (lib.mkAliasOptionModule (optionPath ++ [ "commonName" ]) (requestOptionPath ++ [ "commonName" ]))
    (lib.mkAliasOptionModule (optionPath ++ [ "pathLen" ]) (requestOptionPath ++ [ "pathLen" ]))
  ];

  options.services.pd-pki.roles.intermediateSigningAuthority = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.intermediate.stateDir;
      description = ''
        Authority state for this delegated CA. Changing it changes which intermediate identity,
        pending signing request, imported certificate chain, and revocation material this node
        treats as authoritative.
      '';
    };

    request = lib.mkOption {
      default = { };
      description = ''
        Declarative intermediate CA request contract. These settings define what this node asks
        the root CA to sign and what subject, delegation depth, lifetime request, and key shape
        pd-pki will enforce before accepting the resulting certificate.
      '';
      type = lib.types.submodule {
        options = {
          basename = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.intermediate.basename;
            description = ''
              Public artifact label for the intermediate signing ceremony. This affects the names
              used in exported request bundles and signed return bundles that external tooling and
              operators exchange.
            '';
          };

          commonName = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.intermediate.commonName;
            description = ''
              Subject common name requested for the intermediate CA. pd-pki enforces this against
              the CSR presented to the root signer and against the imported intermediate
              certificate that becomes active on the node.
            '';
          };

          pathLen = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = builtins.fromJSON runtimeDefaults.intermediate.pathLen;
            description = ''
              Delegation depth requested for this intermediate CA. `0` means the intermediate may
              issue only end-entity certificates; larger values permit additional subordinate CA
              layers beneath it.
            '';
          };

          requestedDays = lib.mkOption {
            type = lib.types.ints.positive;
            default = builtins.fromJSON runtimeDefaults.intermediate.days;
            description = ''
              Requested certificate lifetime for the intermediate CA. This is carried to the root
              signer as part of the request contract, though signer policy may shorten it or reject
              it.
            '';
          };

          key = lib.mkOption {
            default = { };
            description = ''
              Cryptographic characteristics of the intermediate CA keypair when pd-pki is
              responsible for generating the CSR locally.
            '';
            type = lib.types.submodule {
              options = {
                algorithm = lib.mkOption {
                  type = lib.types.enum supportedRequestKeyAlgorithms;
                  default = "ec-p384";
                  description = ''
                    Algorithm for a newly generated intermediate CA private key. This determines
                    the CSR public key type that the root signer and signer policy will evaluate.
                  '';
                };

                rsaBits = lib.mkOption {
                  type = lib.types.ints.positive;
                  default = 3072;
                  description = ''
                    RSA modulus size for a locally generated intermediate key. Larger values
                    increase key strength but must still fit the root signer policy and ceremony
                    requirements.
                  '';
                };
              };
            };
          };
        };
      };
    };

    generateRuntimeSecrets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this node should actively maintain the intermediate CA request and imported
        authority material. Disable this when another mechanism fully manages the intermediate CA
        state outside pd-pki.
      '';
    };

    refreshInterval = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "5m";
      description = ''
        How quickly this node should reconcile externally provisioned PKI material such as a new
        intermediate certificate, chain, or CRL. Set to `null` when PKI changes should only be
        adopted on explicit service runs.
      '';
    };

    reloadUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Systemd units for PKI consumers that should react when this intermediate CA's active
        certificate, trust chain, or CRL changes.
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
        How dependent PKI consumers should be nudged when the active intermediate CA material
        changes.
      '';
    };

    provisioningUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        External provisioning steps that establish request inputs or signed authority material
        before pd-pki decides what the current intermediate CA state should be. Use this to order
        pd-pki after secret delivery, CSR generation, or signer-import workflows.
      '';
    };

    certificateSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Externally signed intermediate certificate that should become this node's active delegated
        CA certificate.
      '';
    };

    certificateCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Systemd credential carrying the intermediate certificate that should become the node's
        active delegated CA certificate.
      '';
    };

    keySourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Intermediate private key supplied from outside pd-pki. This determines the actual key
        material behind the CSR and, after signing, the live delegated CA identity on the node.
      '';
    };

    keyCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Systemd credential carrying the intermediate private key that defines the live delegated CA
        identity.
      '';
    };

    csrSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Intermediate CSR supplied from outside pd-pki. Use this when key custody or CSR generation
        happens elsewhere but pd-pki should still enforce the requested subject and CA constraints
        before the request goes to the root signer.
      '';
    };

    csrCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Systemd credential carrying an externally generated intermediate CSR for the root signing
        ceremony.
      '';
    };

    chainSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Certificate chain that anchors the active intermediate CA back to its issuer. This defines
        the trust path that downstream consumers will use for intermediate-issued certificates.
      '';
    };

    chainCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Systemd credential carrying the trust chain that should accompany the active intermediate
        CA certificate.
      '';
    };

    crlSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        CRL issued by this intermediate CA. This controls which previously issued certificates are
        treated as revoked by systems that consume the intermediate's published trust material.
      '';
    };

    crlCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Systemd credential carrying the revocation state published by this intermediate CA.
      '';
    };

    metadataSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Non-secret metadata describing the active intermediate certificate issuance. This is useful
        for audit, provenance, and coordination with external PKI automation.
      '';
    };

    metadataCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Systemd credential carrying audit and provenance metadata for the active intermediate
        certificate.
      '';
    };

    runtimePaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = runtimePaths;
      description = ''
        Read-only map of where this node keeps the active intermediate CA state. External PKI
        automation can use these paths when it needs to hand signed authority material back to
        pd-pki.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = sourceConflictAssertions;
    }
    (lib.mkIf cfg.generateRuntimeSecrets {
      systemd.services.pd-pki-intermediate-signing-authority-init = {
        description = "Initialize runtime intermediate CA artifacts for pd-pki";
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

      systemd.services.pd-pki-intermediate-signing-authority-refresh = lib.mkIf (refreshInputs != [ ] && cfg.refreshInterval != null) {
        description = "Refresh runtime intermediate CA artifacts for pd-pki";
        wants = cfg.provisioningUnits;
        after = [ "pd-pki-intermediate-signing-authority-init.service" ] ++ cfg.provisioningUnits;
        requires = [ "pd-pki-intermediate-signing-authority-init.service" ];
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

      systemd.timers.pd-pki-intermediate-signing-authority-refresh = lib.mkIf (refreshInputs != [ ] && cfg.refreshInterval != null) {
        description = "Periodically reconcile imported intermediate CA artifacts for pd-pki";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cfg.refreshInterval;
          OnUnitInactiveSec = cfg.refreshInterval;
          Persistent = true;
          Unit = "pd-pki-intermediate-signing-authority-refresh.service";
        };
      };
    })
  ]);
}
