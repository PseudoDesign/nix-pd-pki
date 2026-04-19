{ pkgs, pdPkiSigningTools }:
pkgs.writeShellApplication {
  name = "pd-pki-normalize-root-inventory-from-mount";
  runtimeInputs = [
    pdPkiSigningTools
    pkgs.coreutils
    pkgs.findutils
    pkgs.git
    pkgs.jq
    pkgs.openssl
    pkgs.gnused
  ];
  text = ''
    set -euo pipefail

    usage() {
      local exit_code="''${1:-1}"
      cat >&2 <<'EOF'
    Usage: pd-pki-normalize-root-inventory-from-mount [-v|--verbose] <mountpoint>

    Find the newest exported root-inventory bundle beneath:
      <mountpoint>/pd-pki-transfer/root-inventory/

    Then normalize it into the current git worktree's:
      inventory/root-ca/<root-id>/

    By default, print only a short title plus root certificate metadata.
    Use -v or --verbose to also print the normalized file list and git status.
    EOF
      exit "$exit_code"
    }

    verbose=0
    mountpoint_arg=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -h|--help)
          usage 0
          ;;
        -v|--verbose)
          verbose=1
          shift
          ;;
        --)
          shift
          break
          ;;
        -*)
          printf 'Unknown option: %s\n' "$1" >&2
          usage
          ;;
        *)
          if [ -n "$mountpoint_arg" ]; then
            usage
          fi
          mountpoint_arg="$1"
          shift
          ;;
      esac
    done

    if [ -z "$mountpoint_arg" ] && [ "$#" -gt 0 ]; then
      mountpoint_arg="$1"
      shift
    fi

    [ -n "$mountpoint_arg" ] || usage
    [ "$#" -eq 0 ] || usage

    if ! mountpoint="$(cd -- "$mountpoint_arg" 2>/dev/null && pwd)"; then
      printf 'Mountpoint not found: %s\n' "$mountpoint_arg" >&2
      exit 1
    fi

    if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
      printf '%s\n' "Run this command from inside the pd-pki git worktree." >&2
      exit 1
    fi

    bundle_root="$mountpoint/pd-pki-transfer/root-inventory"
    if [ ! -d "$bundle_root" ]; then
      printf 'Root-inventory directory not found under mountpoint: %s\n' "$bundle_root" >&2
      exit 1
    fi

    bundle_dir="$(
      find "$bundle_root" -maxdepth 1 -mindepth 1 -type d -name 'root-*' -printf '%T@ %p\n' |
        sort -nr |
        head -n1 |
        cut -d' ' -f2-
    )"
    if [ -z "$bundle_dir" ]; then
      printf 'No exported root-inventory bundles found under: %s\n' "$bundle_root" >&2
      exit 1
    fi

    bundle_name="$(basename -- "$bundle_dir")"
    root_id="$(printf '%s\n' "$bundle_name" | sed -En 's/^root-([0-9a-f]+)-[0-9]{8}T[0-9]{6}Z$/\1/p')"

    if [ -z "$root_id" ]; then
      printf 'Could not parse root ID from bundle directory name: %s\n' "$bundle_name" >&2
      exit 1
    fi

    inventory_root="$repo_root/inventory/root-ca"
    inventory_dir="$inventory_root/$root_id"
    metadata_path="$inventory_dir/root-ca.metadata.json"
    certificate_path="$inventory_dir/root-ca.cert.pem"
    key_uri_path="$inventory_dir/root-key-uri.txt"

    print_root_certificate_metadata() {
      printf 'Root certificate metadata\n'
      printf '=========================\n'
      printf 'Root ID: %s\n' "$root_id"

      if [ -f "$metadata_path" ]; then
        jq -r '
          [
            "Profile: " + (.profile // "unknown"),
            "Subject: " + (.subject // "unknown"),
            "Issuer: " + (.issuer // "unknown"),
            "Serial: " + (.serial // "unknown"),
            "Not Before: " + (.notBefore // "unknown"),
            "Not After: " + (.notAfter // "unknown"),
            "SHA-256 Fingerprint: " + (.sha256Fingerprint // "unknown")
          ] | .[]
        ' "$metadata_path"
      elif [ -f "$certificate_path" ]; then
        openssl x509 -in "$certificate_path" \
          -noout \
          -subject \
          -issuer \
          -serial \
          -dates \
          -fingerprint -sha256
      else
        printf '%s\n' "No root certificate metadata or certificate file found." >&2
      fi

      if [ -f "$key_uri_path" ]; then
        printf 'Key URI: %s\n' "$(cat "$key_uri_path")"
      fi
    }

    cd "$repo_root"
    pd-pki-signing-tools normalize-root-inventory \
      --source-dir "$bundle_dir" \
      --inventory-root "$inventory_root"

    git add -- "$inventory_dir"

    print_root_certificate_metadata
    if [ "$verbose" = "1" ]; then
      printf '\nVerbose details\n'
      printf '===============\n'
      printf 'Normalized bundle: %s\n' "$bundle_dir"
      printf 'Inventory directory: %s\n' "$inventory_dir"
      printf 'Copied files:\n'
      find "$inventory_dir" -maxdepth 1 -type f | sort
      printf '\nGit status:\n'
      git status --short -- "$inventory_dir"
    fi
  '';
}
