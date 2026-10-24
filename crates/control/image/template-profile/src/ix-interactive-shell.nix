# Shared interactive policy for base images and vanilla NixOS templates.
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.ix.interactiveShell.enable = lib.mkEnableOption "the ix interactive shell defaults";

  config = lib.mkIf config.ix.interactiveShell.enable {
    # Plain assignment (priority 100), not mkDefault: nixpkgs' bash module already
    # defines this option with mkDefault (priority 1000), and two mkDefault values
    # conflict. Disabling ix.interactiveShell removes this definition; an explicit
    # mkOverride below 100 still wins.
    users.defaultUserShell = pkgs.zsh;
    programs = {
      zsh = {
        enable = lib.mkDefault true;
        enableCompletion = lib.mkDefault true;
        # Keep the NixOS history size and file; the system rc also sets them
        # for users whose Home Manager activation has not run.
        interactiveShellInit = "bindkey -e";
      };
      starship = {
        enable = lib.mkDefault true;
        interactiveOnly = true;
        # ASCII glyphs work in the browser console without a patched font.
        settings = lib.mapAttrsRecursive (_: lib.mkDefault) {
          # Timeouts, not defaults (2000/500 ms): the prompt renders on a
          # guest disk that can be faulting chunks in from CAS, and a prompt
          # that stalls on a slow `git status` is worse than one that omits
          # the branch for one redraw.
          scan_timeout = 30;
          command_timeout = 500;
          add_newline = false;
          format = lib.concatStrings [
            "$directory"
            "$git_branch"
            "$git_status"
            "$nix_shell"
            "$cmd_duration"
            "$line_break"
            "$character"
          ];
          # Default ix sessions run as root. Keep the existing # prompt;
          # templates with a different user can override the character.
          directory = {
            style = "bold cyan";
            truncation_length = 4;
            truncation_symbol = ".../";
          };
          git_branch = {
            symbol = "";
            format = "[git:$branch]($style) ";
            style = "bold magenta";
          };
          git_status = {
            format = "([$all_status$ahead_behind]($style) )";
            style = "bold yellow";
          };
          nix_shell = {
            symbol = "";
            format = "[nix:$state]($style) ";
            style = "bold blue";
          };
          # Preserve the base image's 2-second command annotation threshold.
          cmd_duration = {
            min_time = 2000;
            format = "[took $duration]($style) ";
            style = "yellow";
          };
          character = {
            success_symbol = "[#](bold green)";
            error_symbol = "[#](bold red)";
            vimcmd_symbol = "[#](bold blue)";
          };
        };
      };
    };
  };
}
