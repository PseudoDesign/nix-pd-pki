# Python Workflow App Refactor Proposal

## Status

Proposal for moving imperative ceremony and signing workflow logic out of large
shell strings embedded in Nix expressions and into a dedicated Python
application.

## Recommendation

Keep Nix responsible for:

- flake outputs
- package composition
- appliance images
- NixOS modules
- runtime dependency pinning
- hardening and checks

Move the following into a Python application:

- root ceremony orchestration
- YubiKey / PIV workflow logic
- transport bundle export and normalization
- signer request and signed-bundle handling
- signer-state mutation
- JSON contract validation
- operator-facing CLI flow control

Do not redesign the whole repository around the root ceremony diagram. Instead,
make the workflow layer explicit and keep the existing role packages, modules,
and flake outputs as the product core.

## Why Python

Python is the best near-term fit because it already has strong library support
for the main pieces of this system:

- `ykman` for YubiKey management and PIV operations
- `cryptography` for X.509, CSR, CRL, and fingerprint handling
- `python-pkcs11` for direct PKCS#11 interaction where needed
- `pydantic` for structured contracts and validation
- `typer` for a typed CLI with subcommands

This keeps the migration incremental. Nix can still package and ship the new
tooling, and the current shell entrypoints can become compatibility wrappers
instead of disappearing all at once.

## Why Not Rust First

Rust would be a good long-term choice if the appliance eventually becomes a
standalone product and tighter type-safety is worth the higher implementation
cost.

For the current repository, Python is a better first refactor because:

- Yubico's automation surface is already Python-friendly
- the current implementation is shell, JSON, and OpenSSL heavy, which maps well
  to Python
- the migration can preserve the current CLI semantics with less risk

## Scope

This proposal applies primarily to logic currently embedded in:

- [packages/pd-pki-signing-tools.nix](../packages/pd-pki-signing-tools.nix)
- [packages/pd-pki-operator.nix](../packages/pd-pki-operator.nix)
- [packages/pd-pki-root-yubikey-provisioner-wizard.nix](../packages/pd-pki-root-yubikey-provisioner-wizard.nix)

It does not propose replacing:

- role package generation
- NixOS modules
- flake output structure
- appliance image composition

## Target Repository Layout

Suggested target tree:

```text
pyproject.toml
src/
  pd_pki_workflow/
    __init__.py
    cli.py
    errors.py
    logging.py
    settings.py
    workflows/
      __init__.py
      root_provisioning.py
      root_inventory.py
      root_intermediate_signing.py
      request_signing.py
      crl_management.py
    contracts/
      __init__.py
      common.py
      root_inventory.py
      request_bundle.py
      signed_bundle.py
      signer_policy.py
      signer_state.py
    models/
      __init__.py
      root.py
      request.py
      signing.py
      transfer.py
    crypto/
      __init__.py
      x509.py
      csr.py
      crl.py
      fingerprints.py
      verification.py
    yubikey/
      __init__.py
      device.py
      piv.py
      pkcs11.py
      attestation.py
    storage/
      __init__.py
      files.py
      bundles.py
      inventory.py
      signer_state.py
    ui/
      __init__.py
      prompts.py
      usb.py
      operator_cli.py
      provisioner_cli.py
    util/
      __init__.py
      fs.py
      json.py
      time.py
      subprocess.py
tests/
  python/
    test_root_provisioning.py
    test_root_inventory.py
    test_request_signing.py
    fixtures/
packages/
  pd-pki-workflow-python.nix
  pd-pki-signing-tools.nix
  pd-pki-operator.nix
  pd-pki-root-yubikey-provisioner-wizard.nix
```

## Module Responsibilities

### `cli.py`

The main entrypoint. Defines the command tree and delegates to workflow modules.

Recommended command shape:

```text
pd-pki-workflow root provision dry-run
pd-pki-workflow root provision apply
pd-pki-workflow root inventory export
pd-pki-workflow root inventory normalize
pd-pki-workflow root inventory verify
pd-pki-workflow request export
pd-pki-workflow request sign
pd-pki-workflow request import-signed
pd-pki-workflow signer revoke
pd-pki-workflow signer generate-crl
```

### `workflows/root_provisioning.py`

Owns the root YubiKey initialization ceremony:

- load and validate the root initialization profile
- create the dry-run plan
- generate the OpenSSL config and key URI plan artifacts
- perform destructive token initialization
- collect certificate, attestation, and verified public key artifacts
- write the final ceremony summary

### `workflows/root_inventory.py`

Owns movement from ceremony artifacts to committed inventory:

- export public inventory bundles
- validate bundle contents
- derive `root-id`
- normalize the bundle into `inventory/root-ca/<root-id>/`
- verify an inserted YubiKey against committed inventory

### `workflows/root_intermediate_signing.py`

Owns the root-side intermediate signing workflow:

- verify the inserted root token against committed inventory
- validate the intermediate request bundle
- perform PKCS#11-backed signing
- write the signed bundle and audit metadata

### `workflows/request_signing.py`

Owns generic signer request flow for intermediate and leaf issuance:

- export requests from runtime state
- validate requests against signer policy
- sign requests using file-backed or token-backed keys
- import signed bundles back into runtime state

### `workflows/crl_management.py`

Owns revocation and CRL generation:

- record revocations in signer state
- regenerate signer-side CRLs
- validate CRL metadata before export

### `contracts/*`

Defines stable, versioned contracts as Python models. These should be the
single source of truth for data shape validation.

Expected models include:

- `RootInventoryManifest`
- `RootInventoryBundle`
- `RootYubiKeyInitSummary`
- `IntermediateRequestBundle`
- `SignedBundle`
- `SignerPolicy`
- `SignerStateRecord`

