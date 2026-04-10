{
  pkgs,
  packages,
}:
let
  inherit (pkgs.lib)
    concatMapStringsSep
    filter
    hasSuffix
    listToAttrs
    ;
in
rec {
  pathOrEmpty = artifacts: name:
    if builtins.hasAttr name artifacts then artifacts.${name} else "";

  checkJsonFiles = step:
    concatMapStringsSep "\n" (file: ''
      printf '%s\n' "[${step.id}] parsing JSON artifact: ${file}"
      # Ensure declared JSON artifacts are well-formed.
      jq empty "$step_path/${file}"
      printf '%s\n' "[${step.id}] JSON artifact ok: ${file}"
    '') (filter (file: hasSuffix ".json" file) step.requiredFiles);

  bundleCheckCommands = step:
    let
      artifacts = step.implementation.artifacts;
      bundlePath = pathOrEmpty artifacts "bundle";
      manifestPath =
        if builtins.hasAttr "manifest" artifacts then artifacts.manifest
        else if builtins.hasAttr "metadata" artifacts then artifacts.metadata
        else "";
    in
    ''
      ${if bundlePath != "" then ''
        printf '%s\n' "[${step.id}] checking bundle directory: ${bundlePath}"
        # Verify the bundle directory expected by this step exists.
        test -d "$step_path/${bundlePath}"
        printf '%s\n' "[${step.id}] bundle directory ok: ${bundlePath}"
      '' else ""}
      ${if manifestPath != "" then ''
        printf '%s\n' "[${step.id}] parsing bundle metadata: ${manifestPath}"
        # Verify the bundle metadata can be parsed as JSON.
        jq empty "$step_path/${manifestPath}"
        printf '%s\n' "[${step.id}] bundle metadata ok: ${manifestPath}"
      '' else ""}
    '';

  validationCommand = role: step: validation:
    let
      artifacts = step.implementation.artifacts;
      certificatePath = pathOrEmpty artifacts "certificate";
      csrPath = pathOrEmpty artifacts "csr";
      chainPath = pathOrEmpty artifacts "chain";
      recordPath = pathOrEmpty artifacts "record";
      statusPath = pathOrEmpty artifacts "status";
    in
    if validation == "x509-parse" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating X.509 parsing"
      # Confirm the generated certificate is parseable X.509.
      openssl x509 -in "$step_path/${certificatePath}" -noout >/dev/null
      printf '%s\n' "[${role.id}/${step.id}] X.509 parsing passed"
    '' else if validation == "csr-parse" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating CSR parsing"
      # Confirm the generated certificate signing request is parseable.
      openssl req -in "$step_path/${csrPath}" -noout >/dev/null
      printf '%s\n' "[${role.id}/${step.id}] CSR parsing passed"
    '' else if validation == "self-signed" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating self-signed issuer/subject match"
      # Confirm the root certificate is self-issued in test mode.
      subject="$(openssl x509 -in "$step_path/${certificatePath}" -noout -subject)"
      issuer="$(openssl x509 -in "$step_path/${certificatePath}" -noout -issuer)"
      test "$subject" = "''${issuer/issuer=/subject=}"
      printf '%s\n' "[${role.id}/${step.id}] self-signed issuer/subject match passed"
    '' else if validation == "ca-basic-constraints" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating CA basic constraints"
      # Confirm the certificate is marked as a certificate authority.
      openssl x509 -in "$step_path/${certificatePath}" -noout -text | grep -q "CA:TRUE"
      printf '%s\n' "[${role.id}/${step.id}] CA basic constraints passed"
    '' else if validation == "chain-verify" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating certificate chain"
      # Confirm the certificate chains back to the bundled issuer chain.
      openssl verify -CAfile "$step_path/${chainPath}" "$step_path/${certificatePath}" >/dev/null
      printf '%s\n' "[${role.id}/${step.id}] certificate chain passed"
    '' else if validation == "server-eku" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating server EKU"
      # Confirm the leaf certificate is suitable for server authentication.
      openssl x509 -in "$step_path/${certificatePath}" -noout -text | grep -q "TLS Web Server Authentication"
      printf '%s\n' "[${role.id}/${step.id}] server EKU passed"
    '' else if validation == "client-eku" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating client EKU"
      # Confirm the leaf certificate is suitable for client authentication.
      openssl x509 -in "$step_path/${certificatePath}" -noout -text | grep -q "TLS Web Client Authentication"
      printf '%s\n' "[${role.id}/${step.id}] client EKU passed"
    '' else if validation == "san-present" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating subject alternative names"
      # Confirm subject alternative names are present on the CSR or certificate.
      if [ -n "${certificatePath}" ]; then
        openssl x509 -in "$step_path/${certificatePath}" -noout -text | grep -q "Subject Alternative Name"
      else
        openssl req -in "$step_path/${csrPath}" -noout -text | grep -q "Subject Alternative Name"
      fi
      printf '%s\n' "[${role.id}/${step.id}] subject alternative names passed"
    '' else if validation == "bundle-complete" then
      bundleCheckCommands step
    else if validation == "trust-bundle" then
      bundleCheckCommands step
    else if validation == "revocation-json" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating revocation metadata"
      # Confirm the revocation metadata files are well-formed JSON.
      ${if recordPath != "" then ''jq empty "$step_path/${recordPath}"'' else ""}
      ${if statusPath != "" then ''jq empty "$step_path/${statusPath}"'' else ""}
      printf '%s\n' "[${role.id}/${step.id}] revocation metadata passed"
    '' else if validation == "json-parse" then
      checkJsonFiles step
    else
      "# Unsupported validation ${validation}\n";

  mkStepCheck = role: step:
    let
      artifacts = step.implementation.artifacts;
      keyPath = pathOrEmpty artifacts "key";
      manifestPath =
        if builtins.hasAttr "manifest" artifacts then artifacts.manifest
        else if builtins.hasAttr "metadata" artifacts then artifacts.metadata
        else "";
      requestPath = pathOrEmpty artifacts "request";
      rolePackage = packages.${role.id};
      validationCommands = concatMapStringsSep "\n" (validation: validationCommand role step validation) step.validations;
    in
    {
      name = "${role.id}-${step.id}";
      value = pkgs.runCommand "${role.id}-${step.id}-check" {
        nativeBuildInputs = [
          pkgs.openssl
          pkgs.jq
        ];
      } ''
        set -euo pipefail

        printf '%s\n' "[${role.id}/${step.id}] starting step check"

        # Validate the step output layout and its machine-readable metadata.
        step_path="${rolePackage}/steps/${step.id}"
        test -d "$step_path"
        test -f "$step_path/define.json"
        test -f "$step_path/checks.json"
        test -f "$step_path/status.json"
        printf '%s\n' "[${role.id}/${step.id}] step metadata present"

        # Confirm every required artifact declared by the step contract exists.
        ${concatMapStringsSep "\n" (file: ''
          printf '%s\n' "[${role.id}/${step.id}] checking required artifact: ${file}"
          test -e "$step_path/${file}"
          printf '%s\n' "[${role.id}/${step.id}] required artifact present: ${file}"
        '') step.requiredFiles}

        # Check optional key, manifest, and request metadata when the step declares them.
        ${if keyPath != "" then ''
          printf '%s\n' "[${role.id}/${step.id}] checking key artifact: ${keyPath}"
          test -f "$step_path/${keyPath}"
          printf '%s\n' "[${role.id}/${step.id}] key artifact present: ${keyPath}"
        '' else ""}
        ${if manifestPath != "" && !(hasSuffix ".json" manifestPath) then ''
          printf '%s\n' "[${role.id}/${step.id}] checking manifest artifact: ${manifestPath}"
          test -e "$step_path/${manifestPath}"
          printf '%s\n' "[${role.id}/${step.id}] manifest artifact present: ${manifestPath}"
        '' else ""}
        ${if requestPath != "" then ''
          printf '%s\n' "[${role.id}/${step.id}] parsing request metadata: ${requestPath}"
          jq empty "$step_path/${requestPath}"
          printf '%s\n' "[${role.id}/${step.id}] request metadata ok: ${requestPath}"
        '' else ""}

        # Run the validation suite declared for this specific step.
        ${validationCommands}

        printf '%s\n' "[${role.id}/${step.id}] step check passed"
        touch "$out"
      '';
    };

  mkRoleCheck = role:
    {
      name = role.id;
      value = pkgs.runCommand "${role.id}-check" {
        nativeBuildInputs = [ pkgs.jq ];
      } ''
        set -euo pipefail

        printf '%s\n' "[${role.id}] starting role check"

        # Validate the role-level metadata exported by the package.
        role_path="${packages.${role.id}}"
        test -d "$role_path"
        test -f "$role_path/role.json"
        test -f "$role_path/steps.json"
        jq empty "$role_path/role.json"
        jq empty "$role_path/steps.json"
        printf '%s\n' "[${role.id}] role metadata passed"

        # Confirm the role exposes exactly the expected set of steps.
        expected_count=${toString (builtins.length role.steps)}
        actual_count=$(find "$role_path/steps" -mindepth 1 -maxdepth 1 -type d | wc -l)
        test "$expected_count" -eq "$actual_count"
        ${concatMapStringsSep "\n" (step: ''
          printf '%s\n' "[${role.id}] checking step directory: ${step.id}"
          test -d "$role_path/steps/${step.id}"
          test -f "$role_path/steps/${step.id}/define.json"
          test -f "$role_path/steps/${step.id}/checks.json"
          test -f "$role_path/steps/${step.id}/status.json"
          printf '%s\n' "[${role.id}] step directory passed: ${step.id}"
        '') role.steps}

        printf '%s\n' "[${role.id}] role check passed"
        touch "$out"
      '';
    };

  checksForRole = role:
    listToAttrs ([ (mkRoleCheck role) ] ++ map (step: mkStepCheck role step) role.steps);
}
