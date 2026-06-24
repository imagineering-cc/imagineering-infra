# `.claude/` — project Claude Code config

## `settings.json` — the read-only command allowlist

`settings.json` pre-approves a set of **read-only** commands (shellcheck, `bash -n`,
yamllint, `git status/fetch/log/diff/show/branch/rev-parse/remote`, `gh pr
view/list/diff/checks`) so a ship/CI cycle in this repo isn't blocked waiting on
interactive permission prompts. It was added in PR #87 after a classifier outage
made every prompt a hard stop. `settings.json` is JSON and can't carry comments,
which is why this note lives here.

### How `Bash(cmd:*)` matching actually works (verified 2026-06-24)

`Bash(git diff:*)` is a **command-prefix** match. The obvious worry is a
*compound-command escape*: does `Bash(git diff:*)` also pre-approve
`git diff && rm -rf /`? **No.**

Claude Code is **compound-command aware**: it splits a command on the shell
operators `&&`, `||`, `;`, `|`, `|&`, `&`, and newlines, and matches **each
sub-command independently** against the allow rules. So `git diff && rm -rf /`
still prompts on the `rm` part — the prefix rule only ever satisfies the `git diff`
sub-command. (Source: Claude Code permissions docs, "Compound commands". When you
approve a compound command with "don't ask again", it saves a *separate* rule per
sub-command, not one rule for the whole string.)

### Caveats worth knowing

- **Process wrappers are stripped** before matching: `timeout`, `time`, `nice`,
  `nohup`, `stdbuf`, and bare `xargs`. So `Bash(yamllint:*)` also matches
  `timeout 30 yamllint …`. Fine here — these are read-only commands.
- **Environment/exec runners are NOT stripped** and always prompt: `npx`,
  `docker exec`, `direnv exec`, `mise exec`, `watch`, `setsid`, `find -exec`,
  `find -delete`. A prefix rule can't silently cover a command hidden behind one.
- **Prefix rules are convenience, not a security boundary.** Argument-constraining
  allow patterns (e.g. trying to pin a URL on `curl`) are fragile and bypassable;
  the docs recommend **deny** rules for anything security-critical, not clever allow
  patterns. This allowlist is safe because every entry is intrinsically read-only,
  not because the matcher is airtight.
- For an **exact** match (no trailing args), use `Bash(cmd)` with no `:*`.

> Bottom line: the compound-command-escape hole does not exist (sub-commands are
> re-checked), and this allowlist's low blast radius comes from the commands being
> read-only — keep it that way. Anything that mutates state should stay out of the
> allow list (let it prompt) or, if it must be constrained, go in a deny rule.
