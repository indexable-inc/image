# Required guest activation and optional shell policy share one import boundary.
# Publication must remain enabled even when a template disables shell defaults.
{
  imports = [./ix-interactive-shell.nix ./ix-users-ready.nix];
}
