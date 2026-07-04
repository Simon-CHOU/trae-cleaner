# SOP: D: 盘清理实战记录 (2026-07-03)

## 概况

- **总空间:** 256.7 GB
- **本次释放:** ~6.95 GB
- **工具:** SpaceSniffer 导出 txt 报告 → 人工分析 → 逐项确认执行

---

## 步骤记录

### Step 1: 分析 SpaceSniffer 报告

读取 txt 报告，识别 Top 空间占用：

| 项目 | 大小 | 判定 |
|------|------|------|
| WSL Ubuntu ext4.vhdx | 70.7 GB | 需谨慎处理 |
| Docker docker_data.vhdx (疑似重复 ×2) | 25.6 + 3.7 GB | 需鉴别 |
| pagefile.sys | 19 GB | 系统文件 |
| D:\dev 开发文件 | 22.7 GB | 部分可清理 |

### Step 2: Docker 重复数据清理 (释放 3.7 GB)

**现象:** SpaceSniffer 报告显示两个 `docker_data.vhdx` 在不同路径层级：
- `D:\DockerData\DockerDesktopWSL\DockerDesktopWSL\disk\docker_data.vhdx` (25.6 GB)
- `D:\DockerData\DockerDesktopWSL\disk\docker_data.vhdx` (3.7 GB)

**鉴别方法:**
1. 读取 Docker 配置文件 `%APPDATA%\Docker\settings.json` → 找到 `customWslDistroDir: "D:\\DockerData\\DockerDesktopWSL\\DockerDesktopWSL"`
2. 对比两个文件的 `LastWriteTime`：
   - 嵌套路径 (25.6 GB): 2026/7/3 — **当前在用**
   - 外层路径 (3.7 GB): 2026/1/6 — **遗留旧数据**（6 个月未更新）

**安全流程:**
```powershell
# 1. 停止 Docker + WSL
wsl --shutdown

# 2. 重命名（不直接删除，验证安全）
Rename-Item "D:\DockerData\DockerDesktopWSL\disk\docker_data.vhdx" docker_data.vhdx.bak

# 3. 重启 Docker Desktop，验证容器/镜像正常

# 4. 确认无误后删除 .bak
Remove-Item "D:\DockerData\DockerDesktopWSL\disk\docker_data.vhdx.bak"

# 5. 清理空目录
Remove-Item "D:\DockerData\DockerDesktopWSL\main"  # 如为空
```

**根因:** Docker `customWslDistroDir` 配置从 `D:\DockerData\DockerDesktopWSL` 改为 `D:\DockerData\DockerDesktopWSL\DockerDesktopWSL`（嵌套加深一层），旧路径数据未被清理。

### Step 3: CUDA 安装包清理 (释放 3.25 GB)

**文件:** `D:\dev\infinitensor2025winter\stage1\Learning-CUDA\cuda-repo-wsl-ubuntu-13-1-local_13.1.1-1_amd64.deb`

**判定:** 3.25 GB 的 .deb 安装包，安装后即无用途，可安全删除。

```powershell
Remove-Item "D:\dev\...\cuda-repo-wsl-ubuntu-13-1-local_13.1.1-1_amd64.deb"
```

### Step 4: DeepSeek Git LFS 缓存 (保留)

**文件:** `DeepSeek-R1-Distill-Qwen-1.5B\.git\lfs\objects\` (3.55 GB)

**说明:** 是 `model.safetensors` (3.3 GB) 的版本控制冗余副本。**用户决定保留**，故跳过。

---

## 关键经验

### 1. Docker 重复数据检测模式
- 两个 `docker_data.vhdx` 在不同路径层级 → 检查 `customWslDistroDir` 配置
- 对比 `LastWriteTime` 判断哪个在用
- 重命名法验证安全，不直接删除

### 2. 开发目录大文件模式
- CUDA `.deb` 安装包 (3+ GB) 常见于 ML 开发目录
- 安装后即无用途，可安全删除
- 用户确认即可执行

### 3. Git LFS 缓存
- ML 模型的 `.git/lfs/objects` 几乎等于模型文件本身大小
- 删除前必须问用户模型是否还需要
- 不可自动删除
