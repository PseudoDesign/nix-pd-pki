# NixOS Modules

`pd-pki` exposes one NixOS module per role through
`services.pd-pki.roles.*`.

Each role module is built from
[`modules/mk-role-module.nix`](../modules/mk-role-module.nix).
Enabling a role module:

- exposes the role package under `/etc/pd-pki/<role-id>` by default
- can add the role package to `environment.systemPackages`
- exposes read-only `definition` and `stepIds` values derived from the workflow
  contract

## Option Paths

- `services.pd-pki.roles.rootCertificateAuthority`
- `services.pd-pki.roles.intermediateSigningAuthority`
- `services.pd-pki.roles.openvpnServerLeaf`
- `services.pd-pki.roles.openvpnClientLeaf`

## Runtime Model

Each role follows the same high-level runtime pattern:

- request material is provided from outside the module, either as direct file
  paths or as systemd credentials
- pd-pki validates staged inputs before replacing the live runtime state
- refreshed imports can trigger reload or restart hooks for dependent services
  only when runtime artifacts actually change

Role-specific behavior:

- `services.pd-pki.roles.rootCertificateAuthority` stages operator-provided root
  key, CSR, certificate, optional CRL, and optional metadata into mutable
  runtime paths, and exports a declarative non-secret YubiKey initialization
  profile JSON under `/etc` for offline root ceremonies
- `services.pd-pki.roles.intermediateSigningAuthority` writes
  `signing-request.json`, then either derives a CSR from an operator-provided
  key via `keySourcePath` or `keyCredentialPath`, stages an externally generated
  CSR via `csrSourcePath` or `csrCredentialPath`, or reuses an already-seeded
  runtime key and CSR, and finally stages an imported intermediate certificate,
  chain, optional CRL, and optional metadata
- `services.pd-pki.roles.openvpnServerLeaf` writes `issuance-request.json` plus
  `san-manifest.json`, then either derives a CSR from an operator-provided key
  via `keySourcePath` or `keyCredentialPath`, stages an externally generated CSR
  via `csrSourcePath` or `csrCredentialPath`, or reuses an already-seeded
  runtime key and CSR, and finally stages an imported server certificate, chain,
  issuer CRL, and optional metadata
- `services.pd-pki.roles.openvpnClientLeaf` writes `issuance-request.json` plus
  `identity-manifest.json`, then either derives a CSR from an operator-provided
  key via `keySourcePath` or `keyCredentialPath`, stages an externally generated
  CSR via `csrSourcePath` or `csrCredentialPath`, or reuses an already-seeded
  runtime key and CSR, and finally stages an imported client certificate, chain,
  issuer CRL, and optional metadata

## Provisioning Inputs

Provisioned inputs can be supplied as plain file paths through `*SourcePath`
options or loaded into the pd-pki units as systemd credentials through
`*CredentialPath` options.

`provisioningUnits` lets a role start and wait for external provisioners such as
Vault agents, secret sync jobs, or CSR exporters before it validates anything.

If a role has source paths or credential paths configured, it also enables a
periodic refresh timer. The timer re-runs validation and staging automatically,
and roles can optionally reload or restart dependent systemd units through
`reloadUnits` and `reloadMode` when the staged runtime artifacts actually
change.

## Example

```nix
{
  imports = [ inputs.pd-pki.nixosModules.default ];

  services.pd-pki.roles.openvpnServerLeaf = {
    enable = true;
    refreshInterval = "5m";
    provisioningUnits = [ "vault-agent.service" ];
    reloadUnits = [ "openvpn-server.service" ];
    keyCredentialPath = "/run/secrets/openvpn/server.key.pem";
    certificateSourcePath = "/var/lib/pd-pki/imports/server.cert.pem";
    chainSourcePath = "/var/lib/pd-pki/imports/server.chain.pem";
    crlSourcePath = "/var/lib/pd-pki/imports/intermediate.crl.pem";
  };

  services.pd-pki.roles.openvpnClientLeaf = {
    enable = true;
    csrSourcePath = "/run/secrets/openvpn/client.csr.pem";
    certificateSourcePath = "/var/lib/pd-pki/imports/client.cert.pem";
    chainSourcePath = "/var/lib/pd-pki/imports/client.chain.pem";
    crlSourcePath = "/var/lib/pd-pki/imports/intermediate.crl.pem";
  };
}
```

## Validation Behavior

Imported runtime artifacts are validated before they replace the live files.
The modules reject:

- certificate and key mismatches
- certificate and CSR mismatches
- broken chains
- wrong EKUs or SANs for leaf roles
- CA or profile mismatches for intermediate roles
- invalid or expired CRLs
- metadata that does not match the staged certificate

Updated imports are written through a staging directory first so failed
validation leaves the existing runtime state untouched.
