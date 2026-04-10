{
  default = {
    imports = [
      ./root-certificate-authority.nix
      ./intermediate-signing-authority.nix
      ./openvpn-server-leaf.nix
      ./openvpn-client-leaf.nix
    ];
  };

  root-certificate-authority = import ./root-certificate-authority.nix;
  intermediate-signing-authority = import ./intermediate-signing-authority.nix;
  openvpn-server-leaf = import ./openvpn-server-leaf.nix;
  openvpn-client-leaf = import ./openvpn-client-leaf.nix;
}
