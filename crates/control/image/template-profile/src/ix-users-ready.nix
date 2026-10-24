{
  config,
  lib,
  pkgs,
  ...
}: {
  options.ix.usersReady.enable = lib.mkEnableOption "the ix guest users publication protocol";

  config = lib.mkIf config.ix.usersReady.enable {
    assertions = [
      {
        assertion = !config.systemd.sysusers.enable && !config.services.userborn.enable;
        message = "ix-users-ready requires the activation users writer; service-owned user databases need their own publication hook";
      }
    ];

    system = {
      activationScripts = {
        # Dependencies order snippets but do not propagate failures. NixOS resets
        # _localstatus before each snippet, so capture the users result here.
        users.text = lib.mkMerge [
          (lib.mkBefore ''
            # A direct NixOS reactivation can start with a previous publication.
            # Withdraw it before changing users; a failed writer must not leave it valid.
            ${lib.getExe' pkgs.coreutils "rm"} -f /run/ix/users-ready || exit $?
          '')
          (lib.mkAfter ''
            ix_users_status=$_localstatus
          '')
        ];

        ix-users-ready = {
          deps = ["users"];
          text = ''
            (
              set -e
              test "$ix_users_status" -eq 0
              ${lib.getExe' pkgs.coreutils "install"} -d -m 0755 /run/ix
              ix_users_marker=$(${lib.getExe' pkgs.coreutils "mktemp"} /run/ix/users-ready.XXXXXXXXXX)
              trap '${lib.getExe' pkgs.coreutils "rm"} -f -- "$ix_users_marker"' EXIT
              printf 'users ready\n' > "$ix_users_marker"
              ${lib.getExe' pkgs.coreutils "chmod"} 0644 "$ix_users_marker"
              ${lib.getExe' pkgs.coreutils "mv"} -f "$ix_users_marker" /run/ix/users-ready
            )
          '';
        };
      };
    };
  };
}
