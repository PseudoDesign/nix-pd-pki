{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pd-pki-workflow;
  guiUrl = "http://127.0.0.1:${toString cfg.port}/gui";
  kioskCommand = pkgs.writeShellApplication {
    name = "pd-pki-provisioner-kiosk";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      chromium
    ];
    text = ''
      set -euo pipefail

      url=${lib.escapeShellArg guiUrl}

      # Wait until the loopback API is ready so Chromium does not stop on a
      # connection-refused error page during boot.
      until curl --silent --show-error --fail --output /dev/null "$url"; do
        sleep 1
      done

      exec ${lib.getExe pkgs.chromium} \
        --enable-features=UseOzonePlatform \
        --ozone-platform=wayland \
        --force-dark-mode \
        --kiosk \
        --incognito \
        --no-first-run \
        --no-default-browser-check \
        --disable-session-crashed-bubble \
        --disable-features=Translate,MediaRouter \
        "$url"
    '';
  };
in
{
  imports = [
    ../hardware/rpi5-offline-root-ca.nix
    ../profiles/root-yubikey-provisioner.nix
  ];

  image.baseName = lib.mkForce "pd-pki-rpi5-root-yubikey-provisioner";
  networking.hostName = "rpi5-root-yubikey-provisioner";
  services.getty.autologinUser = lib.mkForce null;
  services.pd-pki-workflow.liveHardware.enable = true;
  services.pd-pki-workflow.environment = {
    PD_PKI_WEB_HIDE_CURSOR = "1";
    PD_PKI_WEB_THEME = "dark";
  };
  services.usbguard.rules = lib.mkAfter ''
    # Allow USB HID touch interfaces for the local kiosk display.
    allow with-interface one-of { 03:00:00 }
  '';

  fonts.packages = [ pkgs.dejavu_fonts ];

  programs.chromium = {
    enable = true;
    extraOpts = {
      BrowserSignin = 0;
      MetricsReportingEnabled = false;
      PasswordManagerEnabled = false;
      SyncDisabled = true;
    };
  };

  services.cage = {
    enable = true;
    user = cfg.user;
    program = lib.getExe kioskCommand;
    environment = {
      NIXOS_OZONE_WL = "1";
    };
  };

  systemd.services.cage-tty1.serviceConfig = {
    Restart = lib.mkForce "always";
    RestartSec = 2;
  };

  system.nixos.tags = [ "gui-kiosk" ];
}
