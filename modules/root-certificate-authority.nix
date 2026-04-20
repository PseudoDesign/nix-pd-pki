{ config, lib, pkgs, ... }:
let
  runtimeDefaults = import ./runtime-defaults.nix { inherit pkgs; };
  roleModule = import ./mk-role-module.nix {
    roleId = "root-certificate-authority";
    optionName = "rootCertificateAuthority";
    packagePath = ../packages/root-certificate-authority.nix;
  };
  cfg = config.services.pd-pki.roles.rootCertificateAuthority;
  optionPath = [
    "services"
    "pd-pki"
    "roles"
    "rootCertificateAuthority"
  ];
  ceremonyOptionPath = optionPath ++ [ "ceremony" ];
  resolvedYubiKeyProfile = {
    schemaVersion = 1;
    profileKind = "root-yubikey-initialization";
    roleId = "root-certificate-authority";
    subject = cfg.ceremony.subject;
    validityDays = cfg.ceremony.validityDays;
    slot = cfg.ceremony.key.slot;
    algorithm = cfg.ceremony.key.algorithm;
    pinPolicy = cfg.ceremony.key.pinPolicy;
    touchPolicy = cfg.ceremony.key.touchPolicy;
    pkcs11ModulePath = cfg.ceremony.pkcs11.modulePath;
    pkcs11ProviderDirectory = cfg.ceremony.pkcs11.providerDirectory;
    certificateInstallPath = cfg.ceremony.outputs.certificateInstallPath;
    archiveBaseDirectory = cfg.ceremony.outputs.archiveBaseDirectory;
  };
  yubiKeyProfileFile = pkgs.writeText "pd-pki-root-yubikey-init-profile.json" (builtins.toJSON resolvedYubiKeyProfile);
  refreshInputs = builtins.filter (value: value != null) [
    cfg.keySourcePath
    cfg.keyCredentialPath
    cfg.csrSourcePath
    cfg.csrCredentialPath
    cfg.certificateSourcePath
    cfg.certificateCredentialPath
    cfg.crlSourcePath
    cfg.crlCredentialPath
    cfg.metadataSourcePath
    cfg.metadataCredentialPath
  ];
  credentialNames = {
    key = "root-key-source";
    csr = "root-csr-source";
    certificate = "root-certificate-source";
    crl = "root-crl-source";
    metadata = "root-metadata-source";
  };
  loadCredentials = builtins.filter (entry: entry != null) [
    (if cfg.keyCredentialPath == null then null else "${credentialNames.key}:${cfg.keyCredentialPath}")
    (if cfg.csrCredentialPath == null then null else "${credentialNames.csr}:${cfg.csrCredentialPath}")
    (if cfg.certificateCredentialPath == null then null else "${credentialNames.certificate}:${cfg.certificateCredentialPath}")
    (if cfg.crlCredentialPath == null then null else "${credentialNames.crl}:${cfg.crlCredentialPath}")
    (if cfg.metadataCredentialPath == null then null else "${credentialNames.metadata}:${cfg.metadataCredentialPath}")
  ];
  sourceConflictAssertions = [
    {
      assertion = !(cfg.keySourcePath != null && cfg.keyCredentialPath != null);
      message = "rootCertificateAuthority.keySourcePath and rootCertificateAuthority.keyCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.csrSourcePath != null && cfg.csrCredentialPath != null);
      message = "rootCertificateAuthority.csrSourcePath and rootCertificateAuthority.csrCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.certificateSourcePath != null && cfg.certificateCredentialPath != null);
      message = "rootCertificateAuthority.certificateSourcePath and rootCertificateAuthority.certificateCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.crlSourcePath != null && cfg.crlCredentialPath != null);
      message = "rootCertificateAuthority.crlSourcePath and rootCertificateAuthority.crlCredentialPath are mutually exclusive";
    }
    {
      assertion = !(cfg.metadataSourcePath != null && cfg.metadataCredentialPath != null);
      message = "rootCertificateAuthority.metadataSourcePath and rootCertificateAuthority.metadataCredentialPath are mutually exclusive";
    }
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
    key_credential_name=${lib.escapeShellArg (if cfg.keyCredentialPath == null then "" else credentialNames.key)}
    csr_source_path=${lib.escapeShellArg (if cfg.csrSourcePath == null then "" else cfg.csrSourcePath)}
    csr_credential_name=${lib.escapeShellArg (if cfg.csrCredentialPath == null then "" else credentialNames.csr)}
    certificate_source_path=${lib.escapeShellArg (if cfg.certificateSourcePath == null then "" else cfg.certificateSourcePath)}
    certificate_credential_name=${lib.escapeShellArg (if cfg.certificateCredentialPath == null then "" else credentialNames.certificate)}
    crl_source_path=${lib.escapeShellArg (if cfg.crlSourcePath == null then "" else cfg.crlSourcePath)}
    crl_credential_name=${lib.escapeShellArg (if cfg.crlCredentialPath == null then "" else credentialNames.crl)}
    metadata_source_path=${lib.escapeShellArg (if cfg.metadataSourcePath == null then "" else cfg.metadataSourcePath)}
    metadata_credential_name=${lib.escapeShellArg (if cfg.metadataCredentialPath == null then "" else credentialNames.metadata)}
    consumer_reload_mode=${lib.escapeShellArg cfg.reloadMode}
    managed_digest_before=""
    managed_digest_after=""
    consumer_units=(${lib.concatMapStringsSep " " lib.escapeShellArg cfg.reloadUnits})
    import_workdir=""

    trap 'rm -rf "$import_workdir"' EXIT

    mkdir -p ${lib.escapeShellArg runtimeDefaults.baseStateDir}
    exec 9>"$lock_file"
    flock 9

    key_source_path="$(resolve_artifact_source_path "$key_source_path" "$key_credential_name")"
    csr_source_path="$(resolve_artifact_source_path "$csr_source_path" "$csr_credential_name")"
    certificate_source_path="$(resolve_artifact_source_path "$certificate_source_path" "$certificate_credential_name")"
    crl_source_path="$(resolve_artifact_source_path "$crl_source_path" "$crl_credential_name")"
    metadata_source_path="$(resolve_artifact_source_path "$metadata_source_path" "$metadata_credential_name")"

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
  imports = [
    roleModule
    (lib.mkAliasOptionModule (optionPath ++ [ "yubiKey" "subject" ]) (ceremonyOptionPath ++ [ "subject" ]))
    (lib.mkAliasOptionModule (optionPath ++ [ "yubiKey" "validityDays" ]) (ceremonyOptionPath ++ [ "validityDays" ]))
    (lib.mkAliasOptionModule (optionPath ++ [ "yubiKey" "slot" ]) (ceremonyOptionPath ++ [ "key" "slot" ]))
    (lib.mkAliasOptionModule (optionPath ++ [ "yubiKey" "algorithm" ]) (ceremonyOptionPath ++ [ "key" "algorithm" ]))
    (lib.mkAliasOptionModule (optionPath ++ [ "yubiKey" "pinPolicy" ]) (ceremonyOptionPath ++ [ "key" "pinPolicy" ]))
    (lib.mkAliasOptionModule (optionPath ++ [ "yubiKey" "touchPolicy" ]) (ceremonyOptionPath ++ [ "key" "touchPolicy" ]))
    (lib.mkAliasOptionModule (optionPath ++ [ "yubiKey" "pkcs11ModulePath" ]) (ceremonyOptionPath ++ [ "pkcs11" "modulePath" ]))
    (lib.mkAliasOptionModule (optionPath ++ [ "yubiKey" "pkcs11ProviderDirectory" ]) (ceremonyOptionPath ++ [ "pkcs11" "providerDirectory" ]))
    (lib.mkAliasOptionModule (optionPath ++ [ "yubiKey" "certificateInstallPath" ]) (ceremonyOptionPath ++ [ "outputs" "certificateInstallPath" ]))
    (lib.mkAliasOptionModule (optionPath ++ [ "yubiKey" "archiveBaseDirectory" ]) (ceremonyOptionPath ++ [ "outputs" "archiveBaseDirectory" ]))
  ];

  options.services.pd-pki.roles.rootCertificateAuthority = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.root.stateDir;
      description = ''
        Authority state for the active root CA on this node. Changing it changes which root key,
        CSR, trust anchor certificate, CRL, and provenance metadata pd-pki treats as
        authoritative.
      '';
    };

    ceremony = lib.mkOption {
      default = { };
      description = ''
        Declarative root self-signing ceremony contract for the offline YubiKey-backed trust
        anchor. These settings define the root certificate identity, token-backed key behavior,
        PKCS#11 access path, and where public ceremony artifacts are published after
        initialization.
      '';
      type = lib.types.submodule {
        options = {
          subject = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.root.subject;
            description = ''
              Distinguished name for the self-signed root certificate in OpenSSL slash format.
              This becomes the trust anchor identity embedded in every certificate chain issued
              beneath the root.
            '';
          };

          validityDays = lib.mkOption {
            type = lib.types.ints.positive;
            default = builtins.fromJSON runtimeDefaults.root.days;
            description = ''
              Requested lifetime of the self-signed root certificate. Longer lifetimes reduce root
              rotation frequency but keep the same trust anchor active for longer across the fleet.
            '';
          };

          key = lib.mkOption {
            default = { };
            description = ''
              Characteristics of the YubiKey-backed root signing key and the operator controls
              required to use it during future ceremonies.
            '';
            type = lib.types.submodule {
              options = {
                slot = lib.mkOption {
                  type = lib.types.str;
                  default = runtimeDefaults.root.slot;
                  description = ''
                    PIV slot that becomes the canonical location of the root private key on the
                    YubiKey. Future signing and verification workflows identify the root key by
                    this slot.
                  '';
                };

                algorithm = lib.mkOption {
                  type = lib.types.str;
                  default = runtimeDefaults.root.algorithm;
                  description = ''
                    YubiKey key algorithm requested for the root signing key. This determines the
                    public key type and the signature digest family used for the self-signed root
                    certificate.
                  '';
                };

                pinPolicy = lib.mkOption {
                  type = lib.types.str;
                  default = runtimeDefaults.root.pinPolicy;
                  description = ''
                    PIN policy applied to the root signing key. This controls how often operators
                    must authenticate before the root key may be used.
                  '';
                };

                touchPolicy = lib.mkOption {
                  type = lib.types.str;
                  default = runtimeDefaults.root.touchPolicy;
                  description = ''
                    Touch policy applied to the root signing key. This determines whether a
                    physical operator presence check is enforced when the root key signs.
                  '';
                };
              };
            };
          };

          pkcs11 = lib.mkOption {
            default = { };
            description = ''
              PKCS#11 and OpenSSL provider plumbing used by offline root tooling to reach the
              YubiKey-backed root signer.
            '';
            type = lib.types.submodule {
              options = {
                modulePath = lib.mkOption {
                  type = lib.types.str;
                  default = runtimeDefaults.root.pkcs11ModulePath;
                  description = ''
                    PKCS#11 module used by ceremony tooling to discover and operate the YubiKey
                    root signing key.
                  '';
                };

                providerDirectory = lib.mkOption {
                  type = lib.types.str;
                  default = runtimeDefaults.root.pkcs11ProviderDirectory;
                  description = ''
                    OpenSSL provider directory that exposes the `pkcs11` provider needed for the
                    root self-signing and verification toolchain.
                  '';
                };
              };
            };
          };

          outputs = lib.mkOption {
            default = { };
            description = ''
              Publication paths for the public root artifacts produced by the ceremony.
            '';
            type = lib.types.submodule {
              options = {
                certificateInstallPath = lib.mkOption {
                  type = lib.types.str;
                  default = runtimePaths.certificate;
                  description = ''
                    Destination where the ceremony should install the public root certificate that
                    this repo and downstream systems treat as the active trust anchor.
                  '';
                };

                archiveBaseDirectory = lib.mkOption {
                  type = lib.types.str;
                  default = runtimeDefaults.root.archiveBaseDirectory;
                  description = ''
                    Base directory where the ceremony archives the public root inventory and audit
                    artifacts used for later verification and signing workflows.
                  '';
                };
              };
            };
          };
        };
      };
    };

    yubiKeyProfileEtcPath = lib.mkOption {
      type = lib.types.str;
      default = "pd-pki/root-yubikey-init-profile.json";
      description = ''
        Relative path under `/etc` where the exported machine-readable root ceremony profile JSON
        is published for operator tooling.
      '';
    };

    yubiKeyProfilePath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/etc/${cfg.yubiKeyProfileEtcPath}";
      description = ''
        Absolute path to the exported root ceremony profile JSON.
      '';
    };

    yubiKeyProfile = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = resolvedYubiKeyProfile;
      description = ''
        Resolved machine-readable root self-signing ceremony profile derived from the NixOS
        configuration.
      '';
    };

    generateRuntimeSecrets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this node should actively maintain imported root CA state such as the live root
        key, trust anchor certificate, CRL, and provenance metadata.
      '';
    };

    refreshInterval = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "5m";
      description = ''
        How quickly this node should reconcile externally provisioned root PKI material such as a
        new root certificate, CSR, or CRL. Set to `null` when root updates should only be adopted
        on explicit service runs.
      '';
    };

    reloadUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Systemd units for PKI consumers that should react when the active root trust anchor or
        root-issued CRL changes.
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
        How dependent PKI consumers should be nudged when the active root CA material changes.
      '';
    };

    provisioningUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        External provisioning steps that establish root key material, certificate imports, or CRL
        state before pd-pki decides what the current root CA state should be.
      '';
    };

    keySourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Root private key supplied from outside pd-pki. This defines the active trust-anchor key
        material staged on the node.
      '';
    };

    keyCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Systemd credential carrying the root private key that defines the active trust-anchor key
        material.
      '';
    };

    csrSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Root CSR supplied from outside pd-pki. Use this when the root certificate request record
        is generated or preserved by another system but should still be staged with the active root
        state.
      '';
    };

    csrCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Systemd credential carrying an externally generated root CSR for audit or ceremony
        continuity.
      '';
    };

    certificateSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Root certificate that should become the active trust anchor on this node.
      '';
    };

    certificateCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Systemd credential carrying the root certificate that should become the active trust
        anchor on this node.
      '';
    };

    crlSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        CRL issued by the root CA. This controls which root-issued certificates are treated as
        revoked by systems that consume the root trust material.
      '';
    };

    crlCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Systemd credential carrying the revocation state published by the root CA.
      '';
    };

    metadataSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Non-secret metadata describing the active root certificate and its provenance. This is
        useful for audit, inventory, and coordination with external PKI automation.
      '';
    };

    metadataCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Systemd credential carrying audit and provenance metadata for the active root
        certificate.
      '';
    };

    runtimePaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = runtimePaths;
      description = ''
        Read-only map of where this node keeps the active root CA state. External PKI automation
        can use these paths when handing root artifacts back to pd-pki.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = sourceConflictAssertions;
      environment.etc.${cfg.yubiKeyProfileEtcPath}.source = yubiKeyProfileFile;
    }
    (lib.mkIf cfg.generateRuntimeSecrets {
      systemd.services.pd-pki-root-certificate-authority-init = {
        description = "Initialize runtime root CA artifacts for pd-pki";
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

      systemd.services.pd-pki-root-certificate-authority-refresh = lib.mkIf (refreshInputs != [ ] && cfg.refreshInterval != null) {
        description = "Refresh runtime root CA artifacts for pd-pki";
        wants = cfg.provisioningUnits;
        after = [ "pd-pki-root-certificate-authority-init.service" ] ++ cfg.provisioningUnits;
        requires = [ "pd-pki-root-certificate-authority-init.service" ];
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

      systemd.timers.pd-pki-root-certificate-authority-refresh = lib.mkIf (refreshInputs != [ ] && cfg.refreshInterval != null) {
        description = "Periodically reconcile imported root CA artifacts for pd-pki";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cfg.refreshInterval;
          OnUnitInactiveSec = cfg.refreshInterval;
          Persistent = true;
          Unit = "pd-pki-root-certificate-authority-refresh.service";
        };
      };
    })
  ]);
}
