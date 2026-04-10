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
    certificate = "${cfg.stateDir}/server.cert.pem";
    chain = "${cfg.stateDir}/chain.pem";
  };
  rootPaths = {
    key = "${cfg.rootStateDir}/root-ca.key.pem";
    csr = "${cfg.rootStateDir}/root-ca.csr.pem";
    certificate = "${cfg.rootStateDir}/root-ca.cert.pem";
    metadata = "${cfg.rootStateDir}/root-ca.metadata.json";
  };
  intermediatePaths = {
    key = "${cfg.intermediateStateDir}/intermediate-ca.key.pem";
    csr = "${cfg.intermediateStateDir}/intermediate-ca.csr.pem";
    certificate = "${cfg.intermediateStateDir}/intermediate-ca.cert.pem";
    chain = "${cfg.intermediateStateDir}/chain.pem";
    metadata = "${cfg.intermediateStateDir}/signer-metadata.json";
  };
  initScript = pkgs.writeShellScript "pd-pki-openvpn-server-leaf-init" ''
    set -euo pipefail
    umask 077

    source ${../packages/pki-workflow-lib.sh}

    root_state_dir=${lib.escapeShellArg cfg.rootStateDir}
    intermediate_state_dir=${lib.escapeShellArg cfg.intermediateStateDir}
    state_dir=${lib.escapeShellArg cfg.stateDir}
    lock_file=${lib.escapeShellArg "${runtimeDefaults.baseStateDir}/.runtime-init.lock"}
    root_key=${lib.escapeShellArg rootPaths.key}
    root_csr=${lib.escapeShellArg rootPaths.csr}
    root_cert=${lib.escapeShellArg rootPaths.certificate}
    root_metadata=${lib.escapeShellArg rootPaths.metadata}
    intermediate_key=${lib.escapeShellArg intermediatePaths.key}
    intermediate_csr=${lib.escapeShellArg intermediatePaths.csr}
    intermediate_cert=${lib.escapeShellArg intermediatePaths.certificate}
    intermediate_chain=${lib.escapeShellArg intermediatePaths.chain}
    intermediate_metadata=${lib.escapeShellArg intermediatePaths.metadata}
    key_path=${lib.escapeShellArg runtimePaths.key}
    csr_path=${lib.escapeShellArg runtimePaths.csr}
    cert_path=${lib.escapeShellArg runtimePaths.certificate}
    chain_path=${lib.escapeShellArg runtimePaths.chain}

    root_workdir=""
    intermediate_workdir=""
    request_workdir=""
    leaf_workdir=""
    trap 'rm -rf "$root_workdir" "$intermediate_workdir" "$request_workdir" "$leaf_workdir"' EXIT

    mkdir -p ${lib.escapeShellArg runtimeDefaults.baseStateDir}
    exec 9>"$lock_file"
    flock 9

    mkdir -p "$root_state_dir" "$intermediate_state_dir" "$state_dir"
    chmod 700 "$root_state_dir" "$intermediate_state_dir" "$state_dir"

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

    if [ ! -f "$intermediate_key" ] || [ ! -f "$intermediate_cert" ] || [ ! -f "$intermediate_csr" ] || [ ! -f "$intermediate_chain" ] || [ ! -f "$intermediate_metadata" ]; then
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
      cp "$intermediate_workdir/intermediate-ca.key.pem" "$intermediate_key"
      cp "$intermediate_workdir/intermediate-ca.csr.pem" "$intermediate_csr"
      cp "$intermediate_workdir/intermediate-ca.cert.pem" "$intermediate_cert"
      cp "$intermediate_workdir/chain.pem" "$intermediate_chain"
      chmod 600 "$intermediate_key"
      chmod 644 "$intermediate_csr" "$intermediate_cert" "$intermediate_chain"
      write_certificate_metadata "$intermediate_cert" "$intermediate_metadata" "intermediate-ca-runtime"
      chmod 644 "$intermediate_metadata"
    fi

    if [ -f "$key_path" ] && [ -f "$cert_path" ] && [ -f "$csr_path" ] && [ -f "$chain_path" ]; then
      exit 0
    fi

    request_workdir="$(mktemp -d)"
    leaf_workdir="$(mktemp -d)"

    generate_tls_request \
      "$request_workdir" \
      ${lib.escapeShellArg runtimeDefaults.server.basename} \
      ${lib.escapeShellArg cfg.commonName} \
      ${lib.escapeShellArg sanSpec} \
      ${lib.escapeShellArg runtimeDefaults.server.profile}
    sign_tls_certificate \
      "$leaf_workdir" \
      ${lib.escapeShellArg runtimeDefaults.server.basename} \
      "$request_workdir/server.csr.pem" \
      ${lib.escapeShellArg sanSpec} \
      ${lib.escapeShellArg runtimeDefaults.server.profile} \
      ${lib.escapeShellArg runtimeDefaults.server.serial} \
      ${lib.escapeShellArg runtimeDefaults.server.days} \
      "$intermediate_key" \
      "$intermediate_cert" \
      "$root_cert"

    cp "$request_workdir/server.key.pem" "$key_path"
    cp "$request_workdir/server.csr.pem" "$csr_path"
    cp "$leaf_workdir/server.cert.pem" "$cert_path"
    cp "$leaf_workdir/chain.pem" "$chain_path"
    chmod 600 "$key_path"
    chmod 644 "$csr_path" "$cert_path" "$chain_path"
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

    rootStateDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.root.stateDir;
      description = ''
        Mutable directory where the runtime root CA signer lives.
      '';
    };

    intermediateStateDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDefaults.intermediate.stateDir;
      description = ''
        Mutable directory where the runtime intermediate CA signer lives.
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
        Whether to generate simulated runtime OpenVPN server material under the mutable state directories.
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
