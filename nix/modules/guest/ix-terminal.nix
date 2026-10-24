# First-login terminal experience of the ix/base image: zsh + starship (the shared
# ix.interactiveShell policy), a developer toolbox on PATH, truecolor defaults, btop following the terminal's light or dark background (./btop.conf) and a
# non-root `ix` user with passwordless sudo. The banner a client sees on connect (name, size,
# the tools below) is drawn by the `ix` CLI from the VM record, not by this image.
#
# Layered by blockvol-base-artifact.nix `guestToplevelFor` next to ix-agent-tools.nix, so
# only the base image carries it; vanilla NixOS templates keep their own shell policy.
#
# Session user: the console agent drops default `ix shell` / `ix new` sessions to the user named
# in /etc/ix/session-user (written below; crates/vm/guest/console/agent/src/session_user.rs),
# starts a zsh login shell as it (so set-environment and PATH with /run/wrappers/bin for sudo
# load) and exports HOME, USER, LOGNAME and SHELL from passwd. Without the file the session
# stays root, so other images are unchanged. `ix exec` and explicit commands still run as root.
{
  config,
  lib,
  pkgs,
  ...
}: let
  zsh = config.programs.zsh.package;
  # What `ix-nix-eval-warm` evaluates into the template's eval cache.
  evalWarmAttrs = ["hello" "firefox" "gcc" "rustc" "cargo" "python3" "nodejs" "git"];
  # The completion dump /etc/zshrc's `compinit` writes on a user's first shell, built once here
  # from the fpath a fresh VM has. Without it the first login shell of every new VM opens all ~2100
  # completion files to regenerate the dump. When capture evicted its page cache, each open was
  # a cold disk read: 815-850 ms before the prompt (prod, 2026-10-16;
  # 340 ms with the dump seeded, 40 ms warm). compinit checks the dump's `#files` count and zsh
  # version against the live fpath, so a user who adds completions later regenerates it as before.
  #
  # The fpath comes from the image's own /etc/zshenv (the NIX_PROFILES loop), not a copy of it, so
  # a nixpkgs change to that loop moves the dump with it; only /run/current-system/sw, which does
  # not exist at build time, is mapped to the system path it will point at. Home profiles are empty
  # on a fresh VM, as they are here.
  zcompdumpScript = pkgs.writeText "ix-zcompdump.zsh" ''
    . ${config.environment.etc.zshenv.source}
    fpath=(''${fpath//\/run\/current-system\/sw/${config.system.path}})
    # set-environment points PATH at /run/current-system/sw; compinit's dump writer needs `mv`.
    path=(${pkgs.coreutils}/bin $path)
    autoload -U compinit
    compinit -u -d "$1"
    read -r _ files _ < "$1"
    if (( files < 1000 )); then
      print -u2 "ix-zcompdump: only $files completion files on the image fpath: $fpath"
      exit 1
    fi
  '';
  zcompdump = pkgs.runCommand "ix-zcompdump" {} ''
    HOME=$TMPDIR ${lib.getExe zsh} -f ${zcompdumpScript} $TMPDIR/zcompdump
    cp $TMPDIR/zcompdump $out
  '';
  # btop's defaults for the session users (./btop.conf), run through the packaged btop first: a fork bump
  # that renames an option or drops a theme fails the image build instead of shipping btop's Default theme.
  btopConf = pkgs.runCommand "ix-btop-conf" {nativeBuildInputs = [pkgs.python3];} ''
    python3 ${./btop_conf_check.py} ${lib.getExe pkgs.btop} ${./btop.conf}
    cp ${./btop.conf} $out
  '';
  # The prompt file the nixpkgs starship module exports as STARSHIP_CONFIG: the same generator over the same settings.
  starshipConfig = (pkgs.formats.toml {}).generate "starship.toml" config.programs.starship.settings;
  # Built with the image (system.checks): the packaged starship renders that file outside SSH and must put the
  # machine's hostname right before the directory. The hostname is the build sandbox's, so a config that hardcoded
  # one would fail too.
  starshipPromptCheck = pkgs.runCommand "ix-starship-prompt-check" {nativeBuildInputs = [pkgs.python3];} ''
    python3 ${./starship_prompt_check.py} ${lib.getExe config.programs.starship.package} ${starshipConfig}
    touch $out
  '';
in {
  config = {
    ix.interactiveShell.enable = true;

    programs = {
      zsh = {
        autosuggestions.enable = true;
        syntaxHighlighting.enable = true;
        histSize = 50000;
        setOptions = [
          # Same as Andrew's local zsh (home-manager): no EXTENDED_HISTORY, no AUTO_CD.
          "HIST_FCNTL_LOCK"
          "HIST_IGNORE_DUPS"
          "HIST_IGNORE_SPACE"
          "SHARE_HISTORY"
          "NO_APPEND_HISTORY"
          "NO_EXTENDED_HISTORY"
          "NO_HIST_EXPIRE_DUPS_FIRST"
          "NO_HIST_FIND_NO_DUPS"
          "NO_HIST_IGNORE_ALL_DUPS"
          "NO_HIST_SAVE_NO_DUPS"
        ];
        # Menu completion with a case-insensitive match, on top of the stock compinit.
        interactiveShellInit = ''
          zstyle ':completion:*' menu select
          zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
          bindkey '^[[A' history-beginning-search-backward
          bindkey '^[[B' history-beginning-search-forward

          # A default shell parked in the golden template (vm-guest-daemon prespawn_shell.rs,
          # IX_MOTD_DEFERRED, a name kept from when this image printed an MOTD) ran this rc under the template's hostname, and every clone resumes the
          # same process, so $HOST and the $RANDOM sequence would be the template's in all of them.
          # Before each command (preexec, so the first command already sees it) and each prompt, a
          # hostname that moved refreshes $HOST, and the first one reseeds $RANDOM. $(<file) reads
          # without a fork.
          if [[ -n ''${IX_MOTD_DEFERRED:-} ]]; then
            _ix_refresh_identity() {
              # The $RANDOM sequence is the template's in every clone, whatever its hostname:
              # reseeded once, at this shell's first command or prompt.
              if [[ -z ''${_ix_reseeded:-} ]]; then
                _ix_reseeded=1
                zmodload -s zsh/random 2>/dev/null && RANDOM=$SRANDOM
              fi
              local name
              name=$(</proc/sys/kernel/hostname) 2>/dev/null || return 0
              [[ $name == "$HOST" ]] && return 0
              HOST=$name
              [[ -n ''${HOSTNAME:-} ]] && HOSTNAME=$name
            }
            autoload -Uz add-zsh-hook
            add-zsh-hook preexec _ix_refresh_identity
            add-zsh-hook precmd _ix_refresh_identity
          fi
        '';
      };

      git.enable = true;
      tmux = {
        enable = true;
        terminal = "tmux-256color";
        # Truecolor passthrough for every outer terminal, so colours survive Ctrl-A sessions.
        extraConfig = ''
          set -ga terminal-overrides ",*:Tc"
          set -g mouse on
          set -g history-limit 50000
        '';
      };
      direnv = {
        enable = true;
        nix-direnv.enable = true;
        silent = true;
      };
    };

    environment = {
      systemPackages = with pkgs; [
        gh
        ripgrep
        fd
        eza
        bat
        jq
        htop
        btop
        curl
        # Unwrapped on purpose: pkgs.wrapNeovim (what programs.neovim uses) pulls python, ruby and
        # wl-clipboard closures (hundreds of MiB) even with every provider switched off.
        neovim-unwrapped
      ];

      shellAliases = {
        ls = "eza";
        ll = "eza -l --git";
        la = "eza -la --git";
        tree = "eza --tree";
        vi = "nvim";
        vim = "nvim";
      };

      variables = {
        BAT_THEME = "ansi";
        EDITOR = "nvim";
      };

      # The CLI forwards the client's TERM but not COLORTERM, so a Ctrl-A session lost 24-bit colour
      # even on a terminal that has it. Every TERM below belongs to a terminal that does truecolor.
      # Existing COLORTERM wins; unknown terminals (linux, vt100) are left alone.
      interactiveShellInit = ''
        if [ -z "''${COLORTERM:-}" ]; then
          case "''${TERM:-}" in
            xterm-256color|xterm-direct|xterm-kitty|xterm-ghostty|ghostty|alacritty|wezterm|foot|tmux-256color|screen-256color)
              export COLORTERM=truecolor ;;
          esac
        fi
      '';

      # Terminfo for the terminals people connect from (kitty, ghostty, alacritty, wezterm, foot, ...),
      # so TERM from the client resolves instead of falling back to "dumb".
      enableAllTerminfo = true;
    };

    # A user with no zsh startup file gets the blocking zsh-newuser-install menu on first login
    # (found in the aarch64 boot check, 2026-10-09). An empty ~/.zshrc ends it; the system rc in
    # /etc/zshrc does the real work.
    #
    # Each session user also starts with the prebuilt completion dump (`zcompdump` above), copied
    # only when absent (`C`), owned by the user so compinit can rewrite it when the fpath grows. The
    # rules run in the template's boot, so the copies are on the disk every golden restore forks.
    systemd.tmpfiles.rules = [
      "f /root/.zshrc 0644 root root - # ix: silences zsh-newuser-install"
      "f /home/ix/.zshrc 0644 ix users - # ix: silences zsh-newuser-install"
      "C /root/.zcompdump - - - - ${zcompdump}"
      "z /root/.zcompdump 0644 root root -"
      "C /home/ix/.zcompdump - - - - ${zcompdump}"
      "z /home/ix/.zcompdump 0644 ix users -"
    ]
    # btop reads only $XDG_CONFIG_HOME/btop/btop.conf, with no system-wide file, so each session user starts
    # with a copy of `btopConf`, made only when absent (`C`): a btop.conf the user already has is never touched.
    ++ lib.concatMap ({
      home,
      owner,
    }: [
      "d ${home}/.config 0755 ${owner} -"
      "d ${home}/.config/btop 0755 ${owner} -"
      "C ${home}/.config/btop/btop.conf - - - - ${btopConf}"
      "z ${home}/.config/btop/btop.conf 0644 ${owner} -"
    ]) [
      {
        home = "/root";
        owner = "root root";
      }
      {
        home = "/home/ix";
        owner = "ix users";
      }
    ];

    # The prompt is Andrew's own starship config (./starship.toml): the VM's name and the path, then
    # a green/red ❯, no right prompt, Nerd Font symbols. mkForce replaces the shared
    # ix.interactiveShell prompt (ASCII glyphs, `#` header, right-aligned cwd) for this image only.
    programs.starship.settings = lib.mkForce (builtins.fromTOML (builtins.readFile ./starship.toml));
    system.checks = [starshipPromptCheck];
    # nixpkgs merges presets into STARSHIP_CONFIG; `starshipConfig` renders `settings` alone, so it is the
    # shipped file only while there are none.
    assertions = [
      {
        assertion = config.programs.starship.presets == [];
        message = "ix-terminal.nix: starship presets are set, so starship_prompt_check.py no longer renders the shipped prompt";
      }
    ];

    # Non-root default session user (see header).
    environment.etc."ix/session-user".text = "ix\n";

    # Start that user's default shell at the end of every restore's Configure, so the first
    # `ix new` attach resumes a shell whose prompt is already drawn (vm-guest-daemon
    # prespawn_shell.rs). Costs each VM one idle zsh and one shell start.
    environment.etc."ix/prespawn-shell".text = "";

    # The node agent runs this before the golden snapshot's final flush
    # (node-agent golden/standalone.rs PRE_CAPTURE_WARM_HOOK): the session user's first
    # interactive login shell, prompt included, the way the console agent starts it. What it reads
    # is then in the captured RAM, so a restored VM's first `ix new` shell faults those pages from
    # the host's donor instead of reading its forked disk cold (815-850 ms cold on prod, 40 ms warm,
    # 2026-10-16). The environment is the console agent's: HOME, USER, LOGNAME and SHELL from passwd.
    environment.etc."ix/pre-capture-warm" = {
      mode = "0755";
      text = ''
        #!${pkgs.runtimeShell}
        set -eu
        # A restored clone's Configure forks `systemctl` once, to raise ix-restored.target; read cold
        # off the forked disk when capture evicted its page cache, that fork cost 40-50 ms of
        # every warm create (2026-10-16). One query here puts systemctl, its shared
        # library and systemd's answering pages back in the captured RAM.
        # Bounded too: systemctl's D-Bus call to a busy PID 1 can wait its 25 s default.
        ${lib.getExe' pkgs.coreutils "timeout"} -k 1 3 ${lib.getExe' config.systemd.package "systemctl"} show --property=Id ix-restored.target >/dev/null 2>&1 || true
        # Bounded here, under the node agent's 50 s wait (node-agent golden/standalone.rs PRE_CAPTURE_WARM_BUDGET, checked
        # against this hook's three bounds: (3 + 1) + (8 + 2) + (20 + 2) s), so a hang ends as a failure (exit 124)
        # instead of a process the capture would freeze into every restore. `-k 2` follows the
        # SIGTERM with a SIGKILL, so a child that ignores SIGTERM cannot outlive the bound.
        # Keep the nixpkgs files an evaluation reads in the captured page cache: a fresh VM's
        # first `nix eval nixpkgs#firefox` took 9.8 s cold against 1.75 s
        # warm (2026-10-16). Reads only (ix-nix-eval-warm below does the writing; the
        # capture's last flush puts what the hook writes in the disk cut, clean in the RAM image).
        # Best effort and bounded on its own, so the
        # shell warm-up below keeps its budget.
        ${lib.getExe' pkgs.coreutils "timeout"} -k 2 8 ${lib.getExe config.nix.package} \
          --extra-experimental-features 'nix-command flakes' eval --raw nixpkgs#hello.outPath \
          </dev/null >/dev/null 2>&1 || true
        exec ${lib.getExe' pkgs.coreutils "timeout"} -k 2 20 ${lib.getExe' pkgs.util-linux "runuser"} -u ix -- ${lib.getExe' pkgs.coreutils "env"} -i \
          HOME=/home/ix USER=ix LOGNAME=ix SHELL=${lib.getExe config.programs.zsh.package} TERM=xterm-256color \
          ${lib.getExe config.programs.zsh.package} -lic '${lib.getExe config.programs.starship.package} prompt >/dev/null' \
          </dev/null >/dev/null
      '';
    };
    # The eval cache (~/.cache/nix/eval-cache-v*) for the packages people reach for first, filled
    # before the golden capture and copied to the session user, so a fresh VM's first
    # `nix shell` / `nix build` / `nix path-info` on them answers from it (1.8 s -> 35 ms for
    # firefox) instead of evaluating nixpkgs. `nix path-info --derivation` is an installable
    # command, so it writes the cache (`nix eval` writes none). Ordered before ix-golden.target so
    # the capture holds what it wrote. Every boot: a condition on the capture-mode marker raced
    # the capture-time Configure that creates it and skipped the unit (2026-10-17); a
    # restore never re-runs it, and a cold boot that does gets the same warm cache.
    ix.golden.captureAfter = ["multi-user.target" "ix-nix-eval-warm.service"];
    systemd.services.ix-nix-eval-warm = {
      description = "Fill the nix eval cache for common packages";
      # Pulled in by ix-golden.target (captureAfter above), not by multi-user.target.
      # No network: the `nixpkgs` pin resolves from the fetcher cache ix-nix-fetcher-seed fills
      # (lib/os/image.nix).
      after = ["nix-daemon.socket" "ix-nix-fetcher-seed.service"];
      wants = ["nix-daemon.socket" "ix-nix-fetcher-seed.service"];
      # Best effort: it can never fail the unit, so it can never degrade the system state the
      # capture checks. A failed or timed-out warm-up refused every golden capture of the toolchain
      # image (prod, 2026-10-17 17:45-18:35Z: "failed units are [ix-nix-eval-warm.service]",
      # ix/base:latest flipped cold, ~100 s creates). systemd never times it out
      # (`TimeoutStartSec = infinity`); the script bounds itself with `timeout` and exits 0.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "infinity";
      };
      environment.HOME = "/root";
      path = [config.nix.package pkgs.coreutils];
      # `fsync-store-paths` (as root, so the store setting applies): each of the ~4300 .drv files
      # the evaluation writes is on disk before the next. All of them dirty at the capture's flush
      # had XFS start a worker per blocked completion, and the ~360 idle `xfs-conv` workers that
      # left were frozen into every restore (1229 kernel threads against 840, 100 vCPUs,
      # 2026-10-16); with it +6, for 1.3 s more.
      # 90 s for the evaluation (SIGKILL 5 s after the SIGTERM), then the copy; any failure only
      # leaves the cache colder. `set +e`: NixOS scripts run under `set -e`, and a failed `cp`
      # (no /home/ix/.cache/nix yet) used to fail the unit.
      script = ''
        set +e
        timeout -k 5 90 nix --extra-experimental-features 'nix-command flakes' --option fsync-store-paths true \
          path-info --derivation \
          ${lib.concatMapStringsSep " " (attr: "nixpkgs#${attr}") evalWarmAttrs} >/dev/null \
          || echo "ix-nix-eval-warm: evaluation did not finish (status $?); the eval cache stays partial"
        # Owned by ix from the start: a root-owned ~/.cache left by a failed copy would break the
        # user's nix (its SQLite caches live there), which is worse than a cold eval cache.
        install -d -o ix -g users -m 0755 /home/ix/.cache /home/ix/.cache/nix
        for cache in /root/.cache/nix/eval-cache-v*; do
          [ -e "$cache" ] || continue
          cp -a "$cache" /home/ix/.cache/nix/ && chown -R ix:users "/home/ix/.cache/nix/''${cache##*/}" \
            || echo "ix-nix-eval-warm: could not copy $cache to the session user"
        done
        exit 0
      '';
    };
    users.users.ix = {
      isNormalUser = true;
      uid = 1000;
      description = "ix";
      extraGroups = ["wheel" "kvm"];
      shell = pkgs.zsh;
    };
    security.sudo = {
      enable = true;
      wheelNeedsPassword = false;
    };
  };
}
