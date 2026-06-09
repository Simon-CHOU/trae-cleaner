---
name: sanitize
description: Use when scanning and redacting sensitive data (absolute paths, tokens, real names) from SpaceSniffer txt reports, log files, or markdown before committing — or when the pre-commit hook blocks a commit with a "SECURITY BLOCK" message.
---

# Sanitize Scan Files

## Overview

Scans uncommitted `.txt`, `.log`, `.md` files in the working tree for sensitive patterns and replaces them with environment-variable placeholders. Preserves SpaceSniffer folder-tree indentation and hierarchy.

## When to Use

- Pre-commit hook blocked a commit: `SECURITY BLOCK: sensitive data in '...'`
- About to commit SpaceSniffer exports and want to scrub absolute paths
- User says "sanitize", "脱敏", or "洗数据"

## Sensitive Pattern Definitions

See `CLAUDE.md` for the project's current allowlist/denylist.

**Default blocked patterns (replace these):**
- Absolute paths with real names: `C:\Users\RealName\` → `%USERPROFILE%\`
- Production tokens, secret keys
- Any pattern added to `SENSITIVE_PATTERNS` in `.git/hooks/pre-commit`

**Allowed (never replaced):**
- `mrsim` — local machine username
- `p6q5aw7q.default-release` — cleared Firefox profile

## Workflow

### Step 1: Identify files to scan

```bash
git diff --name-only          # unstaged changes
git diff --cached --name-only # staged changes
find . \( -name "*.txt" -o -name "*.log" -o -name "*.md" \) -newer .git/index
```

### Step 2: Scan for sensitive patterns

```bash
# Check what would be caught by the current denylist
grep -rnE "<SENSITIVE_PATTERN>" --include="*.txt" --include="*.log" .
```

### Step 3: Replace sensitive patterns

Use `sed` to replace sensitive absolute paths with variable placeholders:

```bash
# Replace a specific sensitive path with environment variable
sed -i 's|C:\\Users\\RealName\\|%USERPROFILE%\\|g' "target_file.txt"

# Verify the replacement preserved structure
git diff "target_file.txt"
```

**Critical rule:** Never break SpaceSniffer indentation. SpaceSniffer uses leading spaces for folder hierarchy — the replacement string must have the same character width or use a placeholder that doesn't shift columns.

### Step 4: Verify and commit

```bash
git diff --stat              # confirm changes look right
git add .
git commit -m "sanitize: redact sensitive paths"
```

## Common Patterns to Redact

| Pattern | Replacement | Example |
|---------|-------------|---------|
| Real-name user path | `%USERPROFILE%` | `C:\Users\ZhangSan\` → `%USERPROFILE%\` |
| Project-specific absolute paths | `%PROJECT_ROOT%` | `D:\secret-project\` → `%PROJECT_ROOT%\` |
| Tokens / keys | `[REDACTED]` | `sk-abc123...` → `[REDACTED]` |
| Email addresses | `user@domain.com` | `zhangsan@company.com` → `user@domain.com` |

## Integration with Pre-Commit Hook

```
git commit
    │
    ├── pre-commit hook scans staged files
    │       │
    │       ├── clean → commit proceeds
    │       │
    │       └── SENSITIVE match found → BLOCKED
    │               │
    │               └── user runs /sanitize
    │                       │
    │                       └── sed replaces patterns
    │                               │
    │                               └── git commit succeeds
```
