(import ./mk-role-module.nix {
  roleId = "openvpn-client-leaf";
  optionName = "openvpnClientLeaf";
  packagePath = ../packages/openvpn-client-leaf.nix;
})
