{
  pkgs,
  definitions,
  checkNames,
  packages,
}:
let
  sharedCheckManifest = [
    {
      name = "module-runtime-artifacts";
      title = "Validate Module Runtime Artifacts";
      description = "Boot each role module and confirm it only creates local mutable artifacts while staging any imported certificates and chains.";
    }
    {
      name = "openvpn-daemon";
      title = "Validate OpenVPN Daemon Behavior";
      description = "Boot real OpenVPN server and client daemons, drive the external signer/import flow, verify tunnel establishment, and confirm revoked client certificates are rejected.";
    }
    {
      name = "rpi5-root-ca-hardening";
      title = "Validate Root CA Appliance Hardening";
      description = "Confirm the offline Raspberry Pi root CA image disables onboard radios and admits only the USB classes needed for the signing workflow.";
    }
    {
      name = "role-topology";
      title = "Validate Linux Role Topology";
      description = "Boot one Linux VM per role and run the exported role and step checks through the installed NixOS modules.";
    }
    {
      name = "pd-pki";
      title = "Validate Aggregate Package";
      description = "Confirm the aggregate pd-pki package exposes the expected role packages.";
    }
    {
      name = "signing-tools-pkcs11";
      title = "Validate Signing Tools PKCS#11 Flow";
      description = "Exercise the signer tooling against a software PKCS#11 token for signing, revocation, and CRL generation.";
    }
    {
      name = "signing-tools-root-yubikey-init";
      title = "Validate Root YubiKey Init Flow";
      description = "Verify the root YubiKey initialization tooling enforces dry-run review and guarded apply preconditions.";
    }
    {
      name = "e2e-root-yubikey-provisioning-contract";
      title = "E2E: Root YubiKey Provisioning Contract";
      description = "Validate the workflow-facing dry-run outputs that seed the root CA YubiKey provisioning contract.";
    }
    {
      name = "e2e-root-inventory-export-bundle-contract";
      title = "E2E: Root Inventory Export Bundle";
      description = "Validate the removable-media root inventory bundle exported from a completed root YubiKey provisioning ceremony.";
    }
    {
      name = "e2e-root-yubikey-inventory-normalization";
      title = "E2E: Root Inventory Normalization";
      description = "Validate the normalized public root CA inventory contract that will be committed into the repository.";
    }
    {
      name = "e2e-root-yubikey-identity-verification";
      title = "E2E: Root YubiKey Identity Verification";
      description = "Validate that workflow identity checks key off the committed root certificate and verified public key rather than serial alone.";
    }
    {
      name = "e2e-root-intermediate-request-bundle-contract";
      title = "E2E: Intermediate Request Bundle";
      description = "Validate the removable-media request bundle exported from the intermediate runtime state.";
    }
    {
      name = "e2e-root-intermediate-signed-bundle-contract";
      title = "E2E: Intermediate Signed Bundle";
      description = "Validate the signed intermediate bundle produced by the offline root workflow.";
    }
    {
      name = "e2e-root-intermediate-airgap-handoff";
      title = "E2E: Intermediate Air-Gap Handoff";
      description = "Validate the request export, offline signing, USB handoff, and signed import loop for the intermediate CA workflow.";
    }
  ];

  roleCheckManifest = map (role: {
    name = role.id;
    title = "Validate ${role.title} Package";
    description = "Verify the ${role.title} package exports its role metadata and expected step directories.";
  }) definitions.roles;

  stepCheckManifest = builtins.concatLists (
    map (
      role:
      map (step: {
        name = "${role.id}-${step.id}";
        title = "${role.title}: ${step.title}";
        description = step.summary;
      }) role.steps
    ) definitions.roles
  );

  moduleCheckManifest =
    [
      {
        name = "nixos-module-default";
        title = "Validate Default NixOS Module";
        description = "Evaluate the default pd-pki NixOS module and confirm it enables all role packages.";
      }
    ]
    ++ map (role: {
      name = "nixos-module-${role.id}";
      title = "Validate ${role.title} NixOS Module";
      description = "Evaluate the ${role.title} NixOS module and confirm it installs the expected package and declared step IDs.";
    }) definitions.roles;

  checkManifestData =
    sharedCheckManifest
    ++ roleCheckManifest
    ++ stepCheckManifest
    ++ moduleCheckManifest;

  checkManifest =
    assert map (check: check.name) checkManifestData == checkNames;
    pkgs.writeText "pd-pki-check-manifest.json" (builtins.toJSON checkManifestData);

  pdPkiOperator = packages.pd-pki-operator;

  testReport = pkgs.writeShellApplication {
    name = "test-report";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.nix
      pkgs.pandoc
    ];
    text = ''
      set -euo pipefail

      format_duration() {
        duration_ms="$1"

        if [ "$duration_ms" -lt 1000 ]; then
          printf '%sms' "$duration_ms"
        elif [ "$duration_ms" -lt 60000 ]; then
          seconds=$((duration_ms / 1000))
          milliseconds=$((duration_ms % 1000))
          printf '%ss %03dms' "$seconds" "$milliseconds"
        else
          total_seconds=$((duration_ms / 1000))
          minutes=$((total_seconds / 60))
          seconds=$((total_seconds % 60))
          printf '%sm %02ds' "$minutes" "$seconds"
        fi
      }

      usage() {
        printf '%s\n' "Usage: test-report [--out-dir PATH] [--flake PATH] [--verbose|--debug]" >&2
      }

      out_root="$PWD/reports"
      flake_ref="$(pwd -P)"
      verbose=0

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --out-dir)
            out_root="$2"
            shift 2
            ;;
          --flake)
            flake_ref="$2"
            shift 2
            ;;
          --verbose|--debug)
            verbose=1
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            printf '%s\n' "Unknown argument: $1" >&2
            usage
            exit 2
            ;;
        esac
      done

      flake_ref="$(cd "$flake_ref" && pwd -P)"
      mkdir -p "$out_root"
      out_root="$(cd "$out_root" && pwd -P)"

      if [ ! -f "$flake_ref/flake.nix" ]; then
        printf '%s\n' "No flake.nix found at $flake_ref" >&2
        exit 2
      fi

      timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
      generated_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      report_dir="$out_root/test-report-$timestamp"
      logs_dir="$report_dir/logs"
      results_file="$report_dir/check-results.json"
      report_json="$report_dir/report.json"
      report_md="$report_dir/report.md"
      report_site_md="$report_dir/site.md"
      report_html="$report_dir/index.html"
      report_css="$report_dir/style.css"

      mkdir -p "$logs_dir"
      printf '[]\n' > "$results_file"

      system='${pkgs.stdenv.hostPlatform.system}'
      manifest='${checkManifest}'

      total_checks="$(jq 'length' "$manifest")"
      passed_checks=0
      failed_checks=0

      printf '%s\n' "Writing test report to $report_dir"
      printf '%s\n' "Running $total_checks checks for system $system"
      if [ "$verbose" -eq 1 ]; then
        printf '%s\n' "Verbose output enabled; streaming build, package, and test status logs"
      fi

      while IFS="$(printf '\t')" read -r check_name check_title check_description; do
        log_path="logs/$check_name.log"
        log_file="$logs_dir/$check_name.log"
        build_target="$flake_ref#checks.$system.$check_name"
        build_output_file="$(mktemp "$report_dir/$check_name.output.XXXXXX")"
        started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        start_epoch_ms="$(date +%s%3N)"

        build_cmd=(
          nix
          build
          --no-link
          --print-build-logs
          --print-out-paths
          "$build_target"
        )

        {
          printf 'Check: %s\n' "$check_name"
          printf 'Title: %s\n' "$check_title"
          printf 'Description: %s\n' "$check_description"
          printf 'Target: %s\n' "$build_target"
          printf 'Started at (UTC): %s\n' "$started_at_utc"
          printf 'Command: '
          printf '%q ' "''${build_cmd[@]}"
          printf '\n'
          printf '%s\n' "--- Begin nix output ---"
        } > "$log_file"

        printf '%s\n' "==> $check_title [$check_name]"
        if [ "$verbose" -eq 1 ]; then
          printf '%s\n' "    description: $check_description"
          printf '%s\n' "    log: $log_file"
        fi

        set +e
        if [ "$verbose" -eq 1 ]; then
          "''${build_cmd[@]}" 2>&1 | tee "$build_output_file" | tee -a "$log_file"
          exit_code=''${PIPESTATUS[0]}
        else
          "''${build_cmd[@]}" >"$build_output_file" 2>&1
          exit_code=$?
          cat "$build_output_file" >> "$log_file"
        fi
        set -e

        if [ ! -s "$build_output_file" ]; then
          printf '%s\n' "(nix build produced no stdout/stderr for this check)" >> "$log_file"
        fi

        if [ "$exit_code" -eq 0 ]; then
          status="passed"
          failed_message=""
          store_path="$(grep -E '^/nix/store/' "$build_output_file" | tail -n1 || true)"
          passed_checks=$((passed_checks + 1))
        else
          status="failed"
          failed_message="$(tail -n1 "$build_output_file" || true)"
          if [ -z "$failed_message" ]; then
            failed_message="nix build exited with code $exit_code"
          fi
          store_path=""
          failed_checks=$((failed_checks + 1))
        fi

        finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        end_epoch_ms="$(date +%s%3N)"
        duration_milliseconds=$((end_epoch_ms - start_epoch_ms))
        duration_seconds=$((duration_milliseconds / 1000))
        duration_display="$(format_duration "$duration_milliseconds")"

        if [ "$status" = "passed" ]; then
          printf '%s\n' "PASS $duration_display"
        else
          printf '%s\n' "FAIL $duration_display: $failed_message"
        fi

        {
          printf '%s\n' "--- End nix output ---"
          printf 'Finished at (UTC): %s\n' "$finished_at_utc"
          printf 'Duration: %s\n' "$duration_display"
          printf 'Duration (ms): %s\n' "$duration_milliseconds"
          printf 'Exit code: %s\n' "$exit_code"
          printf 'Status: %s\n' "$status"
          if [ -n "$store_path" ]; then
            printf 'Store path: %s\n' "$store_path"
          fi
          if [ -n "$failed_message" ]; then
            printf 'Failure message: %s\n' "$failed_message"
          fi
        } >> "$log_file"

        rm -f "$build_output_file"

        jq \
          --arg name "$check_name" \
          --arg title "$check_title" \
          --arg description "$check_description" \
          --arg status "$status" \
          --arg startedAtUtc "$started_at_utc" \
          --arg finishedAtUtc "$finished_at_utc" \
          --arg durationDisplay "$duration_display" \
          --arg logPath "$log_path" \
          --arg logFile "$log_file" \
          --arg storePath "$store_path" \
          --arg failureMessage "$failed_message" \
          --argjson exitCode "$exit_code" \
          --argjson durationMilliseconds "$duration_milliseconds" \
          --argjson durationSeconds "$duration_seconds" \
          '. += [{
            name: $name,
            title: $title,
            description: $description,
            status: $status,
            exitCode: $exitCode,
            durationDisplay: $durationDisplay,
            durationMilliseconds: $durationMilliseconds,
            durationSeconds: $durationSeconds,
            startedAtUtc: $startedAtUtc,
            finishedAtUtc: $finishedAtUtc,
            logPath: $logPath,
            logFile: $logFile,
            storePath: $storePath,
            failureMessage: $failureMessage
          }]' \
          "$results_file" > "$results_file.tmp"
        mv "$results_file.tmp" "$results_file"
      done < <(jq -r '.[] | [.name, .title, .description] | @tsv' "$manifest")

      jq -n \
        --arg generatedAtUtc "$generated_at_utc" \
        --arg flakeRef "$flake_ref" \
        --arg system "$system" \
        --arg reportDir "$report_dir" \
        --argjson totalChecks "$total_checks" \
        --argjson passedChecks "$passed_checks" \
        --argjson failedChecks "$failed_checks" \
        --slurpfile checks "$results_file" \
        '{
          generatedAtUtc: $generatedAtUtc,
          flakeRef: $flakeRef,
          system: $system,
          reportDir: $reportDir,
          summary: {
            totalChecks: $totalChecks,
            passedChecks: $passedChecks,
            failedChecks: $failedChecks,
            status: if $failedChecks == 0 then "passed" else "failed" end
          },
          checks: $checks[0]
        }' > "$report_json"

      {
        printf '# pd-pki Test Report\n\n'
        printf -- "- Generated at (UTC): \`%s\`\n" "$generated_at_utc"
        printf -- "- Flake: \`%s\`\n" "$flake_ref"
        printf -- "- System: \`%s\`\n" "$system"
        printf -- "- Total checks: \`%s\`\n" "$total_checks"
        printf -- "- Passed: \`%s\`\n" "$passed_checks"
        printf -- "- Failed: \`%s\`\n\n" "$failed_checks"
        printf '| Check | Title | Status | Exit Code | Duration | Log |\n'
        printf '| --- | --- | --- | ---: | --- | --- |\n'
        jq -r '.checks[] | "| `\(.name)` | \(.title) | \(.status) | \(.exitCode) | \(.durationDisplay) | `\(.logPath)` |"' "$report_json"
        printf '\n## Check Descriptions\n\n'
        jq -r '.checks[] | "### \(.title)\n\n- Check ID: `\(.name)`\n- Description: \(.description)\n- Status: \(.status)\n- Log: `\(.logPath)`\n"' "$report_json"
      } > "$report_md"

      {
        printf '# pd-pki Test Report\n\n'
        printf -- "- Generated at (UTC): \`%s\`\n" "$generated_at_utc"
        printf -- "- Flake: \`%s\`\n" "$flake_ref"
        printf -- "- System: \`%s\`\n" "$system"
        printf -- "- Total checks: \`%s\`\n" "$total_checks"
        printf -- "- Passed: \`%s\`\n" "$passed_checks"
        printf -- "- Failed: \`%s\`\n\n" "$failed_checks"
        printf '## Report Files\n\n'
        printf -- "- [HTML report](index.html)\n"
        printf -- "- [Markdown report](report.md)\n"
        printf -- "- [JSON report](report.json)\n\n"
        printf '| Check | Title | Status | Exit Code | Duration | Log |\n'
        printf '| --- | --- | --- | ---: | --- | --- |\n'
        jq -r '.checks[] | "| `\(.name)` | \(.title) | \(.status) | \(.exitCode) | \(.durationDisplay) | [view log](\(.logPath)) |"' "$report_json"
        printf '\n## Check Descriptions\n\n'
        jq -r '.checks[] | "### \(.title)\n\n- Check ID: `\(.name)`\n- Description: \(.description)\n- Status: \(.status)\n- Log: [\(.logPath)](\(.logPath))\n"' "$report_json"
      } > "$report_site_md"

      cat > "$report_css" <<'EOF'
