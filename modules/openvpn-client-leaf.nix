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
  runtimePaths = {
    directory = cfg.stateDir;
    key = "${cfg.stateDir}/client.key.pem";
    csr = "${cfg.stateDir}/client.csr.pem";
    certificate = "${cfg.stateDir}/client.cert.pem";
    chain = "${cfg.stateDir}/chain.pem";
  };
  initScript = pkgs.writeShellScript "pd-pki-openvpn-client-leaf-init" ''
    set -euo pipefail
    umask 077

    source ${../packages/pki-workflow-lib.sh}

    state_dir=${lib.escapeShellArg cfg.stateDir}
    lock_file=${lib.escapeShellArg "${runtimeDefaults.baseStateDir}/.runtime-init.lock"}
    key_path=${lib.escapeShellArg runtimePaths.key}
    csr_path=${lib.escapeShellArg runtimePaths.csr}
    cert_path=${lib.escapeShellArg runtimePaths.certificate}
    chain_path=${lib.escapeShellArg runtimePaths.chain}
    certificate_source_path=${lib.escapeShellArg (if cfg.certificateSourcePath == null then "" else cfg.certificateSourcePath)}
    chain_source_path=${lib.escapeShellArg (if cfg.chainSourcePath == null then "" else cfg.chainSourcePath)}

    request_workdir=""
    trap 'rm -rf "$request_workdir"' EXIT

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
        ${lib.escapeShellArg runtimeDefaults.client.basename} \
        ${lib.escapeShellArg cfg.commonName} \
        ${lib.escapeShellArg sanSpec} \
        ${lib.escapeShellArg runtimeDefaults.client.profile}
      cp "$request_workdir/client.key.pem" "$key_path"
      cp "$request_workdir/client.csr.pem" "$csr_path"
      chmod 600 "$key_path"
      chmod 644 "$csr_path"
    else
      printf '%s\n' "Refusing to regenerate a client request from partial state in $state_dir" >&2
      exit 1
    fi

    copy_optional_artifact "$certificate_source_path" "$cert_path" 644
    copy_optional_artifact "$chain_source_path" "$chain_path" 644
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

    certificateSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to an externally signed client certificate to stage into the runtime
        state directory.
      '';
    };

    chainSourcePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host path to a client certificate chain to stage into the runtime state directory.
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
