{
  pkgs,
  definitions,
  packages,
}:
let
  helpers = import ./common.nix { inherit pkgs packages; };
  role = definitions.roleMap.openvpn-server-leaf;
in
# Checks for the server leaf workflow, covering request generation,
# deployment bundle assembly, rotation, and trust update consumption.
helpers.checksForRole role