:root {
  --background: #f3efe5;
  --surface: rgba(255, 255, 255, 0.92);
  --surface-strong: #fffdf8;
  --border: #d8d3c5;
  --text: #1d2733;
  --muted: #53606c;
  --accent: #0b6e69;
  --accent-soft: #d9f0ed;
  --pass: #1f7a3d;
  --fail: #b42318;
}

html {
  background:
    radial-gradient(circle at top left, rgba(11, 110, 105, 0.12), transparent 28rem),
    linear-gradient(180deg, #f7f3ea 0%, #edf3f5 100%);
}

body {
  margin: 0 auto;
  max-width: 72rem;
  padding: 2.5rem 1.25rem 4rem;
  color: var(--text);
  font-family: "IBM Plex Sans", "Segoe UI", sans-serif;
  line-height: 1.6;
}

body > * {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 1rem;
  box-shadow: 0 1rem 2.5rem rgba(29, 39, 51, 0.08);
  margin: 0 0 1.25rem;
  padding: 1.25rem 1.5rem;
}

h1,
h2,
h3 {
  color: #13202b;
  line-height: 1.2;
}

h1 {
  background:
    linear-gradient(135deg, rgba(11, 110, 105, 0.12), rgba(255, 255, 255, 0)) var(--surface-strong);
  font-size: 2.1rem;
  letter-spacing: -0.03em;
}

a {
  color: var(--accent);
  font-weight: 600;
  text-decoration-thickness: 0.08em;
  text-underline-offset: 0.14em;
}

table {
  border-collapse: collapse;
  display: block;
  overflow-x: auto;
  width: 100%;
}

th,
td {
  border-bottom: 1px solid var(--border);
  padding: 0.75rem;
  text-align: left;
  vertical-align: top;
}

th {
  background: rgba(11, 110, 105, 0.08);
}

code {
  background: rgba(19, 32, 43, 0.08);
  border-radius: 0.35rem;
  font-family: "IBM Plex Mono", "SFMono-Regular", monospace;
  padding: 0.08rem 0.35rem;
}

pre {
  background: #13202b;
  border-radius: 0.85rem;
  color: #f7f9fb;
  overflow-x: auto;
  padding: 1rem;
}

blockquote {
  background: var(--accent-soft);
  border-left: 0.35rem solid var(--accent);
  color: var(--muted);
  margin: 0;
}

li > p:last-child {
  margin-bottom: 0;
}

strong {
  color: #13202b;
}

@media (max-width: 640px) {
  body {
    padding: 1rem 0.75rem 2rem;
  }

  body > * {
    padding: 1rem;
  }

  h1 {
    font-size: 1.7rem;
  }
}
EOF

      pandoc \
        --from gfm \
        --to html5 \
        --standalone \
        --metadata title='pd-pki Test Report' \
        --css style.css \
        --output "$report_html" \
        "$report_site_md"

      touch "$report_dir/.nojekyll"

      printf '%s\n' "Markdown report: $report_md"
      printf '%s\n' "JSON report: $report_json"
      printf '%s\n' "HTML report: $report_html"

      if [ "$failed_checks" -gt 0 ]; then
        printf '%s\n' "One or more checks failed. See the report and per-check logs in $report_dir" >&2
        exit 1
      fi
    '';
  };
in
{
  inherit testReport pdPkiOperator;
}
