let
  mkStep =
    {
      id,
      order,
      title,
      summary,
      inputs,
      outputs,
      requiredFiles,
      validations,
      implementation,
    }:
    {
      inherit
        id
        order
        title
        summary
        inputs
        outputs
        requiredFiles
        validations
        implementation
        ;
    };

  roles = [
    {
      id = "root-certificate-authority";
      title = "Root Certificate Authority";
      description = "Top-level certificate authority for the PKI hierarchy. For automated tests this role simulates the YubiKey-backed flow with deterministic dummy artifacts in the Nix store.";
      steps = [
        (mkStep {
          id = "create-root-ca";
          order = 1;
          title = "Create Root CA";
          summary = "Generate a dummy self-signed root CA certificate and associated audit metadata.";
          inputs = [
            "Root subject metadata"
            "Root certificate profile and policy constraints"
            "Validity period and serial number policy"
            "Test-mode signer parameters that replace the YubiKey flow"
          ];
          outputs = [
            "Dummy root private key material for automated testing"
            "Self-signed root CA certificate"
            "Public metadata such as fingerprint, serial number, and validity window"
          ];
          requiredFiles = [
            "artifacts/root-ca.key.pem"
            "artifacts/root-ca.csr.pem"
            "artifacts/root-ca.cert.pem"
            "artifacts/root-ca.metadata.json"
            "status.json"
          ];
          validations = [
            "x509-parse"
            "csr-parse"
            "self-signed"
            "ca-basic-constraints"
            "json-parse"
          ];
          implementation = {
            kind = "root-ca";
            note = "Simulated in software for repository checks; no hardware-backed key management is attempted.";
            artifacts = {
              key = "artifacts/root-ca.key.pem";
              csr = "artifacts/root-ca.csr.pem";
              certificate = "artifacts/root-ca.cert.pem";
              metadata = "artifacts/root-ca.metadata.json";
            };
          };
        })
        (mkStep {
          id = "rotate-root-ca";
          order = 2;
          title = "Rotate Root CA";
          summary = "Provision a replacement dummy root certificate and produce a retirement record for the prior root.";
          inputs = [
            "Existing root CA metadata"
            "Replacement root subject metadata"
            "Updated policy constraints, if changed"
            "Replacement signer parameters"
          ];
          outputs = [
            "Replacement self-signed root CA certificate"
            "Replacement private key material for automated testing"
            "Retirement record for the prior root certificate"
          ];
          requiredFiles = [
            "artifacts/replacement-root-ca.key.pem"
            "artifacts/replacement-root-ca.csr.pem"
            "artifacts/replacement-root-ca.cert.pem"
            "artifacts/replacement-root-ca.metadata.json"
            "artifacts/retirement-record.json"
            "status.json"
          ];
          validations = [
            "x509-parse"
            "csr-parse"
            "self-signed"
            "ca-basic-constraints"
            "json-parse"
          ];
          implementation = {
            kind = "root-ca";
            note = "Simulates rotation by minting a second dummy root certificate and recording retirement metadata.";
            artifacts = {
              key = "artifacts/replacement-root-ca.key.pem";
              csr = "artifacts/replacement-root-ca.csr.pem";
              certificate = "artifacts/replacement-root-ca.cert.pem";
              metadata = "artifacts/replacement-root-ca.metadata.json";
              retirementRecord = "artifacts/retirement-record.json";
            };
          };
        })
        (mkStep {
          id = "sign-intermediate-ca-certificate";
          order = 3;
          title = "Sign Intermediate CA Certificate";
          summary = "Use the dummy root CA to sign a representative intermediate CA certificate.";
          inputs = [
            "Approved intermediate CA certificate signing request"
            "Issuance policy for the intermediate CA"
            "Access to the simulated root signer"
            "Intermediate validity period and path length constraints"
          ];
          outputs = [
            "Signed intermediate CA certificate"
            "Certificate chain linking the intermediate to the root"
            "Issuance metadata for audit purposes"
          ];
          requiredFiles = [
            "artifacts/intermediate-ca.key.pem"
            "artifacts/intermediate-ca.csr.pem"
            "artifacts/intermediate-ca.cert.pem"
            "artifacts/chain.pem"
            "artifacts/issuance-metadata.json"
            "status.json"
          ];
          validations = [
            "x509-parse"
            "csr-parse"
            "chain-verify"
            "ca-basic-constraints"
            "json-parse"
          ];
          implementation = {
            kind = "intermediate-ca";
            note = "Produces a representative intermediate CA signed by the dummy root.";
            artifacts = {
              key = "artifacts/intermediate-ca.key.pem";
              csr = "artifacts/intermediate-ca.csr.pem";
              certificate = "artifacts/intermediate-ca.cert.pem";
              chain = "artifacts/chain.pem";
              metadata = "artifacts/issuance-metadata.json";
            };
          };
        })
        (mkStep {
          id = "revoke-intermediate-ca-certificate";
          order = 4;
          title = "Revoke Intermediate CA Certificate";
          summary = "Emit revocation metadata for the representative intermediate certificate.";
          inputs = [
            "Identifier for the intermediate CA certificate to revoke"
            "Revocation reason and effective time"
            "Current revocation state"
          ];
          outputs = [
            "Updated revocation record"
            "Updated public status for downstream consumers"
          ];
          requiredFiles = [
            "artifacts/revocation-record.json"
            "artifacts/revocation-status.json"
            "status.json"
          ];
          validations = [
            "revocation-json"
            "json-parse"
          ];
          implementation = {
            kind = "revocation-record";
            note = "Stores revocation data as JSON for testability rather than producing a CRL.";
            artifacts = {
              record = "artifacts/revocation-record.json";
              status = "artifacts/revocation-status.json";
            };
          };
        })
        (mkStep {
          id = "publish-root-trust-artifacts";
          order = 5;
          title = "Publish Root Trust Artifacts";
          summary = "Assemble a distribution-ready trust bundle containing root-side public artifacts.";
          inputs = [
            "Current root CA certificate"
            "Current signed intermediate CA certificates"
            "Current revocation artifacts"
            "Public metadata describing the active signing configuration"
          ];
          outputs = [
            "Trust bundle for downstream roles"
            "Published root and intermediate certificates"
            "Published revocation metadata"
          ];
          requiredFiles = [
            "artifacts/trust-bundle/root-ca.cert.pem"
            "artifacts/trust-bundle/intermediate-ca.cert.pem"
            "artifacts/trust-bundle/chain.pem"
            "artifacts/trust-bundle/revocation-record.json"
            "artifacts/publication-manifest.json"
            "status.json"
          ];
          validations = [
            "trust-bundle"
            "json-parse"
          ];
          implementation = {
            kind = "trust-publication";
            note = "Publishes public trust material and metadata into a deterministic bundle layout.";
            artifacts = {
              bundle = "artifacts/trust-bundle";
              manifest = "artifacts/publication-manifest.json";
            };
          };
        })
      ];
    }
    {
      id = "intermediate-signing-authority";
      title = "Intermediate Signing Authority";
      description = "Delegated certificate authority signed by the root CA. In automated tests this role uses the dummy root artifacts to mint representative intermediate and leaf material.";
      steps = [
        (mkStep {
          id = "create-intermediate-ca";
          order = 1;
          title = "Create Intermediate CA";
          summary = "Generate an intermediate CA keypair, CSR, root-signed certificate, and chain metadata.";
          inputs = [
            "Intermediate subject metadata"
            "Intermediate certificate profile and policy constraints"
            "Validity period, serial number policy, and path length constraints"
            "Access to the root CA workflow needed to sign the intermediate CSR"
          ];
          outputs = [
            "Intermediate private key material generated in the designated signing environment"
            "Root-signed intermediate CA certificate"
            "Certificate chain linking the intermediate to the root CA"
          ];
          requiredFiles = [
            "artifacts/intermediate-ca.key.pem"
            "artifacts/intermediate-ca.csr.pem"
            "artifacts/intermediate-ca.cert.pem"
            "artifacts/chain.pem"
            "artifacts/signer-metadata.json"
            "status.json"
          ];
          validations = [
            "x509-parse"
            "csr-parse"
            "chain-verify"
            "ca-basic-constraints"
            "json-parse"
          ];
          implementation = {
            kind = "intermediate-ca";
            note = "Uses the dummy root CA created by the root package as the signer.";
            artifacts = {
              key = "artifacts/intermediate-ca.key.pem";
              csr = "artifacts/intermediate-ca.csr.pem";
              certificate = "artifacts/intermediate-ca.cert.pem";
              chain = "artifacts/chain.pem";
              metadata = "artifacts/signer-metadata.json";
            };
          };
        })
        (mkStep {
          id = "rotate-intermediate-ca";
          order = 2;
          title = "Rotate Intermediate CA";
          summary = "Provision a replacement intermediate CA and record retirement information for the prior intermediate.";
          inputs = [
            "Existing intermediate CA metadata"
            "Replacement intermediate subject metadata"
            "Updated policy constraints, if changed"
            "Access to the root CA workflow to sign the replacement CSR"
          ];
          outputs = [
            "Replacement intermediate private key material"
            "Replacement root-signed intermediate CA certificate"
            "Retirement record for the prior intermediate certificate"
          ];
          requiredFiles = [
            "artifacts/replacement-intermediate-ca.key.pem"
            "artifacts/replacement-intermediate-ca.csr.pem"
            "artifacts/replacement-intermediate-ca.cert.pem"
            "artifacts/replacement-chain.pem"
            "artifacts/retirement-record.json"
            "status.json"
          ];
          validations = [
            "x509-parse"
            "csr-parse"
            "chain-verify"
            "ca-basic-constraints"
            "json-parse"
          ];
          implementation = {
            kind = "intermediate-ca";
            note = "Creates a second representative intermediate signed by the dummy root.";
            artifacts = {
              key = "artifacts/replacement-intermediate-ca.key.pem";
              csr = "artifacts/replacement-intermediate-ca.csr.pem";
              certificate = "artifacts/replacement-intermediate-ca.cert.pem";
              chain = "artifacts/replacement-chain.pem";
              metadata = "artifacts/retirement-record.json";
            };
          };
        })
        (mkStep {
          id = "sign-openvpn-server-leaf-certificate";
          order = 3;
          title = "Sign OpenVPN Server Leaf Certificate";
          summary = "Sign a representative OpenVPN server certificate using the intermediate CA.";
          inputs = [
            "Approved OpenVPN server certificate signing request"
            "Requested server subject alternative names and endpoint metadata"
            "Server issuance policy and key usage constraints"
            "Requested validity period and serial number allocation"
          ];
          outputs = [
            "Signed OpenVPN server leaf certificate"
            "Certificate chain for server deployment"
            "Audit record of the signing event"
          ];
          requiredFiles = [
            "artifacts/server.key.pem"
            "artifacts/server.csr.pem"
            "artifacts/server.cert.pem"
            "artifacts/chain.pem"
            "artifacts/issuance-metadata.json"
            "status.json"
          ];
          validations = [
            "x509-parse"
            "csr-parse"
            "chain-verify"
            "server-eku"
            "san-present"
            "json-parse"
          ];
          implementation = {
            kind = "server-leaf";
            note = "Generates a representative server CSR inside the build and signs it with the intermediate.";
            artifacts = {
              key = "artifacts/server.key.pem";
              csr = "artifacts/server.csr.pem";
              certificate = "artifacts/server.cert.pem";
              chain = "artifacts/chain.pem";
              metadata = "artifacts/issuance-metadata.json";
            };
          };
        })
        (mkStep {
          id = "sign-openvpn-client-leaf-certificate";
          order = 4;
          title = "Sign OpenVPN Client Leaf Certificate";
          summary = "Sign a representative OpenVPN client certificate using the intermediate CA.";
          inputs = [
            "Approved OpenVPN client certificate signing request"
            "Client identity metadata and subject naming inputs"
            "Client issuance policy and key usage constraints"
            "Requested validity period and serial number allocation"
          ];
          outputs = [
            "Signed OpenVPN client leaf certificate"
            "Certificate chain for client distribution"
            "Audit record of the signing event"
          ];
          requiredFiles = [
            "artifacts/client.key.pem"
            "artifacts/client.csr.pem"
            "artifacts/client.cert.pem"
            "artifacts/chain.pem"
            "artifacts/issuance-metadata.json"
            "status.json"
          ];
          validations = [
            "x509-parse"
            "csr-parse"
            "chain-verify"
            "client-eku"
            "json-parse"
          ];
          implementation = {
            kind = "client-leaf";
            note = "Generates a representative client CSR inside the build and signs it with the intermediate.";
            artifacts = {
              key = "artifacts/client.key.pem";
              csr = "artifacts/client.csr.pem";
              certificate = "artifacts/client.cert.pem";
              chain = "artifacts/chain.pem";
              metadata = "artifacts/issuance-metadata.json";
            };
          };
        })
        (mkStep {
          id = "revoke-leaf-certificate";
          order = 5;
          title = "Revoke Leaf Certificate";
          summary = "Record revocation metadata for representative server and client certificates.";
          inputs = [
            "Identifier for the leaf certificate to revoke"
            "Revocation reason and effective time"
            "Current revocation state needed to produce updated status artifacts"
          ];
          outputs = [
            "Updated revocation artifact"
            "Revocation record for audit purposes"
            "Updated public status for downstream consumers"
          ];
          requiredFiles = [
            "artifacts/revocation-record.json"
            "artifacts/revoked-certificates.json"
            "status.json"
          ];
          validations = [
            "revocation-json"
            "json-parse"
          ];
          implementation = {
            kind = "revocation-record";
            note = "Stores representative leaf revocation data as JSON.";
            artifacts = {
              record = "artifacts/revocation-record.json";
              status = "artifacts/revoked-certificates.json";
            };
          };
        })
        (mkStep {
          id = "publish-intermediate-trust-artifacts";
          order = 6;
          title = "Publish Intermediate Trust Artifacts";
          summary = "Assemble a publication bundle containing intermediate trust data and issuance metadata.";
          inputs = [
            "Current intermediate CA certificate and root chain"
            "Current issued leaf certificate metadata or distribution manifests"
            "Current revocation artifacts"
            "Public metadata describing the active intermediate signing configuration"
          ];
          outputs = [
            "Trust bundle or distribution directory for OpenVPN roles"
            "Published intermediate and chain certificates"
            "Published revocation artifacts and supporting metadata"
          ];
          requiredFiles = [
            "artifacts/trust-bundle/intermediate-ca.cert.pem"
            "artifacts/trust-bundle/chain.pem"
            "artifacts/trust-bundle/revocation-record.json"
            "artifacts/trust-bundle/server.cert.pem"
            "artifacts/trust-bundle/client.cert.pem"
            "artifacts/publication-manifest.json"
            "status.json"
          ];
          validations = [
            "trust-bundle"
            "json-parse"
          ];
          implementation = {
            kind = "trust-publication";
            note = "Publishes the intermediate certificate, chain, representative issued certs, and revocation metadata.";
            artifacts = {
              bundle = "artifacts/trust-bundle";
              manifest = "artifacts/publication-manifest.json";
            };
          };
        })
      ];
    }
    {
      id = "openvpn-server-leaf";
      title = "OpenVPN Server Leaf";
      description = "Leaf-certificate workflow for OpenVPN server identities. In tests it generates representative requests, bundles, rotation artifacts, and trust consumption state.";
      steps = [
        (mkStep {
          id = "create-openvpn-server-leaf-request";
          order = 1;
          title = "Create OpenVPN Server Leaf Request";
          summary = "Generate a representative OpenVPN server private key, CSR, and SAN manifest.";
          inputs = [
            "Server subject metadata such as common name or service identity"
            "Requested subject alternative names such as DNS names or IP addresses"
            "Server certificate profile, key usage, and extended key usage constraints"
            "Deployment metadata describing the OpenVPN server instance or environment"
          ];
          outputs = [
            "Server private key material for automated testing"
            "OpenVPN server certificate signing request"
            "Subject and SAN manifest for review before issuance"
          ];
          requiredFiles = [
            "artifacts/server.key.pem"
            "artifacts/server.csr.pem"
            "artifacts/san-manifest.json"
            "artifacts/issuance-request.json"
            "status.json"
          ];
          validations = [
            "csr-parse"
            "san-present"
            "json-parse"
          ];
          implementation = {
            kind = "server-request";
            note = "Produces a representative server keypair and CSR suitable for the intermediate signer.";
            artifacts = {
              key = "artifacts/server.key.pem";
              csr = "artifacts/server.csr.pem";
              manifest = "artifacts/san-manifest.json";
              request = "artifacts/issuance-request.json";
            };
          };
        })
        (mkStep {
          id = "package-openvpn-server-deployment-bundle";
          order = 2;
          title = "Package OpenVPN Server Deployment Bundle";
          summary = "Assemble a deployment-ready bundle containing the representative server certificate, key, chain, and trust metadata.";
          inputs = [
            "Signed OpenVPN server leaf certificate"
            "Intermediate and root certificate chain"
            "Current revocation artifacts needed by the server role"
            "Packaging requirements such as file layout, naming, and deployment metadata"
          ];
          outputs = [
            "Deployment-ready OpenVPN server bundle"
            "Server certificate and trust chain in the expected packaging format"
            "Bundle manifest describing serial number, validity window, and subject alternative names"
          ];
          requiredFiles = [
            "artifacts/deployment-bundle/server.key.pem"
            "artifacts/deployment-bundle/server.cert.pem"
            "artifacts/deployment-bundle/chain.pem"
            "artifacts/deployment-bundle/revocation-record.json"
            "artifacts/bundle-manifest.json"
            "status.json"
          ];
          validations = [
            "bundle-complete"
            "server-eku"
            "chain-verify"
            "json-parse"
          ];
          implementation = {
            kind = "server-bundle";
            note = "Signs the generated server CSR with the intermediate CA and packages the result.";
            artifacts = {
              bundle = "artifacts/deployment-bundle";
              manifest = "artifacts/bundle-manifest.json";
              certificate = "artifacts/deployment-bundle/server.cert.pem";
              chain = "artifacts/deployment-bundle/chain.pem";
            };
          };
        })
        (mkStep {
          id = "rotate-openvpn-server-certificate";
          order = 3;
          title = "Rotate OpenVPN Server Certificate";
          summary = "Generate replacement server key material, issue a replacement certificate, and record retirement metadata.";
          inputs = [
            "Existing server certificate and deployment metadata"
            "New server subject or SAN inputs, if changed"
            "Rotation policy indicating whether to rekey or reuse the existing key"
            "Replacement validity period and activation window"
          ];
          outputs = [
            "Replacement server private key material"
            "Replacement signed OpenVPN server certificate and chain"
            "Retirement record for the previous certificate"
          ];
          requiredFiles = [
            "artifacts/replacement-server.key.pem"
            "artifacts/replacement-server.csr.pem"
            "artifacts/replacement-server.cert.pem"
            "artifacts/replacement-chain.pem"
            "artifacts/retirement-record.json"
            "status.json"
          ];
          validations = [
            "x509-parse"
            "csr-parse"
            "server-eku"
            "chain-verify"
            "json-parse"
          ];
          implementation = {
            kind = "server-rotation";
            note = "Rekeys and issues a replacement server certificate for rollout testing.";
            artifacts = {
              key = "artifacts/replacement-server.key.pem";
              csr = "artifacts/replacement-server.csr.pem";
              certificate = "artifacts/replacement-server.cert.pem";
              chain = "artifacts/replacement-chain.pem";
              retirementRecord = "artifacts/retirement-record.json";
            };
          };
        })
        (mkStep {
          id = "consume-server-trust-updates";
          order = 4;
          title = "Consume Server Trust Updates";
          summary = "Stage updated trust chain and revocation metadata for a representative server deployment.";
          inputs = [
            "Current published root and intermediate trust bundle"
            "Current revocation artifacts"
            "Metadata describing the target server deployment environment"
            "Update policy and activation window for trust changes"
          ];
          outputs = [
            "Updated trust material for server-side certificate validation"
            "Deployment record showing when the trust bundle changed"
            "Status metadata indicating the active trust and revocation set"
          ];
          requiredFiles = [
            "artifacts/staged-trust/root-ca.cert.pem"
            "artifacts/staged-trust/intermediate-ca.cert.pem"
            "artifacts/staged-trust/revocation-record.json"
            "artifacts/trust-update-status.json"
            "status.json"
          ];
          validations = [
            "trust-bundle"
            "json-parse"
          ];
          implementation = {
            kind = "trust-consumption";
            note = "Stages the published trust bundle into a server-oriented layout and records activation metadata.";
            artifacts = {
              bundle = "artifacts/staged-trust";
              manifest = "artifacts/trust-update-status.json";
            };
          };
        })
      ];
    }
    {
      id = "openvpn-client-leaf";
      title = "OpenVPN Client Leaf";
      description = "Leaf-certificate workflow for OpenVPN client identities. In tests it generates representative requests, bundles, rotation artifacts, and trust consumption state.";
      steps = [
        (mkStep {
          id = "create-openvpn-client-leaf-request";
          order = 1;
          title = "Create OpenVPN Client Leaf Request";
          summary = "Generate a representative OpenVPN client private key, CSR, and identity manifest.";
          inputs = [
            "Client identity metadata such as user, device, or service account attributes"
            "Subject naming policy inputs used to construct the client certificate subject"
            "Client certificate profile, key usage, and extended key usage constraints"
            "Enrollment metadata describing the client device, token, or distribution channel"
          ];
          outputs = [
            "Client private key material for automated testing"
            "OpenVPN client certificate signing request"
            "Identity manifest describing the requested subject and related client metadata"
          ];
          requiredFiles = [
            "artifacts/client.key.pem"
            "artifacts/client.csr.pem"
            "artifacts/identity-manifest.json"
            "artifacts/issuance-request.json"
            "status.json"
          ];
          validations = [
            "csr-parse"
            "json-parse"
          ];
          implementation = {
            kind = "client-request";
            note = "Produces a representative client keypair and CSR suitable for the intermediate signer.";
            artifacts = {
              key = "artifacts/client.key.pem";
              csr = "artifacts/client.csr.pem";
              manifest = "artifacts/identity-manifest.json";
              request = "artifacts/issuance-request.json";
            };
          };
        })
        (mkStep {
          id = "package-openvpn-client-credential-bundle";
          order = 2;
          title = "Package OpenVPN Client Credential Bundle";
          summary = "Assemble a distribution-ready client credential bundle containing the representative certificate, key, chain, and trust metadata.";
          inputs = [
            "Signed OpenVPN client leaf certificate"
            "Intermediate and root certificate chain"
            "Current revocation artifacts needed by the client role"
            "Distribution requirements such as archive format, file layout, and client configuration metadata"
          ];
          outputs = [
            "Distribution-ready OpenVPN client credential bundle"
            "Client certificate and trust chain in the expected packaging format"
            "Bundle manifest describing serial number, validity window, and client identity metadata"
          ];
          requiredFiles = [
            "artifacts/credential-bundle/client.key.pem"
            "artifacts/credential-bundle/client.cert.pem"
            "artifacts/credential-bundle/chain.pem"
            "artifacts/credential-bundle/revocation-record.json"
            "artifacts/bundle-manifest.json"
            "status.json"
          ];
          validations = [
            "bundle-complete"
            "client-eku"
            "chain-verify"
            "json-parse"
          ];
          implementation = {
            kind = "client-bundle";
            note = "Signs the generated client CSR with the intermediate CA and packages the result.";
            artifacts = {
              bundle = "artifacts/credential-bundle";
              manifest = "artifacts/bundle-manifest.json";
              certificate = "artifacts/credential-bundle/client.cert.pem";
              chain = "artifacts/credential-bundle/chain.pem";
            };
          };
        })
        (mkStep {
          id = "rotate-openvpn-client-certificate";
          order = 3;
          title = "Rotate OpenVPN Client Certificate";
          summary = "Generate replacement client key material, issue a replacement certificate, and record retirement metadata.";
          inputs = [
            "Existing client certificate and distribution metadata"
            "New client identity or subject naming inputs, if changed"
            "Rotation policy indicating whether to rekey or reuse the existing key"
            "Replacement validity period and activation window"
          ];
          outputs = [
            "Replacement client private key material"
            "Replacement signed OpenVPN client certificate and chain"
            "Retirement record for the previous certificate"
          ];
          requiredFiles = [
            "artifacts/replacement-client.key.pem"
            "artifacts/replacement-client.csr.pem"
            "artifacts/replacement-client.cert.pem"
            "artifacts/replacement-chain.pem"
            "artifacts/retirement-record.json"
            "status.json"
          ];
          validations = [
            "x509-parse"
            "csr-parse"
            "client-eku"
            "chain-verify"
            "json-parse"
          ];
          implementation = {
            kind = "client-rotation";
            note = "Rekeys and issues a replacement client certificate for rollout testing.";
            artifacts = {
              key = "artifacts/replacement-client.key.pem";
              csr = "artifacts/replacement-client.csr.pem";
              certificate = "artifacts/replacement-client.cert.pem";
              chain = "artifacts/replacement-chain.pem";
              retirementRecord = "artifacts/retirement-record.json";
            };
          };
        })
        (mkStep {
          id = "consume-client-trust-updates";
          order = 4;
          title = "Consume Client Trust Updates";
          summary = "Stage updated trust chain and revocation metadata for a representative client distribution.";
          inputs = [
            "Current published root and intermediate trust bundle"
            "Current revocation artifacts"
            "Metadata describing the target client device, token, or distribution channel"
            "Update policy and activation window for trust changes"
          ];
          outputs = [
            "Updated trust material for client-side certificate validation"
            "Distribution record showing when the trust bundle changed"
            "Status metadata indicating the active trust and revocation set"
          ];
          requiredFiles = [
            "artifacts/staged-trust/root-ca.cert.pem"
            "artifacts/staged-trust/intermediate-ca.cert.pem"
            "artifacts/staged-trust/revocation-record.json"
            "artifacts/trust-update-status.json"
            "status.json"
          ];
          validations = [
            "trust-bundle"
            "json-parse"
          ];
          implementation = {
            kind = "trust-consumption";
            note = "Stages the published trust bundle into a client-oriented layout and records activation metadata.";
            artifacts = {
              bundle = "artifacts/staged-trust";
              manifest = "artifacts/trust-update-status.json";
            };
          };
        })
      ];
    }
  ];
in
{
  inherit roles;

  roleMap = builtins.listToAttrs (map (role: {
    name = role.id;
    value = role;
  }) roles);

  roleCount = builtins.length roles;
  stepCount = builtins.foldl' (count: role: count + builtins.length role.steps) 0 roles;
}
