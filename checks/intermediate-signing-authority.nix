{
  pkgs,
  definitions,
  packages,
}:
let
  helpers = import ./common.nix { inherit pkgs packages; };
  role = definitions.roleMap.intermediate-signing-authority;
in
# Checks for the intermediate CA workflow, including issuance,
# rotation, representative leaf signing, revocation, and publication.
helpers.checksForRole role
