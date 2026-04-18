{
  pkgs,
  pd-pki-package,
}:
pkgs.runCommand "pd-pki-package-gui-lock-config" { } ''
  gui_path="$(
    find ${pd-pki-package} -path '*/site-packages/pd_pki_workflow/gui.py' -print -quit
  )"

  test -n "$gui_path"
  grep -F 'if (configLocked) {' "$gui_path"
  grep -F 'profileDir: lockedWorkflowConfig.profileDir || ""' "$gui_path"

  touch "$out"
''
