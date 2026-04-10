{ pkgs }:
let
  rootCertificateAuthority = import ./root-certificate-authority.nix { inherit pkgs; };
  intermediateSigningAuthority = import ./intermediate-signing-authority.nix { inherit pkgs; };
  openvpnServerLeaf = import ./openvpn-server-leaf.nix { inherit pkgs; };
  openvpnClientLeaf = import ./openvpn-client-leaf.nix { inherit pkgs; };
in
{
  pd-pki = pkgs.linkFarm "pd-pki" [
    {
      name = "root-certificate-authority";
      path = rootCertificateAuthority;
    }
    {
      name = "intermediate-signing-authority";
      path = intermediateSigningAuthority;
    }
    {
      name = "openvpn-server-leaf";
      path = openvpnServerLeaf;
    }
    {
      name = "openvpn-client-leaf";
      path = openvpnClientLeaf;
    }
  ];

  root-certificate-authority = rootCertificateAuthority;
  intermediate-signing-authority = intermediateSigningAuthority;
  openvpn-server-leaf = openvpnServerLeaf;
  openvpn-client-leaf = openvpnClientLeaf;
}
