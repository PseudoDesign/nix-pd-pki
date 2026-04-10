{ pkgs }:

pkgs.runCommand "root-certificate-authority" { } ''
  mkdir -p "$out"
''
