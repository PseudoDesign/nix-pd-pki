(import ./mk-role-module.nix {
  roleId = "openvpn-server-leaf";
  optionName = "openvpnServerLeaf";
  packagePath = ../packages/openvpn-server-leaf.nix;
})
