{
  pkgs,
  definitions,
  packages,
}:
let
  helpers = import ./common.nix { inherit pkgs packages; };
  role = definitions.roleMap.openvpn-client-leaf;
in
# Checks for the client leaf workflow, covering request generation,
# credential bundle assembly, rotation, and trust update consumption.
helpers.checksForRole role
