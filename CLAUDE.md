# CLAUDE.md

## Privacy & Sanitization

### Sensitive-Pattern Definitions
- **Blocked:** absolute paths containing real names, production tokens, secret keys.
- **Allowed (non-sensitive):** `mrsim`, `p6q5aw7q.default-release` — local machine username and cleared Firefox profile.

### Sanitization Skill
When the user runs `/sanitize` or asks to "sanitize scan files", execute:

1. Scan the working tree for uncommitted `.txt`, `.log`, `.md` files.
2. Replace sensitive absolute paths with environment-variable placeholders (e.g. `C:\Users\RealName\` → `%USERPROFILE%\`).
3. Preserve SpaceSniffer indentation and folder hierarchy — never break the tree structure.
4. After sanitization, prompt the user that it is safe to `git commit`.

### Pre-Commit Hook
A `.git/hooks/pre-commit` hook gates every commit. It scans staged `.txt` / `.log` / `.md` files against the `SENSITIVE_PATTERNS` denylist. If a match is found the commit is blocked until the user runs sanitization.

### Cleanup Workflow
See `.claude/skills/disk-cleanup/SKILL.md` for the full disk-space analysis and cleanup loop.
