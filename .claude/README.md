# `.claude/` — repo-local Claude Code config

## `settings.json` — Bash permission allowlist

`settings.json` holds a `permissions.allow` list of read-only ship-cycle Bash
commands (git status/diff/log/show/branch/rev-parse/remote/fetch, gh pr
view/list/diff/checks, shellcheck, yamllint, `bash -n`). Added in PR #87 to cut
permission prompts during routine review/ship work.

These use Claude Code's command-**prefix** matcher: `Bash(git diff:*)` (the `:*`
suffix is equivalent to a trailing ` *`) matches any command starting with
`git diff `.

### Verified: prefix rules do NOT pre-approve chained mutations (hole closed)

A reasonable fear about prefix allowlists: does `Bash(git diff:*)` also approve a
**compound** command like `git diff && rm -rf /` — i.e. does Claude Code
prefix-match the *whole* command string?

**No.** Claude Code parses shell operators and re-checks **each subcommand
independently** against the allow rules. A compound command is auto-approved only
if *every* subcommand matches an allow rule; otherwise it falls through to a
normal permission prompt. So `git diff && rm -rf /` still prompts on the
`rm -rf /` part — the allowlist does not widen the blast radius beyond the exact
read-only commands listed.

This is enforced by Claude Code itself (not the model), independent of anything
in `CLAUDE.md` or the prompt.

**Evidence** (verified 2026-06-22, against the current published docs):

- Permissions reference — "Compound commands":
  <https://code.claude.com/docs/en/permissions> —
  > "Claude Code is aware of shell operators, so a rule like `Bash(safe-cmd *)`
  > won't give it permission to run the command `safe-cmd && other-cmd`. The
  > recognized command separators are `&&`, `||`, `;`, `|`, `|&`, `&`, and
  > newlines. A rule must match each subcommand independently."
- Security reference — defense-in-depth backing the above:
  <https://code.claude.com/docs/en/security> —
  > "Command injection detection: Suspicious bash commands require manual
  > approval even if previously allowlisted." …
  > "Fail-closed matching: Unmatched commands default to requiring manual
  > approval."

### Residual caveats (not present in the current allowlist, but watch for them)

The per-subcommand guarantee covers `&&`/`||`/`;`/`|`/`&`/newline chaining. Two
documented bypass classes are *not* covered by a simple prefix rule — none apply
to the current read-only ruleset, but don't add rules that introduce them:

- **Environment/exec runners pass through to the inner command.** A rule like
  `Bash(devbox run *)` / `docker exec *` / `npx *` matches *whatever follows*,
  including `devbox run rm -rf .`. (Plain wrappers `timeout`/`time`/`nice`/
  `nohup`/`stdbuf`/bare `xargs` are stripped and are safe.) If you ever allow a
  runner, pin the inner command: `Bash(devbox run npm test)`.
- **Argument-constraining prefix rules are fragile** (option reordering,
  protocol/redirect, `URL=… && curl $URL`). For network egress, prefer
  `deny` on `curl`/`wget` + `WebFetch(domain:…)`, not a `Bash(curl http://… *)`
  allow rule.

Scope of this note: the claim above was verified against the docs cited on
2026-06-22. `settings.json` is strict JSON (it carries a `$schema`) and does not
support comments, which is why this note lives here rather than inline.
