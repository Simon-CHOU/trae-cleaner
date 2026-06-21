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
- Want to clean stale build-tool caches (Maven, Gradle, npm, Cargo, pip, etc.) based on 30-day last-access staleness

## Core Loop

```
Optional: scan-caches.ps1 -Report <report.txt>  (cache staleness from SpaceSniffer data)
    ↓
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

## Analysis: The Six Categories

For each large directory in a report, classify into one of:

### 1. Safe to Delete

**Characteristics:** Cache files, logs, auto-regenerated data, old versions not in use.

| Pattern | Examples | Action |
|---------|----------|--------|
| `*Cache*`, `*cache*` | `NVIDIA/DXCache`, `jcef_cache`, `GPUCache` | `rm -rf` |
| `*/log/*`, `*/logs/*` | IDE logs, telemetry logs | `rm -rf` |
| Old version dirs (different name from current) | `IdeaIC2025.2` when on `IntelliJIdea2026.1` | `rm -rf` |
| HTTP disk cache | `cache/morgue/*` in Firefox profile | Delete via browser settings (safer) |
| `C:\Windows\LiveKernelReports\*.dmp` | `WATCHDOG-*.dmp`, kernel crash dumps | Elevated delete (see below) |

**Rule:** If the system/app will auto-regenerate it on next run, it's safe to delete.

**LiveKernelReports (WATCHDOG dumps):**

These are Windows kernel watchdog timeout dumps. They only exist for post-crash analysis. If the system is running normally, they are safe to delete. Requires admin privileges:

```powershell
# 1. Take ownership + grant permission, then delete
takeown /f "C:\Windows\LiveKernelReports\WATCHDOG-*.dmp" /a
icacls "C:\Windows\LiveKernelReports\WATCHDOG-*.dmp" /grant Administrators:F
del /f "C:\Windows\LiveKernelReports\WATCHDOG-*.dmp"

# Or via elevated cmd in one shot:
Start-Process cmd -ArgumentList '/c', 'takeown', '/f',
  'C:\Windows\LiveKernelReports\WATCHDOG-*.dmp', '/a', '&&',
  'icacls', 'C:\Windows\LiveKernelReports\WATCHDOG-*.dmp',
  '/grant', 'Administrators:F', '&&',
  'del', '/f', 'C:\Windows\LiveKernelReports\WATCHDOG-*.dmp' -Verb RunAs -Wait
```

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

### 3. Migrate Docker Desktop WSL Data

Docker Desktop on Windows stores its data in WSL2 virtual disks under `%LOCALAPPDATA%\Docker\wsl`. This can grow large (8GB+) and should be moved to D:.

**First, determine which version structure is in use:**

```powershell
wsl -l -v
```

**Scenario A — Single distro (newer Docker, merged `docker-desktop`):**

If only `docker-desktop` appears (no separate `docker-desktop-data`):

```powershell
# 1. Quit Docker Desktop, then shut down WSL
wsl --shutdown

# 2. Export the distro to D: (takes minutes, no progress bar)
mkdir D:\DockerWSL
wsl --export docker-desktop D:\docker-desktop.tar

# 3. Unregister C: instance (frees C: space immediately)
wsl --unregister docker-desktop

# 4. Import to D:
wsl --import docker-desktop D:\DockerWSL D:\docker-desktop.tar --version 2

# 5. Verify Docker works, then delete the temp tar
rm D:\docker-desktop.tar
```

**Scenario B — Dual distro (older Docker, separate `docker-desktop-data`):**

If both `docker-desktop` and `docker-desktop-data` appear, migrate the `-data` one (it's the large one):

```powershell
wsl --export docker-desktop-data D:\docker-desktop-data.tar
wsl --unregister docker-desktop-data
wsl --import docker-desktop-data D:\DockerWSL D:\docker-desktop-data.tar --version 2
```

**Scenario C — disk/main split (newest Docker with built-in path setting):**

If `C:\Users\...\Docker\wsl` has `disk\docker_data.vhdx` and `main\ext4.vhdx`:

```
C:.\Docker\wsl
├─disk\
│    docker_data.vhdx    ← data (large, can be moved)
└─main\
     ext4.vhdx           ← system engine (small, KEEP on C:)
```

This means Docker already uses the built-in `Settings → Resources → Advanced → Disk image location`. Verify in Docker Desktop GUI where the path points. If already pointing to D:, the C: copy is a stale leftover.

```powershell
# 1. Quit Docker Desktop + wsl --shutdown

# 2. Rename C: copy as safety test (don't delete yet)
ren C:\Users\mrsim\AppData\Local\Docker\wsl\disk\docker_data.vhdx docker_data.vhdx.bak

# 3. Restart Docker — if works normally, delete the .bak
# NEVER delete main\ext4.vhdx — that's Docker's system engine
```

**Verification:** After any scenario, `wsl -l -v` should show the distro as `Running` after Docker restarts, and images/containers should be intact.

### 4. Requires Caution

**Characteristics:** User data that might contain drafts, active toolchains that are in PATH.

| Scenario | Why Cautious | How to Decide |
|----------|-------------|---------------|
| OPFS storage (`*/fs/*`) | May contain unsaved drafts | Ask user; delete via app settings |
| Toolchain in PATH (MinGW, etc.) | May break builds | Check `echo $PATH`; ask user about usage |
| `IndexedDB` in browser profiles | Web app local data | Delete via browser, not filesystem |

**Rule:** If unsure, always ask before deleting.

### 5. Cannot Delete

**Characteristics:** Currently running software, system components.

- Active processes / locked files
- `System32`, `Windows`, `Program Files` system dirs
- WinGet package for currently running tools (e.g., Claude Code)

### 6. Junction Already Exists

**Symptom:** SpaceSniffer shows C: path with data, but `du` shows 0 or `dir /AL` shows a reparse point.

**Action:** Do nothing — data is already on another drive. SpaceSniffer follows junctions and displays them under C: tree, but physical bytes are on the target drive.

Verify with:
```bash
fsutil reparsepoint query "C:\path\to\dir"
```

### 7. Build-Tool Cache Cleanup (30-Day Staleness)

Script: `scan-caches.ps1` — takes a SpaceSniffer "Group by Folder" report as input, cross-references known cache paths, checks filesystem staleness, and optionally moves fully-stale cache directories to the Recycle Bin.

**Design rationale:** SpaceSniffer has already scanned the entire disk. The script parses that report (cheap — in-memory regex) to identify which cache paths exist and their sizes, then does a lightweight staleness check only on those specific directories. No redundant disk scanning.

**Covered caches:**

| Tool | Path |
|------|------|
| Maven repository | `%USERPROFILE%\.m2\repository` |
| Maven wrapper | `%USERPROFILE%\.m2\wrapper` |
| Gradle caches | `%USERPROFILE%\.gradle\caches` |
| npm cache | `%LOCALAPPDATA%\npm-cache` |
| pnpm cache | `%LOCALAPPDATA%\pnpm-cache` |
| Yarn (classic) | `%LOCALAPPDATA%\Yarn` |
| Yarn (berry) | `%USERPROFILE%\.yarn\berry\cache` |
| Cargo registry | `%USERPROFILE%\.cargo\registry` |
| Cargo git | `%USERPROFILE%\.cargo\git` |
| pip cache | `%LOCALAPPDATA%\pip\cache` |
| uv cache | `%LOCALAPPDATA%\uv\cache` |

**Staleness detection:**

For each existing cache directory, the script finds the **newest LastWriteTime** anywhere in the directory tree. If even the newest file is older than 30 days, the entire directory is "fully stale" — it hasn't been touched by any tool in a month and is safe to recycle as a unit. If any file is fresher than 30 days, the cache is "active" and is left alone.

This is simpler and faster than the previous per-file enumeration: one `Get-ChildItem -Recurse` per cache root, keeping only the maximum timestamp.

**Workflow:**

```bash
# Prerequisite: export a SpaceSniffer "Group by Folder" .txt report

# 1. Dry-run: parses report, checks staleness, prints verdict
powershell -File .claude/skills/disk-cleanup/scan-caches.ps1 -Report "report.txt"

# 2. Review the output, then execute
powershell -File .claude/skills/disk-cleanup/scan-caches.ps1 -Report "report.txt" -Execute
```

**What Execute does:**
- Moves fully-stale cache directories to the **Recycle Bin** via `SHFileOperationW` with `FOF_ALLOWUNDO` — not permanent delete.
- Active caches (anything touched in the last 30 days) are never touched.
- Items can be restored from the Recycle Bin if needed.

**Safety:**
- Only touches directories the SpaceSniffer report confirms exist AND the filesystem confirms are fully stale (>30 days since newest file).
- Never touches source code, config files, or toolchain binaries.
- `FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT` suppresses dialogs; errors go to stderr.

## Execution Order

0. **Run build-tool cache scan** — `scan-caches.ps1 -Report <report.txt>` to identify stale Maven/Gradle/npm/Cargo/pip caches, then `-Execute` after review
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
| Deleting `main\ext4.vhdx` to free space | Never delete — it's Docker's system engine, not data |
| Using `wsl --export/--import` on disk/main-split Docker | Check Docker's `Settings → Resources → Advanced → Disk image location` first; if path already points to D:, just rename stale C: copy |
| `wsl --export` seems hung | It's not — large VHDX exports have no progress bar, wait several minutes |
| `rm` fails on LiveKernelReports with "Permission denied" | Use `takeown` + `icacls` via elevated `Start-Process -Verb RunAs` — these are system-protected files |
| `rm` reports WATCHDOG `.dmp` as "Is a directory" | Bash on Windows may misinterpret system dumps; use `cmd /c del /f` instead |
| `scan-caches.ps1` says "access-time tracking: disabled" | Normal on Windows 10+ — the write/create fallback is used; cache staleness detection still works |
| `scan-caches.ps1` reports 0 expired in a large cache | The cache may have been recently populated; check `ThresholdDays` or re-run after 30+ days of inactivity |
