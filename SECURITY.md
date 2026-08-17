# Security

## Reporting a vulnerability

Open a [private security advisory](https://github.com/rowansail/lanes/security/advisories/new)
on the repository. Please do not open a public issue for anything exploitable.

Expect an acknowledgement within a week. This is a small project maintained in
spare time; if something is urgent, say so in the title.

## The security model, in one line

**Lanes never reads, writes, copies or transmits a credential.**

That is not a slogan, it is the reason the app is built the way it is.

## Why it can avoid credentials entirely

Claude Code derives its macOS Keychain service name from the *path* of its config
directory — `Claude Code-credentials-<first 8 hex of SHA-256 of the path>`. So
pointing `CLAUDE_CONFIG_DIR` at a different folder makes Claude Code look up a
different Keychain item entirely, and log in as a different account.

Switching accounts therefore requires changing one string in one file. The tokens
never need to be touched, moved, backed up or decrypted.

This is worth stating plainly because several other account switchers work by
actively swapping the Keychain entry and `~/.claude.json` between accounts, which
means reading secrets out of the Keychain and writing them back. Lanes does not do
that, and no future version should — if a change requires reading a token, the
design is wrong.

### The one Keychain call, and why it is safe

`Profile.hasCredentials` runs:

```
security find-generic-password -s "Claude Code-credentials-<hash>"
```

Note the absence of `-w`. Without it this asks only whether an item exists and
returns its metadata; it never requests the secret. macOS therefore does not
prompt for Keychain access, and no secret enters the process.

Adding `-w` to that call would change the app's security posture completely. Don't.

### Relevant context on Claude Code itself

Security researchers have reported that the Claude Code CLI stores its credential
in the Keychain in a way that any user-level process can read without
re-authentication, unlike the Claude desktop app. Anthropic has characterised this
as a design decision rather than a vulnerability.

Lanes does not change this either way — but it is the reason the project treats
"never read the token" as a hard rule rather than a nice-to-have. A tool that
routinely read credentials would be a convenient target.

## What Lanes *does* touch

Everything below is in your home directory. There is no network access, no
telemetry, and no analytics — the app makes no outbound connections at all.

| Path | Access | Why |
|---|---|---|
| `~/.config/lanes/` | read/write, `0700` | state file, generated shell hook |
| `~/.zshenv`, `~/.bash_profile`, `~/.config/fish/config.fish` | one marker block | so new shells export `CLAUDE_CONFIG_DIR` |
| `~/.claude` | symlink repoint | compatibility with tools that only `readlink` |
| `~/.claude-*/` | read | profile discovery, account email from `.claude.json` |
| `~/.claude-*/desktop/` | read/write | Electron data dir per profile |
| Keychain | existence check only | see above |

### Editing your shell config

This is the riskiest thing the app does, so it is deliberately constrained:

- Everything it writes sits between `# >>> lanes >>>` and `# <<< lanes <<<`
  markers. Nothing outside those markers is ever modified.
- The block only *sources* a file the app owns. It is written once and does not
  need rewriting on upgrade.
- Writes are atomic (write to a temp file, then `rename()`), so an interrupted
  write cannot leave a half-written shell config that breaks your terminal.
- The existing file mode is preserved rather than forced to `0600` — silently
  tightening permissions on a file you own is a surprise, not a security win.
- A backup is taken before the first modification.

## Scope

In scope: anything that causes Lanes to read a credential, write outside the paths
above, corrupt a shell config, or activate a profile other than the one requested.

Out of scope: vulnerabilities in Claude Code or the Claude desktop app themselves
— report those to Anthropic. Also out of scope: the fact that already-running
shells keep their old `CLAUDE_CONFIG_DIR`. That is how process environments work,
it is documented, and it is not a bug Lanes can fix.

## A standing caveat

`CLAUDE_CONFIG_DIR` and the Keychain naming scheme are **undocumented** and were
determined by observing Claude Code's behaviour. Anthropic can change either
without notice, and a change would break profile isolation.

Lanes reports the detected Claude Code version in its diagnostics for exactly this
reason. If isolation appears to stop working after a Claude Code update, that is
the first thing to check, and a report with the version number attached is the
most useful thing you can send.
