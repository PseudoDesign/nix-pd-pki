let
  module = import ./pd-pki-workflow.nix;
in
{
  default = module;
  pd-pki-workflow = module;
}
