{
  pkgs,
  nixpkgs,
  pd-pki-python,
  pd-pki-package,
}:
{
  default = pd-pki-package;
  package = pd-pki-package;
  module-eval = import ./module-eval.nix {
    inherit pkgs nixpkgs pd-pki-python pd-pki-package;
  };
  vm-smoke = import ./vm-smoke.nix {
    inherit pkgs pd-pki-python pd-pki-package;
  };
}
