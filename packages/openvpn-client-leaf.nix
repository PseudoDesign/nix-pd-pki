{ pkgs }:

pkgs.runCommand "openvpn-client-leaf" { } ''
  mkdir -p "$out"
''
