{ pkgs, definitions ? import ./definitions.nix }:
let
  common = import ./common.nix { inherit pkgs definitions; };

  rootRole = common.roleById "root-certificate-authority";
  intermediateRole = common.roleById "intermediate-signing-authority";
  serverRole = common.roleById "openvpn-server-leaf";
  clientRole = common.roleById "openvpn-client-leaf";

  rootCertificateAuthority = import ./root-certificate-authority.nix {
    inherit pkgs definitions;
  };

  intermediateSigningAuthority = import ./intermediate-signing-authority.nix {
    inherit pkgs definitions rootCertificateAuthority;
  };

  openvpnServerLeaf = import ./openvpn-server-leaf.nix {
    inherit pkgs definitions rootCertificateAuthority intermediateSigningAuthority;
  };

  openvpnClientLeaf = import ./openvpn-client-leaf.nix {
    inherit pkgs definitions rootCertificateAuthority intermediateSigningAuthority;
  };

  pdPkiSigningTools = import ./pd-pki-signing-tools.nix {
    inherit pkgs;
  };

  pdPkiOperator = import ./pd-pki-operator.nix {
    inherit pkgs;
  };

  pdPkiRootYubiKeyProvisionerWizard = import ./pd-pki-root-yubikey-provisioner-wizard.nix {
    inherit pkgs pdPkiSigningTools;
  };

  rolePackages = {
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
    pd-pki-signing-tools = pdPkiSigningTools;
    pd-pki-operator = pdPkiOperator;
    pd-pki-root-yubikey-provisioner-wizard = pdPkiRootYubiKeyProvisionerWizard;
  };

  stepPackages =
    common.stepPackagesForRole {
      role = rootRole;
      rolePackage = rootCertificateAuthority;
    }
    // common.stepPackagesForRole {
      role = intermediateRole;
      rolePackage = intermediateSigningAuthority;
    }
    // common.stepPackagesForRole {
      role = serverRole;
      rolePackage = openvpnServerLeaf;
    }
    // common.stepPackagesForRole {
      role = clientRole;
      rolePackage = openvpnClientLeaf;
    };
in
rolePackages // stepPackages
