(import ./mk-role-module.nix {
  roleId = "intermediate-signing-authority";
  optionName = "intermediateSigningAuthority";
  packagePath = ../packages/intermediate-signing-authority.nix;
})
