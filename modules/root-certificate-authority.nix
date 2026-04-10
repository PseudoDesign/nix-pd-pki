(import ./mk-role-module.nix {
  roleId = "root-certificate-authority";
  optionName = "rootCertificateAuthority";
  packagePath = ../packages/root-certificate-authority.nix;
})
