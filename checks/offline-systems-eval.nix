{
  pkgs,
  offlineSystems,
}:
let
  provisioner = offlineSystems.rpi5RootYubiKeyProvisioner.config;
  signer = offlineSystems.rpi5RootIntermediateSigner.config;
in
assert provisioner.services.usbguard.enable;
assert signer.services.usbguard.enable;
assert provisioner.services.pcscd.enable;
assert signer.services.pcscd.enable;
assert provisioner.services.pd-pki-workflow.liveHardware.enable;
assert signer.services.pd-pki-workflow.liveHardware.enable;
assert provisioner.services.openssh.enable;
assert signer.services.openssh.enable;
assert provisioner.services.openssh.openFirewall;
assert signer.services.openssh.openFirewall;
assert !provisioner.services.openssh.settings.PasswordAuthentication;
assert !signer.services.openssh.settings.PasswordAuthentication;
assert !provisioner.security.sudo.wheelNeedsPassword;
assert !signer.security.sudo.wheelNeedsPassword;
assert provisioner.services.cage.enable;
assert !signer.services.cage.enable;
assert provisioner.users.users.adam.isNormalUser;
assert signer.users.users.adam.isNormalUser;
assert builtins.elem "wheel" provisioner.users.users.adam.extraGroups;
assert builtins.elem "wheel" signer.users.users.adam.extraGroups;
assert builtins.elem "root-yubikey-provisioner" provisioner.system.nixos.tags;
assert builtins.elem "root-intermediate-signer" signer.system.nixos.tags;
assert builtins.elem "gui-kiosk" provisioner.system.nixos.tags;
assert builtins.elem "live-hardware-bridge" provisioner.system.nixos.tags;
assert builtins.elem "live-hardware-bridge" signer.system.nixos.tags;
assert builtins.elem "temporary-dev-access" provisioner.system.nixos.tags;
assert builtins.elem "temporary-dev-access" signer.system.nixos.tags;
assert provisioner.networking.wireless.enable == false;
assert signer.networking.wireless.enable == false;
pkgs.runCommand "pd-pki-offline-systems-eval" { } ''
  cat > "$out" <<'EOF'
  provisioner=${provisioner.networking.hostName}
  signer=${signer.networking.hostName}
  EOF
''
