{
  pkgs,
  nixpkgs,
  pd-pki-python,
  pd-pki-package,
  offlineSystems,
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
  offline-systems-eval = import ./offline-systems-eval.nix {
    inherit pkgs offlineSystems;
  };
  offline-profiles-vm = import ./offline-profiles-vm.nix {
    inherit pkgs pd-pki-python pd-pki-package;
  };
}
