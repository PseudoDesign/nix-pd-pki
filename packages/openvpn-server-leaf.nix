{ pkgs }:

pkgs.runCommand "openvpn-server-leaf" { } ''
  mkdir -p "$out"
''
