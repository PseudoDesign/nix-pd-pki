{ pkgs }:

pkgs.runCommand "intermediate-signing-authority" { } ''
  mkdir -p "$out"
''
