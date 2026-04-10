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
    certificate = "${cfg.stateDir}/intermediate-ca.cert.pem";
    chain = "${cfg.stateDir}/chain.pem";
    metadata = "${cfg.stateDir}/signer-metadata.json";
  };
  rootPaths = {
    key = "${cfg.rootStateDir}/root-ca.key.pem";
    csr = "${cfg.rootStateDir}/root-ca.csr.pem";
    certificate = "${cfg.rootStateDir}/root-ca.cert.pem";
    metadata = "${cfg.rootStateDir}/root-ca.metadata.json";
  };
  initScript = pkgs.writeShellScript "pd-pki-intermediate-signing-authority-init" ''
    set -euo pipefail
    umask 077

    source ${../packages/pki-workflow-lib.sh}

    root_state_dir=${lib.escapeShellArg cfg.rootStateDir}
    state_dir=${lib.escapeShellArg cfg.stateDir}
    lock_file=${lib.escapeShellArg "${runtimeDefaults.baseStateDir}/.runtime-init.lock"}
    root_key=${lib.escapeShellArg rootPaths.key}
    root_csr=${lib.escapeShellArg rootPaths.csr}
    root_cert=${lib.escapeShellArg rootPaths.certificate}
    root_metadata=${lib.escapeShellArg rootPaths.metadata}
    key_path=${lib.escapeShellArg runtimePaths.key}
    csr_path=${lib.escapeShellArg runtimePaths.csr}
    cert_path=${lib.escapeShellArg runtimePaths.certificate}
    chain_path=${lib.escapeShellArg runtimePaths.chain}
    metadata_path=${lib.escapeShellArg runtimePaths.metadata}

    root_workdir=""
    intermediate_workdir=""
    trap 'rm -rf "$root_workdir" "$intermediate_workdir"' EXIT

    mkdir -p ${lib.escapeShellArg runtimeDefaults.baseStateDir}
    exec 9>"$lock_file"
    flock 9

    mkdir -p "$root_state_dir" "$state_dir"
    chmod 700 "$root_state_dir" "$state_dir"

    if [ ! -f "$root_key" ] || [ ! -f "$root_cert" ] || [ ! -f "$root_csr" ] || [ ! -f "$root_metadata" ]; then
      root_workdir="$(mktemp -d)"
      generate_self_signed_ca \
        "$root_workdir" \
        ${lib.escapeShellArg runtimeDefaults.root.basename} \
        ${lib.escapeShellArg runtimeDefaults.root.commonName} \
        ${lib.escapeShellArg runtimeDefaults.root.serial} \
        ${lib.escapeShellArg runtimeDefaults.root.days} \
        ${lib.escapeShellArg runtimeDefaults.root.pathLen}
      cp "$root_workdir/root-ca.key.pem" "$root_key"
      cp "$root_workdir/root-ca.csr.pem" "$root_csr"
      cp "$root_workdir/root-ca.cert.pem" "$root_cert"
      chmod 600 "$root_key"
      chmod 644 "$root_csr" "$root_cert"
      write_certificate_metadata "$root_cert" "$root_metadata" "root-ca-runtime"
      chmod 644 "$root_metadata"
    fi

    if [ -f "$key_path" ] && [ -f "$cert_path" ] && [ -f "$csr_path" ] && [ -f "$chain_path" ] && [ -f "$metadata_path" ]; then
      exit 0
    fi

    intermediate_workdir="$(mktemp -d)"

    generate_signed_ca \
      "$intermediate_workdir" \
      ${lib.escapeShellArg runtimeDefaults.intermediate.basename} \
      ${lib.escapeShellArg runtimeDefaults.intermediate.commonName} \
      ${lib.escapeShellArg runtimeDefaults.intermediate.serial} \
      ${lib.escapeShellArg runtimeDefaults.intermediate.days} \
      ${lib.escapeShellArg runtimeDefaults.intermediate.pathLen} \
      "$root_key" \
      "$root_cert"

    cp "$intermediate_workdir/intermediate-ca.key.pem" "$key_path"
    cp "$intermediate_workdir/intermediate-ca.csr.pem" "$csr_path"
    cp "$intermediate_workdir/intermediate-ca.cert.pem" "$cert_path"
    cp "$intermediate_workdir/chain.pem" "$chain_path"
    chmod 600 "$key_path"
    chmod 644 "$csr_path" "$cert_path" "$chain_path"
    write_certificate_metadata "$cert_path" "$metadata_path" "intermediate-ca-runtime"
    chmod 644 "$metadata_path"
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

    rootStateDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.root.stateDir;
      description = ''
        Mutable directory where the runtime root CA signer lives.
      '';
    };

    generateRuntimeSecrets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to generate simulated runtime intermediate CA material under the mutable state directories.
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
