{
  pkgs,
  definitions,
  checkNames,
}:
let
  checkManifest = pkgs.writeText "pd-pki-check-manifest.json" (builtins.toJSON checkNames);

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

      while IFS= read -r check_name; do
        log_file="$logs_dir/$check_name.log"
        started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        start_epoch="$(date +%s)"

        printf '%s\n' "==> $check_name"
        if [ "$verbose" -eq 1 ]; then
          printf '%s\n' "    log: $log_file"
        fi

        set +e
        if [ "$verbose" -eq 1 ]; then
          nix build --no-link --print-build-logs "$flake_ref#checks.$system.$check_name" 2>&1 | tee "$log_file"
          exit_code=''${PIPESTATUS[0]}
        else
          nix build --no-link --print-build-logs "$flake_ref#checks.$system.$check_name" >"$log_file" 2>&1
          exit_code=$?
        fi
        set -e

        if [ "$exit_code" -eq 0 ]; then
          status="passed"
          failed_message=""
          store_path="$(grep -E '^/nix/store/' "$log_file" | tail -n1 || true)"
          passed_checks=$((passed_checks + 1))
          printf '%s\n' "PASS $check_name"
        else
          status="failed"
          failed_message="$(tail -n1 "$log_file" || true)"
          store_path=""
          failed_checks=$((failed_checks + 1))
          printf '%s\n' "FAIL $check_name"
        fi

        finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        end_epoch="$(date +%s)"
        duration_seconds=$((end_epoch - start_epoch))

        jq \
          --arg name "$check_name" \
          --arg status "$status" \
          --arg startedAtUtc "$started_at_utc" \
          --arg finishedAtUtc "$finished_at_utc" \
          --arg logFile "$log_file" \
          --arg storePath "$store_path" \
          --arg failureMessage "$failed_message" \
          --argjson exitCode "$exit_code" \
          --argjson durationSeconds "$duration_seconds" \
          '. += [{
            name: $name,
            status: $status,
            exitCode: $exitCode,
            durationSeconds: $durationSeconds,
            startedAtUtc: $startedAtUtc,
            finishedAtUtc: $finishedAtUtc,
            logFile: $logFile,
            storePath: $storePath,
            failureMessage: $failureMessage
          }]' \
          "$results_file" > "$results_file.tmp"
        mv "$results_file.tmp" "$results_file"
      done < <(jq -r '.[]' "$manifest")

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
        printf '| Check | Status | Exit Code | Duration (s) | Log |\n'
        printf '| --- | --- | ---: | ---: | --- |\n'
        jq -r '.checks[] | "| `\(.name)` | \(.status) | \(.exitCode) | \(.durationSeconds) | `\(.logFile)` |"' "$report_json"
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
