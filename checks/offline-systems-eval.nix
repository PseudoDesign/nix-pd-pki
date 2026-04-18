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
assert builtins.elem "root-yubikey-provisioner" provisioner.system.nixos.tags;
assert builtins.elem "root-intermediate-signer" signer.system.nixos.tags;
assert provisioner.networking.wireless.enable == false;
assert signer.networking.wireless.enable == false;
pkgs.runCommand "pd-pki-offline-systems-eval" { } ''
  cat > "$out" <<'EOF'
  provisioner=${provisioner.networking.hostName}
  signer=${signer.networking.hostName}
  EOF
''