### `crypto/*`

Wraps certificate and CSR operations behind testable helpers instead of
spreading `openssl` command assembly through shell scripts.

This layer should:

- prefer `cryptography` for parse, inspect, fingerprint, and serialization work
- use subprocess calls only when direct library support is missing or less
  reliable for the target environment
- keep OpenSSL invocation in one place when it must still be used

### `yubikey/*`

Owns hardware-facing behavior and isolates YubiKey-specific code.

This layer should:

- use `ykman` for token discovery and PIV operations where possible
- use PKCS#11 through `python-pkcs11` or a narrow subprocess wrapper only when
  required
- normalize token identity, slot, attestation, and routine key URI behavior

### `storage/*`

Owns filesystem layout and bundle movement:

- archive paths
- bundle naming
- inventory write destinations
- signer-state directory reads and writes
- atomic replacement for staged imports

### `ui/*`

Owns presentation-only concerns. This should be thin and disposable.

In the first pass, this layer can stay CLI-oriented and avoid a heavy GUI
rewrite. The provisioning appliance can still use Zenity or a shell wrapper if
that reduces migration risk, as long as the core ceremony logic lives in
Python.

## Libraries

Recommended direct dependencies:

- `typer`
- `pydantic`
- `cryptography`
- `ykman`
- `python-pkcs11`

Optional dependencies:

- `rich` for better CLI output
- `pytest` for unit and fixture tests

Keep these as implementation details behind the application boundary so Nix
packages and higher-level workflows do not depend on library-specific behavior.

## Command Compatibility Plan

The current shell command surface should remain valid during migration.

Map the existing commands to the new Python app like this:

```text
pd-pki-signing-tools init-root-yubikey
  -> pd-pki-workflow root provision apply

pd-pki-signing-tools export-root-inventory
  -> pd-pki-workflow root inventory export

pd-pki-signing-tools normalize-root-inventory
  -> pd-pki-workflow root inventory normalize

pd-pki-signing-tools verify-root-yubikey-identity
  -> pd-pki-workflow root inventory verify

pd-pki-signing-tools export-request
  -> pd-pki-workflow request export

pd-pki-signing-tools sign-request
  -> pd-pki-workflow request sign

pd-pki-signing-tools import-signed
  -> pd-pki-workflow request import-signed

pd-pki-signing-tools revoke-issued
  -> pd-pki-workflow signer revoke

pd-pki-signing-tools generate-crl
  -> pd-pki-workflow signer generate-crl
```

During migration, [packages/pd-pki-signing-tools.nix](../packages/pd-pki-signing-tools.nix)
can shrink into a compatibility wrapper that forwards arguments to the Python
app and preserves the current command names.

## Frontend Plan

### `pd-pki-signing-tools`

Convert from a large shell implementation into a thin compatibility layer.

### `pd-pki-operator`

Keep as a separate user-facing entrypoint if the operator experience should stay
distinct, but make it call workflow APIs instead of reimplementing business
logic.

### `pd-pki-root-yubikey-provisioner-wizard`

Keep as the appliance-specific frontend, but reduce it to:

- device presence checks
- operator prompts
- removable-media prompts
- calls into the Python root provisioning workflow

## Migration Plan

### Phase 1: Contract And Model Extraction

- introduce `pyproject.toml`
- create the Python package skeleton
- model root inventory and summary contracts in `contracts/*`
- write fixture-based tests using existing inventory examples

### Phase 2: Root Inventory Workflow

- implement `root inventory export`
- implement `root inventory normalize`
- implement `root inventory verify`
- keep current shell commands as wrappers

This is the safest first workflow because it is contract-heavy and relatively
easy to test with fixtures.

### Phase 3: Root Provisioning Workflow

- implement dry-run plan generation
- implement apply flow around YubiKey operations
- move summary and archive generation into Python
- keep the appliance wizard as a thin caller

### Phase 4: Generic Request Signing Workflow

- implement request export, sign, and import-signed in Python
- move signer policy validation and signer-state writes out of shell
- preserve bundle layout and runtime state shape

### Phase 5: Revocation And CRL Workflow

- implement signer revocation mutation in Python
- implement CRL generation and metadata writing in Python
- remove duplicated shell logic once checks are green

## Testing Plan

Keep the current Nix checks, but shift more logic into normal Python tests.

Target split:

- Python unit tests for contract validation, path derivation, signer-state
  mutation, and certificate metadata handling
- fixture-driven Python tests for bundle normalization and compatibility
- Nix checks for packaged behavior, appliance integration, and full workflow
  contracts

This should reduce the amount of behavior that can only be validated inside a
large shell application.

## Non-Goals

- replacing NixOS modules with Python
- replacing flake outputs with Python packaging
- changing the normalized inventory contract during the first migration pass
- renaming user-facing commands immediately

## Success Criteria

This refactor is successful if:

- the large shell bodies in the current Nix packages shrink substantially
- workflow contracts become explicit Python models instead of ad hoc JSON
  assembly
- the appliance and operator frontends share one workflow implementation
- Nix remains the deployment and packaging layer rather than the home of most
  imperative logic

## Suggested First Commit

The best first slice is:

1. add `pyproject.toml`
2. add `src/pd_pki_workflow/contracts/root_inventory.py`
3. add `src/pd_pki_workflow/workflows/root_inventory.py`
4. add a thin `pd-pki-workflow` CLI with:
   `root inventory export`, `normalize`, and `verify`
5. convert the existing shell entrypoints for those three commands into wrappers

That gives the project a real application boundary without forcing a risky
big-bang rewrite.
