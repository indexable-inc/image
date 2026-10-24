# Guest developer tools for ix/base: `ix-secrets`, `claude`, `codex`. Both agent CLIs default to no
# permission prompts; ./ix-agent-tools.md says how a user turns that off.
#
# Neither agent CLI has a preset credential: a user signs in by hand, `/login` in Claude Code and the sign-in
# screen in Codex (Andrew, 2026-10-23, after the `ix-secrets` apiKeyHelper preset failed with "cannot reach the
# host secrets broker"). `ix-secrets` stays for scripts that read a granted secret (docs/design/vm-secret-access.md).
#
# `ixSecrets` is the real guest binary (the static-musl `ix-secrets` from `guestBins`, built from
# crates/vm/guest/secrets-client). There is no stub: an image without the helper must not evaluate.
{
  pkgs,
  ixSecrets,
  lib ? pkgs.lib,
}: let
  # Codex CLI: Apache-2.0, redistributable (upstream-docs:docs-upstream/codex-release/SOURCE.md). A pinned static
  # musl release binary, so the guest needs no node, npx or cache directory. Bump the version and
  # both hashes together from the release's `digest` fields.
  codexVersion = "0.161.0";
  codexTargets = {
    x86_64-linux = {
      triple = "x86_64-unknown-linux-musl";
      sha256 = "b1efb95097660d7f2e5a3887618a23f2ea1b0d548078bf92b0f7a5d229a0cef2";
    };
    aarch64-linux = {
      triple = "aarch64-unknown-linux-musl";
      sha256 = "5c90bf4be3c97fc62fcafb28ec2335ee318e6ecb332e1e8ee3d2c63814a5a26a";
    };
  };
  codexTarget =
    codexTargets.${pkgs.stdenv.hostPlatform.system}
    or (throw "ix-agent-tools: no codex release pinned for ${pkgs.stdenv.hostPlatform.system}");
  codex = pkgs.stdenvNoCC.mkDerivation {
    pname = "codex";
    version = codexVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/openai/codex/releases/download/rust-v${codexVersion}/codex-${codexTarget.triple}.tar.gz";
      inherit (codexTarget) sha256;
    };
    dontUnpack = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      tar -xzf "$src" -C "$out/bin"
      mv "$out/bin/codex-${codexTarget.triple}" "$out/bin/codex"
      chmod +x "$out/bin/codex"
      runHook postInstall
    '';
    nativeBuildInputs = [pkgs.gnutar pkgs.gzip];
    meta = {
      license = lib.licenses.asl20;
      mainProgram = "codex";
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  };

  # Claude Code is under Anthropic's commercial terms. It is preinstalled in the image by Andrew's
  # decision (2026-10-16), so `claude` works offline on first use. It is nixpkgs' `claude-code`
  # (allowed in lib/unfree.nix): the glibc release binary, autoPatchelf'd, wrapped with ripgrep and
  # bubblewrap, and with DISABLE_AUTOUPDATER=1 so it never tries to replace itself in the read-only
  # store. The ix nixpkgs pin lags Anthropic's releases, so `manifest` pins the release here instead.
  # The checksums are `platforms.<platform>.checksum` from
  # `https://downloads.claude.ai/claude-code-releases/<version>/manifest.zst.json` (the zstd files
  # nixpkgs fetches, not the raw binaries in manifest.json). Bump the version and both hashes together.
  claude = pkgs.claude-code.override {
    manifest = {
      version = "2.1.296";
      platforms = {
        linux-x64 = {
          binary = "claude.zst";
          checksum = "fac1d78be9446052ac084878c04c2648abb6b22d53279a685fa19ee517d74410";
        };
        linux-arm64 = {
          binary = "claude.zst";
          checksum = "23aa91437a06eff80a65bfc32b0e4b5a6dda3e821019c543696c154274e56913";
        };
      };
    };
  };

  # The VM is the sandbox, so both CLIs start with no permission prompts (Andrew, 2026-10-23: "by default, if
  # possible, make it dangerously ignore permissions"). These are defaults a user overrides, never managed policy:
  # Claude Code's managed settings outrank the user's file, and Codex's `managed_config.toml` outranks theirs.
  # Overriding either one is in ./ix-agent-tools.md.
  #
  # Claude Code has no system layer below the user's settings (https://code.claude.com/docs/en/settings, fetched
  # 2026-10-23), so `claude` seeds the user's settings.json (`$CLAUDE_CONFIG_DIR`, else `~/.claude`) from this
  # file, also at /etc/ix/claude-user-settings.json, when the user has none. After that the file is theirs.
  # Without `skipDangerousModePermissionPrompt`, 2.1.296 stops at a "Bypass Permissions mode" warning whose
  # default answer is "No, exit". Root gets no settings seed: as root, Claude Code exits 1 on this mode ("cannot be
  # used with root/sudo privileges"), and the escape its source checks (`IS_SANDBOX=1`) is undocumented. Root gets no
  # first-run state either, so the wrapper never writes to root's home; root's sessions are one-off
  # `ix shell --noninteractive` commands, not someone at the REPL.
  claudeUserDefaults = {
    permissions.defaultMode = "bypassPermissions";
    skipDangerousModePermissionPrompt = true;
  };
  claudeUserDefaultsFile = pkgs.writeText "claude-user-settings.json" (builtins.toJSON claudeUserDefaults);
  # A first `claude` otherwise walks a theme picker, security notes and a folder-trust dialog before the REPL
  # (2.1.296 on ix/base, 2026-10-23). Claude Code keeps those answers in its own state file, `~/.claude.json`, or
  # `$CLAUDE_CONFIG_DIR/.claude.json` when that is set. Seeding them sends a first run straight to the REPL, whose
  # footer says "Not logged in · Run /login". Trust is seeded for `$HOME`, the directory a session starts in. That
  # overrides an upstream safeguard on purpose: Claude Code never saves trust for `$HOME` itself, and trust in a
  # directory covers every non-git directory below it, so their `.claude/settings.json` hooks run without a dialog.
  # A git clone still asks once. In bypass mode the agent can already run anything as this user, and the VM is the
  # boundary (2.1.296 keeps the seeded key across its own saves, checked 2026-10-23).
  # `hasCompletedOnboarding` is what skips the theme picker; `dark` is Claude Code's default, so it drops the key on
  # its first save. Auto-update is already off: nixpkgs' wrapper sets DISABLE_AUTOUPDATER=1 (base-image-test pins
  # it). The one first-run download, the official plugin marketplace (15 MB into ~/.claude/plugins), runs in the
  # background and was done 1 s in, so it is not baked into the image: the REPL is ready at 1.3 s either way.
  claudeFirstRunState = {
    hasCompletedOnboarding = true;
    theme = "dark";
  };
  claudeFirstRunStateFile = pkgs.writeText "claude-first-run-state.json" (builtins.toJSON claudeFirstRunState);
  coreutils = "${pkgs.coreutils}/bin";
  # `seed` writes a file whole to a temp file and publishes it with `ln`, which never replaces a file: a failed write
  # leaves no half-written file that would stop every later seed, and a concurrent first launch that loses the race
  # runs with the winner's file. A file or symlink already there, dangling or not, is the user's and is left alone.
  # astlog-ignore: no-write-shell-script-bin -- guest developer tool wrappers; Rust port pending
  claudeSeeded = pkgs.writeShellScriptBin "claude" ''
    set -eu
    absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
    seed() {
      local tmp
      tmp="$(${coreutils}/mktemp "$1.XXXXXX")"
      if ${coreutils}/cat > "$tmp" && { ${coreutils}/ln "$tmp" "$1" || ! absent "$1"; }; then
        ${coreutils}/rm -f "$tmp"
      else
        ${coreutils}/rm -f "$tmp"
        echo "claude: cannot seed $1" >&2
        exit 1
      fi
    }
    if [ "$EUID" -ne 0 ]; then
      home="''${HOME:?is unset, so claude cannot seed its first-run settings}"
      settings="''${CLAUDE_CONFIG_DIR:-$home/.claude}/settings.json"
      state="''${CLAUDE_CONFIG_DIR:-$home}/.claude.json"
      if absent "$settings"; then
        ${coreutils}/mkdir -p "''${settings%/*}"
        seed "$settings" < ${claudeUserDefaultsFile}
      fi
      if absent "$state"; then
        rendered="$(${lib.getExe pkgs.jq} --arg home "$home" '. + {projects: {($home): {hasTrustDialogAccepted: true}}}' \
          ${claudeFirstRunStateFile})"
        printf '%s' "$rendered" | seed "$state"
      fi
    fi
    exec ${claude}/bin/claude "$@"
  '';

  # Codex reads /etc/codex/config.toml below the user's ~/.codex/config.toml (Codex config basics, "Configuration
  # precedence", fetched 2026-10-23), so a user's own value wins.
  #
  # Since 0.157 an interactive `codex` starts a background app-server daemon by default, and the daemon installs only
  # from a "complete package" (`codex-package.json` beside `bin/`, plus bundled rg and bwrap; openai/codex#48050).
  # This binary is not one, so without `daemon_auto_start = false` a bare `codex` exits 1 with "this CLI has no
  # complete local package" unless given `--no-daemon`. The package tarball is 162 MB, and installing it copies
  # ~440 MB into each user's CODEX_HOME, so the image turns the daemon off instead. `codex agents`, `queue` and
  # `remote-control` need the daemon and are unsupported here. The update check is off because the image pins the
  # version and the store copy cannot replace itself.
  codexSystemConfig = ''
    approval_policy = "never"
    sandbox_mode = "danger-full-access"
    check_for_update_on_startup = false

    [features]
    daemon_auto_start = false
  '';

in {
  environment.systemPackages = [ixSecrets codex claudeSeeded];
  environment.etc."ix/claude-user-settings.json".source = claudeUserDefaultsFile;
  environment.etc."codex/config.toml".text = codexSystemConfig;
}
