---
name: disk-cleanup
description: Use when cleaning up Windows disk space by analyzing SpaceSniffer exported txt reports (Group by Folder) to determine what can be safely deleted, migrated via junction, or must be kept — and then executing cleanup actions in a loop across multiple reports.
---

# Disk Cleanup via SpaceSniffer Reports

## Overview

Iterative loop: scan with SpaceSniffer → export txt → analyze → act → next report. Each report is a self-contained decision cycle.

## When to Use

- Windows C: drive is full, need to free space systematically
- Have multiple SpaceSniffer `.txt` reports exported (Group by Folder)
- Want data-driven decisions about what's safe to delete vs. migrate

## Core Loop

```
Scan drive (SpaceSniffer)
    ↓
Export txt report (Group by Folder)
    ↓
Read report: identify largest directories
    ↓
Categorize each finding → act
    ↓
Next report or re-scan
```

## Analysis: The Five Categories

For each large directory in a report, classify into one of:

### 1. Safe to Delete

**Characteristics:** Cache files, logs, auto-regenerated data, old versions not in use.

| Pattern | Examples | Action |
|---------|----------|--------|
| `*Cache*`, `*cache*` | `NVIDIA/DXCache`, `jcef_cache`, `GPUCache` | `rm -rf` |
| `*/log/*`, `*/logs/*` | IDE logs, telemetry logs | `rm -rf` |
| Old version dirs (different name from current) | `IdeaIC2025.2` when on `IntelliJIdea2026.1` | `rm -rf` |
| HTTP disk cache | `cache/morgue/*` in Firefox profile | Delete via browser settings (safer) |

**Rule:** If the system/app will auto-regenerate it on next run, it's safe to delete.

### 2. Migrate via Junction

**Characteristics:** App data that must stay at the original path (app hardcodes it), but can live on another drive.

**Pattern:**
```bash
# 1. Copy data to D: drive
cp -a "/c/Users/$USER/AppData/Roaming/AppName" "/d/TargetPath/AppName"

# 2. Verify copy (compare file counts)
find /d/TargetPath/AppName -type f | wc -l

# 3. Remove original
rm -rf "/c/Users/$USER/AppData/Roaming/AppName"

# 4. Create junction (requires admin)
Start-Process cmd -ArgumentList '/c', 'mklink', '/J',
  'C:\Users\...\AppName', 'D:\TargetPath\AppName' -Verb RunAs -Wait

# 5. Verify junction
cmd /c "dir /AL C:\Users\...\AppName"
```

**Always verify:** Junction points to correct target via `fsutil reparsepoint query`.

**Never junction:** Files in active use, system-critical paths, or when backups already exist at target (keep backups intact).

### 3. Requires Caution

**Characteristics:** User data that might contain drafts, active toolchains that are in PATH.

| Scenario | Why Cautious | How to Decide |
|----------|-------------|---------------|
| OPFS storage (`*/fs/*`) | May contain unsaved drafts | Ask user; delete via app settings |
| Toolchain in PATH (MinGW, etc.) | May break builds | Check `echo $PATH`; ask user about usage |
| `IndexedDB` in browser profiles | Web app local data | Delete via browser, not filesystem |

**Rule:** If unsure, always ask before deleting.

### 4. Cannot Delete

**Characteristics:** Currently running software, system components.

- Active processes / locked files
- `System32`, `Windows`, `Program Files` system dirs
- WinGet package for currently running tools (e.g., Claude Code)

### 5. Junction Already Exists

**Symptom:** SpaceSniffer shows C: path with data, but `du` shows 0 or `dir /AL` shows a reparse point.

**Action:** Do nothing — data is already on another drive. SpaceSniffer follows junctions and displays them under C: tree, but physical bytes are on the target drive.

Verify with:
```bash
fsutil reparsepoint query "C:\path\to\dir"
```

## Execution Order

1. Start with the **largest** report item first (biggest win)
2. Delete safe items immediately
3. Migrate eligible items one at a time (copy → verify → junction → confirm)
4. Ask user for cautious items
5. Re-scan after major changes to confirm space freed

## Common Pitfalls

| Mistake | Fix |
|---------|-----|
| SpaceSniffer shows junction data as C: usage | Verify physical location with `fsutil reparsepoint query` |
| Deleting OPFS/IndexedDB via filesystem | Use browser's "Manage Cookies and Site Data" instead |
| Deleting toolchains in PATH | Check `echo $PATH` first |
| `du -sh` returns 0 on Windows | Use `ls -la` or PowerShell `Get-ChildItem` to verify |
| Cross-drive `cmd /c move` loses data | Use `cp -a` via bash or `robocopy` for cross-drive moves |
