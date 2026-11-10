# Agent CLIs on ix/base

`claude` and `codex` on ix/base start without permission prompts because the VM is the sandbox. These are defaults you can turn off.

Bypass means the agent can do anything the session user can. On ix/base that user (`ix`) has passwordless `sudo`, can read every secret granted to the VM with `ix-secrets get`, and can read the CLIs' stored sign-in tokens (`~/.claude/.credentials.json`, `~/.codex/auth.json`). A prompt injection can use all of it. Grant a VM only secrets its agent may send anywhere, and don't snapshot, fork or share a VM you signed in on, because the tokens go with it.

## Claude Code

No credential is preset; sign in with `/login`.

When a non-root user has no `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`), the wrapper writes one that marks onboarding done, picks the dark theme and trusts `$HOME`, so `claude` opens straight into the REPL. Trusting `$HOME` trusts every non-git directory under it, so a `.claude/settings.json` there runs its hooks without asking; a git clone still asks once. To get the trust dialog back, delete your home directory's entry under `projects` in `~/.claude.json`. The image pins the version and sets `DISABLE_AUTOUPDATER=1`.

When a non-root user has no `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), the wrapper copies `/etc/ix/claude-user-settings.json` there:

```json
{
  "permissions": {"defaultMode": "bypassPermissions"},
  "skipDangerousModePermissionPrompt": true,
  "tui": "fullscreen",
  "env": {"CLAUDE_CODE_NATIVE_CURSOR": "1"}
}
```

`CLAUDE_CODE_NATIVE_CURSOR` shows your terminal's own cursor; without it Claude Code paints a block unless a per-account feature flag says otherwise, and a fresh VM has fetched no flags. `/tui default` switches back to the classic renderer. The wrapper never rewrites either file once it exists.

To get prompts back, set this in `~/.claude/settings.json` (deleting the file does not work, the next run copies it again):

```json
{"permissions": {"defaultMode": "default"}}
```

For one session, run `claude --permission-mode default`.

Root gets neither file. Claude Code exits 1 on `bypassPermissions` as root ("cannot be used with root/sudo privileges"). So `ix shell <vm> --noninteractive -- claude ...`, which runs as root with `HOME=/root`, starts in prompting mode, while an interactive `ix shell` is the `ix` user and gets bypass. `sudo -E claude` reads the user's bypass file as root and exits 1; use `--permission-mode default` or the `ix` user.

## Codex

No credential is preset; a first `codex` opens the sign-in screen.

`/etc/codex/config.toml` sets:

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false

[features]
daemon_auto_start = false
```

Since 0.157 Codex starts a background server installed from a full release package the image does not ship. Without `daemon_auto_start = false`, `codex` exits with "this CLI has no complete local package". `codex agents`, `codex queue` and `codex remote-control` need that server and do not work here.

Your `~/.codex/config.toml` overrides the system file. Set `approval_policy = "on-request"` and `sandbox_mode = "workspace-write"` there for prompts and the sandbox, or run `codex -a on-request -s workspace-write` once. Codex has no root check, so these defaults apply to root too.
