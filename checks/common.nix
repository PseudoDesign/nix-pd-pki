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

  checkJsonFiles = step: stepPathRef:
    concatMapStringsSep "\n" (file: ''
      printf '%s\n' "[${step.id}] parsing JSON artifact: ${file}"
      # Ensure declared JSON artifacts are well-formed.
      jq empty "${stepPathRef}/${file}"
      printf '%s\n' "[${step.id}] JSON artifact ok: ${file}"
    '') (filter (file: hasSuffix ".json" file) step.requiredFiles);

  validationCommand =
    {
      role,
      step,
      stepPathRef,
      validation,
    }:
    let
      artifacts = step.implementation.artifacts;
      certificatePath = pathOrEmpty artifacts "certificate";
      csrPath = pathOrEmpty artifacts "csr";
      chainPath = pathOrEmpty artifacts "chain";
    in
    if validation == "x509-parse" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating X.509 parsing"
      # Confirm the generated certificate is parseable X.509.
      openssl x509 -in "${stepPathRef}/${certificatePath}" -noout >/dev/null
      printf '%s\n' "[${role.id}/${step.id}] X.509 parsing passed"
    '' else if validation == "csr-parse" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating CSR parsing"
      # Confirm the generated certificate signing request is parseable.
      openssl req -in "${stepPathRef}/${csrPath}" -noout >/dev/null
      printf '%s\n' "[${role.id}/${step.id}] CSR parsing passed"
    '' else if validation == "self-signed" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating self-signed issuer/subject match"
      # Confirm the root certificate is self-issued in test mode.
      subject="$(openssl x509 -in "${stepPathRef}/${certificatePath}" -noout -subject)"
      issuer="$(openssl x509 -in "${stepPathRef}/${certificatePath}" -noout -issuer)"
      test "$subject" = "''${issuer/issuer=/subject=}"
      printf '%s\n' "[${role.id}/${step.id}] self-signed issuer/subject match passed"
    '' else if validation == "ca-basic-constraints" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating CA basic constraints"
      # Confirm the certificate is marked as a certificate authority.
      openssl x509 -in "${stepPathRef}/${certificatePath}" -noout -text | grep -q "CA:TRUE"
      printf '%s\n' "[${role.id}/${step.id}] CA basic constraints passed"
    '' else if validation == "chain-verify" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating certificate chain"
      # Confirm the certificate chains back to the bundled issuer chain.
      openssl verify -CAfile "${stepPathRef}/${chainPath}" "${stepPathRef}/${certificatePath}" >/dev/null
      printf '%s\n' "[${role.id}/${step.id}] certificate chain passed"
    '' else if validation == "server-eku" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating server EKU"
      # Confirm the leaf certificate is suitable for server authentication.
      openssl x509 -in "${stepPathRef}/${certificatePath}" -noout -text | grep -q "TLS Web Server Authentication"
      printf '%s\n' "[${role.id}/${step.id}] server EKU passed"
    '' else if validation == "client-eku" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating client EKU"
      # Confirm the leaf certificate is suitable for client authentication.
      openssl x509 -in "${stepPathRef}/${certificatePath}" -noout -text | grep -q "TLS Web Client Authentication"
      printf '%s\n' "[${role.id}/${step.id}] client EKU passed"
    '' else if validation == "san-present" then ''
      printf '%s\n' "[${role.id}/${step.id}] validating subject alternative names"
      # Confirm subject alternative names are present on the CSR or certificate.
      if [ -n "${certificatePath}" ]; then
        openssl x509 -in "${stepPathRef}/${certificatePath}" -noout -text | grep -q "Subject Alternative Name"
      else
        openssl req -in "${stepPathRef}/${csrPath}" -noout -text | grep -q "Subject Alternative Name"
      fi
      printf '%s\n' "[${role.id}/${step.id}] subject alternative names passed"
    '' else if validation == "json-parse" then
      checkJsonFiles step stepPathRef
    else
      "# Unsupported validation ${validation}\n";

  stepCheckCommands = role: step: stepPathRef:
    let
      artifacts = step.implementation.artifacts;
      manifestPath =
        if builtins.hasAttr "manifest" artifacts then artifacts.manifest
        else if builtins.hasAttr "metadata" artifacts then artifacts.metadata
        else "";
      requestPath = pathOrEmpty artifacts "request";
      validationCommands = concatMapStringsSep "\n" (
        validation:
        validationCommand {
          inherit
            role
            step
            stepPathRef
            validation
            ;
        }
      ) step.validations;
    in
    ''
      printf '%s\n' "[${role.id}/${step.id}] starting step check"

      # Validate the step output layout and its machine-readable metadata.
      test -d "${stepPathRef}"
      test -f "${stepPathRef}/define.json"
      test -f "${stepPathRef}/checks.json"
      test -f "${stepPathRef}/status.json"
      printf '%s\n' "[${role.id}/${step.id}] step metadata present"

      # Confirm every required artifact declared by the step contract exists.
      ${concatMapStringsSep "\n" (file: ''
        printf '%s\n' "[${role.id}/${step.id}] checking required artifact: ${file}"
        test -e "${stepPathRef}/${file}"
        printf '%s\n' "[${role.id}/${step.id}] required artifact present: ${file}"
      '') step.requiredFiles}

      # Check optional manifest and request metadata when the step declares them.
      ${if manifestPath != "" && !(hasSuffix ".json" manifestPath) then ''
        printf '%s\n' "[${role.id}/${step.id}] checking manifest artifact: ${manifestPath}"
        test -e "${stepPathRef}/${manifestPath}"
        printf '%s\n' "[${role.id}/${step.id}] manifest artifact present: ${manifestPath}"
      '' else ""}
      ${if requestPath != "" then ''
        printf '%s\n' "[${role.id}/${step.id}] parsing request metadata: ${requestPath}"
        jq empty "${stepPathRef}/${requestPath}"
        printf '%s\n' "[${role.id}/${step.id}] request metadata ok: ${requestPath}"
      '' else ""}

      # Run the validation suite declared for this specific step.
      ${validationCommands}

      printf '%s\n' "[${role.id}/${step.id}] step check passed"
    '';

  roleCheckCommands = role: rolePathRef: ''
    printf '%s\n' "[${role.id}] starting role check"

    # Validate the role-level metadata exported by the package.
    test -d "${rolePathRef}"
    test -f "${rolePathRef}/role.json"
    test -f "${rolePathRef}/steps.json"
    jq empty "${rolePathRef}/role.json"
    jq empty "${rolePathRef}/steps.json"
    printf '%s\n' "[${role.id}] role metadata passed"

    # Confirm the role exposes exactly the expected set of steps.
    expected_count=${toString (builtins.length role.steps)}
    actual_count=$(find "${rolePathRef}/steps" -mindepth 1 -maxdepth 1 -type d | wc -l)
    test "$expected_count" -eq "$actual_count"
    ${concatMapStringsSep "\n" (step: ''
      printf '%s\n' "[${role.id}] checking step directory: ${step.id}"
      test -d "${rolePathRef}/steps/${step.id}"
      test -f "${rolePathRef}/steps/${step.id}/define.json"
      test -f "${rolePathRef}/steps/${step.id}/checks.json"
      test -f "${rolePathRef}/steps/${step.id}/status.json"
      printf '%s\n' "[${role.id}] step directory passed: ${step.id}"
    '') role.steps}

    printf '%s\n' "[${role.id}] role check passed"
  '';

  mkStepCheck = role: step:
    let
      rolePackage = packages.${role.id};
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

        step_path="${rolePackage}/steps/${step.id}"
        ${stepCheckCommands role step "$step_path"}
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

        role_path="${packages.${role.id}}"
        ${roleCheckCommands role "$role_path"}
        touch "$out"
      '';
    };

  checksForRole = role:
    listToAttrs ([ (mkRoleCheck role) ] ++ map (step: mkStepCheck role step) role.steps);
}
