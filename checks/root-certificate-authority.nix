{
  pkgs,
  definitions,
  packages,
}:
let
  helpers = import ./common.nix { inherit pkgs packages; };
  role = definitions.roleMap.root-certificate-authority;
in
# Checks for the root CA workflow, including dummy root generation,
# intermediate signing, revocation metadata, and trust publication.
helpers.checksForRole role
