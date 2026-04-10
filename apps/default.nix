{
  pkgs,
  definitions,
  checkNames,
}:
let
  sharedCheckManifest = [
    {
      name = "define-contract";
      title = "Validate Definition Contract";
      description = "Confirm the top-level PKI definitions serialize to valid JSON.";
    }
    {
      name = "openvpn-mutual-auth";
      title = "Validate OpenVPN Mutual Auth";
      description = "Boot an OpenVPN server and client with the generated PKI artifacts and prove mutual TLS authentication succeeds.";
    }
    {
      name = "pd-pki";
      title = "Validate Aggregate Package";
      description = "Confirm the aggregate pd-pki package exposes the expected role packages.";
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

  testReport = pkgs.writeShellApplication {
    name = "test-report";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.nix
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
        jq -r '.checks[] | "| `\(.name)` | \(.title) | \(.status) | \(.exitCode) | \(.durationDisplay) | `\(.logFile)` |"' "$report_json"
        printf '\n## Check Descriptions\n\n'
        jq -r '.checks[] | "### \(.title)\n\n- Check ID: `\(.name)`\n- Description: \(.description)\n- Status: \(.status)\n- Log: `\(.logFile)`\n"' "$report_json"
      } > "$report_md"

      printf '%s\n' "Markdown report: $report_md"
      printf '%s\n' "JSON report: $report_json"

      if [ "$failed_checks" -gt 0 ]; then
        printf '%s\n' "One or more checks failed. See the report and per-check logs in $report_dir" >&2
        exit 1
      fi
    '';
  };
in
{
  inherit testReport;
}
