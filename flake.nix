{
  description = "NixOS integration for the pd-pki Python workflow application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/25.11";
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pd-pki-python = {
      url = "github:PseudoDesign/pd-pki-python";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-raspberrypi, pd-pki-python, ... }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      mkPkgs = system: import nixpkgs { inherit system; };

      forAllSystems = f:
        lib.genAttrs supportedSystems (system: f (mkPkgs system));

      nixosModules = import ./modules;

      mkPdPkiPackage =
        pkgs:
        pd-pki-python.packages.${pkgs.stdenv.hostPlatform.system}.pd-pki.overrideAttrs
          (old: {
            postPatch = (old.postPatch or "") + ''
              substituteInPlace src/pd_pki_workflow/api.py \
                --replace-fail "HTTP_422_UNPROCESSABLE_CONTENT" "HTTP_422_UNPROCESSABLE_ENTITY"
              substituteInPlace src/pd_pki_workflow/mock_api.py \
                --replace-fail "HTTP_422_UNPROCESSABLE_CONTENT" "HTTP_422_UNPROCESSABLE_ENTITY"
            '';
          });

      mkSpecialArgs = pkgs: {
        inherit nixos-raspberrypi pd-pki-python;
        pd-pki-package = mkPdPkiPackage pkgs;
      };

      mkApp = package: program: description: {
        type = "app";
        program = "${package}/bin/${program}";
        meta = {
          inherit description;
        };
      };

      mkSdImageInstaller =
        pkgs:
        {
          commandName,
          imagePackageAttr,
          description,
        }:
        pkgs.writeShellApplication {
          name = commandName;
          runtimeInputs = with pkgs; [
            coreutils
            findutils
            nix
            sudo
            util-linux
            zstd
          ];
          text = ''
            set -euo pipefail

            flake_ref="''${PD_PKI_FLAKE_REF:-${self.outPath}}"
            image_attr=${lib.escapeShellArg imagePackageAttr}
            assume_yes=0
            device=""
            image_source=""

            usage() {
              cat <<EOF
            usage: ${commandName} [--image <path>] [--yes] <device>

            Build the ${imagePackageAttr} image and write it to a whole-disk SD card
            device such as /dev/sdb or /dev/mmcblk0.

            options:
              --image <path>  reuse an existing .img or .img.zst instead of building
              --yes           confirm that the target device will be erased
              -h, --help      show this help text
            EOF
            }

            fail() {
              printf '%s\n' "$1" >&2
              exit 1
            }

            as_root() {
              if [ "$(id -u)" -eq 0 ]; then
                "$@"
              else
                sudo "$@"
              fi
            }

            resolve_image_file() {
              local candidate="$1"
              local pattern
              local found

              if [ -f "$candidate" ]; then
                case "$candidate" in
                  *.img|*.img.zst)
                    printf '%s\n' "$candidate"
                    return 0
                    ;;
                esac
              fi

              if [ -d "$candidate" ]; then
                for pattern in '*.img.zst' '*.img'; do
                  found="$(
                    find "$candidate" -maxdepth 5 \( -type f -o -type l \) -name "$pattern" | head -n 1
                  )"
                  if [ -n "$found" ]; then
                    printf '%s\n' "$found"
                    return 0
                  fi
                done
              fi

              return 1
            }

            while [ "$#" -gt 0 ]; do
              case "$1" in
                --image)
                  [ "$#" -ge 2 ] || fail "--image requires a path"
                  image_source="$2"
                  shift 2
                  ;;
                --yes)
                  assume_yes=1
                  shift
                  ;;
                -h|--help)
                  usage
                  exit 0
                  ;;
                --)
                  shift
                  break
                  ;;
                -*)
                  usage >&2
                  fail "unknown option: $1"
                  ;;
                *)
                  if [ -n "$device" ]; then
                    usage >&2
                    fail "expected exactly one target device"
                  fi
                  device="$1"
                  shift
                  ;;
              esac
            done

            if [ "$#" -gt 0 ]; then
              if [ "$#" -ne 1 ] || [ -n "$device" ]; then
                usage >&2
                fail "unexpected arguments: $*"
              fi
              device="$1"
            fi

            [ -n "$device" ] || {
              usage >&2
              exit 2
            }

            [ -b "$device" ] || fail "expected a block device path, got: $device"

            device_type="$(lsblk -ndo TYPE "$device" 2>/dev/null || true)"
            [ "$device_type" = "disk" ] || fail "expected a whole-disk device, got type: ''${device_type:-unknown}"

            if [ -n "$image_source" ]; then
              printf '%s\n' "Using existing image source: $image_source"
            else
              printf '%s\n' "Building ${imagePackageAttr} from $flake_ref"
              image_source="$(nix build --print-out-paths --no-link "$flake_ref#$image_attr")"
            fi

            image_file="$(resolve_image_file "$image_source")" \
              || fail "could not find a .img or .img.zst under: $image_source"
            image_size="$(numfmt --to=iec-i --suffix=B "$(stat -c '%s' "$image_file")")"

            printf '%s\n' "Image:  $image_file ($image_size)"
            printf '%s\n' "Target: $device"

            if [ "$assume_yes" -ne 1 ]; then
              printf '%s\n' "refusing to erase $device without --yes" >&2
              exit 2
            fi

            while IFS= read -r node; do
              [ -n "$node" ] || continue

              while IFS= read -r target; do
                [ -n "$target" ] || continue
                printf '%s\n' "Unmounting $node from $target"
                as_root umount "$node"
              done < <(findmnt -rn -S "$node" -o TARGET || true)
            done < <(lsblk -nrpo NAME "$device")

            printf '%s\n' "Writing image to $device"
            case "$image_file" in
              *.zst)
                zstdcat -- "$image_file" | as_root dd of="$device" bs=4M iflag=fullblock conv=fsync status=progress
                ;;
              *)
                as_root dd if="$image_file" of="$device" bs=4M iflag=fullblock conv=fsync status=progress
                ;;
            esac

            sync
            as_root blockdev --rereadpt "$device" >/dev/null 2>&1 || true
            printf '%s\n' "Finished writing ${imagePackageAttr} to $device"
          '';
          meta = {
            inherit description;
            platforms = lib.platforms.linux;
          };
        };

      mkSystem =
        system: modules:
        let
          pkgs = mkPkgs system;
        in
        lib.nixosSystem {
          inherit system modules;
          specialArgs = mkSpecialArgs pkgs;
        };

      mkRpi5System =
        modules:
        nixos-raspberrypi.lib.nixosSystem {
          inherit nixpkgs;
          trustCaches = false;
          specialArgs = mkSpecialArgs (mkPkgs "aarch64-linux");
          inherit modules;
        };

      rpi5RootYubiKeyProvisioner = mkRpi5System [ ./systems/rpi5-root-yubikey-provisioner.nix ];
      rpi5RootIntermediateSigner = mkRpi5System [ ./systems/rpi5-root-intermediate-signer.nix ];
    in
    {
      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);

      packages = forAllSystems (
        pkgs:
        let
          package = mkPdPkiPackage pkgs;
          provisionerSdcardInstaller = mkSdImageInstaller pkgs {
            commandName = "pd-pki-install-rpi5-root-yubikey-provisioner-sdcard";
            imagePackageAttr = "packages.aarch64-linux.rpi5-root-yubikey-provisioner-sd-image";
            description = "Build and write the Raspberry Pi 5 root YubiKey provisioner image to an SD card.";
          };
        in
        {
          default = package;
          pd-pki = package;
        }
        // lib.optionalAttrs pkgs.stdenv.isLinux {
          install-rpi5-root-yubikey-provisioner-sdcard = provisionerSdcardInstaller;
        }
        // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-linux") {
          rpi5-root-yubikey-provisioner-sd-image =
            rpi5RootYubiKeyProvisioner.config.system.build.sdImage;
          rpi5-root-intermediate-signer-sd-image =
            rpi5RootIntermediateSigner.config.system.build.sdImage;
        }
      );

      apps = forAllSystems (
        pkgs:
        let
          package = mkPdPkiPackage pkgs;
          provisionerSdcardInstaller = mkSdImageInstaller pkgs {
            commandName = "pd-pki-install-rpi5-root-yubikey-provisioner-sdcard";
            imagePackageAttr = "packages.aarch64-linux.rpi5-root-yubikey-provisioner-sd-image";
            description = "Build and write the Raspberry Pi 5 root YubiKey provisioner image to an SD card.";
          };
        in
        {
          default = mkApp package "pd-pki-api" "Run the pd-pki FastAPI service.";
          pd-pki-api = mkApp package "pd-pki-api" "Run the pd-pki FastAPI service.";
          pd-pki-mock-api = mkApp package "pd-pki-mock-api" "Run the pd-pki mock API.";
          pd-pki-workflow = mkApp package "pd-pki-workflow" "Run the pd-pki workflow CLI.";
        }
        // lib.optionalAttrs pkgs.stdenv.isLinux {
          install-rpi5-root-yubikey-provisioner-sdcard = mkApp
            provisionerSdcardInstaller
            "pd-pki-install-rpi5-root-yubikey-provisioner-sdcard"
            "Build and write the Raspberry Pi 5 root YubiKey provisioner image to an SD card.";
        }
      );

      checks = forAllSystems (
        pkgs:
        import ./checks {
          inherit pkgs nixpkgs pd-pki-python;
          pd-pki-package = mkPdPkiPackage pkgs;
          offlineSystems = {
            inherit rpi5RootYubiKeyProvisioner rpi5RootIntermediateSigner;
          };
        }
      );

      inherit nixosModules;

      nixosConfigurations = {
        hardware-lab = mkSystem "x86_64-linux" [ ./systems/hardware-lab.nix ];
        rpi5-root-yubikey-provisioner = rpi5RootYubiKeyProvisioner;
        rpi5-root-intermediate-signer = rpi5RootIntermediateSigner;
      };
    };
}
