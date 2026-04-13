{ config, lib, pkgs, ... }:
let
  runtimeDefaults = import ./runtime-defaults.nix { inherit pkgs; };
  roleModule = import ./mk-role-module.nix {
    roleId = "root-certificate-authority";
    optionName = "rootCertificateAuthority";
    packagePath = ../packages/root-certificate-authority.nix;
  };
  cfg = config.services.pd-pki.roles.rootCertificateAuthority;
  resolvedYubiKeyProfile = {
    schemaVersion = 1;
    profileKind = "root-yubikey-initialization";
    roleId = "root-certificate-authority";
    subject = cfg.yubiKey.subject;
    validityDays = cfg.yubiKey.validityDays;
    slot = cfg.yubiKey.slot;
    algorithm = cfg.yubiKey.algorithm;
    pinPolicy = cfg.yubiKey.pinPolicy;
    touchPolicy = cfg.yubiKey.touchPolicy;
    pkcs11ModulePath = cfg.yubiKey.pkcs11ModulePath;
    pkcs11ProviderDirectory = cfg.yubiKey.pkcs11ProviderDirectory;
    certificateInstallPath = cfg.yubiKey.certificateInstallPath;
    archiveBaseDirectory = cfg.yubiKey.archiveBaseDirectory;
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
  imports = [ roleModule ];

  options.services.pd-pki.roles.rootCertificateAuthority = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.root.stateDir;
      description = ''
        Mutable directory where the runtime root CA keypair and metadata live.
      '';
    };

    yubiKey = lib.mkOption {
      description = ''
        Declarative, non-secret YubiKey initialization profile for the offline root CA ceremony.
        The module exports this profile as machine-readable JSON for future operator tooling.
      '';
      default = { };
      type = lib.types.submodule {
        options = {
          subject = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.root.subject;
            description = ''
              Root subject in OpenSSL slash format for the YubiKey-backed root certificate.
            '';
          };

          validityDays = lib.mkOption {
            type = lib.types.ints.positive;
            default = builtins.fromJSON runtimeDefaults.root.days;
            description = ''
              Root certificate validity period in days for YubiKey initialization.
            '';
          };

          slot = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.root.slot;
            description = ''
              PIV slot to use for the root signing key during YubiKey initialization.
            '';
          };

          algorithm = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.root.algorithm;
            description = ''
              YubiKey PIV key algorithm to request when generating the root signing key.
            '';
          };

          pinPolicy = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.root.pinPolicy;
            description = ''
              PIN policy to set on the root signing key during YubiKey initialization.
            '';
          };

          touchPolicy = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.root.touchPolicy;
            description = ''
              Touch policy to set on the root signing key during YubiKey initialization.
            '';
          };

          pkcs11ModulePath = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.root.pkcs11ModulePath;
            description = ''
              PKCS#11 module path that the offline root tooling should use for the YubiKey token.
            '';
          };

          pkcs11ProviderDirectory = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.root.pkcs11ProviderDirectory;
            description = ''
              OpenSSL provider directory that exposes `pkcs11prov` for the offline root tooling.
            '';
          };

          certificateInstallPath = lib.mkOption {
            type = lib.types.str;
            default = runtimePaths.certificate;
            description = ''
              Destination where the initialized root certificate should be installed for repo use.
            '';
          };

          archiveBaseDirectory = lib.mkOption {
            type = lib.types.str;
            default = runtimeDefaults.root.archiveBaseDirectory;
            description = ''
              Base directory where public YubiKey initialization artifacts should be archived.
            '';
          };
        };
      };
    };

    yubiKeyProfileEtcPath = lib.mkOption {
      type = lib.types.str;
      default = "pd-pki/root-yubikey-init-profile.json";
      description = ''
        Relative path under `/etc` where the exported root YubiKey initialization profile JSON is
        published.
      '';
    };

    yubiKeyProfilePath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/etc/${cfg.yubiKeyProfileEtcPath}";
      description = ''
        Absolute path to the exported root YubiKey initialization profile JSON.
      '';
    };

    yubiKeyProfile = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = resolvedYubiKeyProfile;
      description = ''
        Resolved machine-readable root YubiKey initialization profile derived from the NixOS
        configuration.
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

    provisioningUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Optional systemd units to start and wait for before pd-pki validates and stages runtime
        root artifacts. Use this to order pd-pki after external secret, CSR, or import
        provisioning services.
      '';
    };

    keySourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an existing root private key to stage into the runtime state directory.
      '';
    };

    keyCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to load as a systemd credential containing the root private key. Use
        this instead of `keySourcePath` when the key should only be exposed to the pd-pki runtime
        units.
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

    csrCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to load as a systemd credential containing the root CSR.
      '';
    };

    certificateSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an existing root certificate to stage into the runtime state directory.
      '';
    };

    certificateCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to load as a systemd credential containing the root certificate.
      '';
    };

    crlSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to a root-issued CRL to stage into the runtime state directory.
      '';
    };

    crlCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to load as a systemd credential containing the root-issued CRL.
      '';
    };

    metadataSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to root metadata JSON to stage into the runtime state directory.
      '';
    };

    metadataCredentialPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to load as a systemd credential containing imported root metadata JSON.
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
