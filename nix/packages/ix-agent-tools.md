# Agent CLIs on ix/base

`claude` and `codex` in ix/base start without permission prompts. The VM is the sandbox. These are defaults, not locked policy, so you can turn them off in your own config.

Bypass means the agent runs anything the session user can, with no prompt. On ix/base that user (`ix`) has passwordless `sudo` and can read every secret the VM is granted with `ix-secrets get`. It can also read the sign-in tokens the CLIs store once you sign in, `~/.claude/.credentials.json` for Claude Code and `~/.codex/auth.json` for Codex. A prompt injection in a page or repo the agent reads can use all of it. So grant a VM only the secrets its agent should be able to send anywhere, and don't snapshot, fork or share a VM you signed in on, because the tokens go with it.

## Claude Code

The image presets no Claude credential. Sign in with `/login`, which the footer of a first run points at ("Not logged in · Run /login").

A first run skips Claude Code's setup screens. When a non-root user has no `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`), the wrapper writes one that marks onboarding done, picks the dark theme, and trusts `$HOME`. So `claude` in `$HOME` opens straight into the REPL in about 1.3 s; the theme picker, the security notes and the folder-trust dialog never show. Change the theme with `/theme`. Claude Code never updates itself here, because the image pins its version and sets `DISABLE_AUTOUPDATER=1`.

Trusting `$HOME` also trusts every directory under it that isn't a git repository, so a `.claude/settings.json` in one of those runs its hooks without asking. A git clone still asks for trust once. Claude Code itself never saves trust for `$HOME`; the image does because the VM is the sandbox and bypass mode already lets the agent run anything as you. To get the dialog back, delete your home directory's entry under `projects` in `~/.claude.json`; the wrapper doesn't touch a file that exists. The first session in a new directory may also offer to make auto mode your default; "No, keep bypass permissions" keeps the image's default.

When a non-root user has no `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), the wrapper also copies `/etc/ix/claude-user-settings.json` there first:

```json
{"permissions": {"defaultMode": "bypassPermissions"}, "skipDangerousModePermissionPrompt": true}
```

So `claude` behaves like `claude --dangerously-skip-permissions` and skips the one-time "Bypass Permissions mode" warning. After the copy both files are yours. The wrapper never rewrites them, and it leaves an existing file or symlink alone.

To get permission prompts back, set the mode in `~/.claude/settings.json`:

```json
{"permissions": {"defaultMode": "default"}}
```

Deleting the file doesn't work, because the next `claude` copies the defaults again. For one session, run `claude --permission-mode default`.

Root gets neither file. Claude Code refuses `bypassPermissions` as root ("cannot be used with root/sudo privileges") and exits 1. Its source checks one escape, `IS_SANDBOX=1`, which Anthropic doesn't document. So a one-off `ix shell <vm> --noninteractive -- claude ...`, which runs as root with `HOME=/root`, starts in the normal prompting mode. An interactive `ix shell` is the `ix` user and gets bypass. A root shell that keeps a non-root user's `HOME` (`sudo -E claude`) reads that user's bypass file and exits 1. Run `claude --permission-mode default` there, or use the `ix` user.

## Codex

The image presets no Codex credential either. A first `codex` opens Codex's sign-in screen, where you sign in with ChatGPT or paste an API key.

`/etc/codex/config.toml` sets:

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false

[features]
daemon_auto_start = false
```

The daemon setting keeps plain `codex` working. Since 0.157 Codex starts a background server by default and installs it from a full release package, which the image doesn't ship, so without this line `codex` exits with "this CLI has no complete local package". `codex agents`, `codex queue` and `codex remote-control` need that server and don't work here. The update check is off because the image pins Codex's version.

Codex reads that system file below `~/.codex/config.toml`, so a value in your own file wins. Set `approval_policy = "on-request"` and `sandbox_mode = "workspace-write"` there to get prompts and the sandbox back. For one interactive run, use `codex -a on-request -s workspace-write`. Codex has no root check, so these defaults apply to root sessions too.
