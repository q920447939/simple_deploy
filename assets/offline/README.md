# 离线安装包（控制端）

本目录用于在 **控制端** 缺少 `python3.12` / `ansible-playbook` 时，由客户端（Flutter）通过 SSH 上传并自动安装。

## 支持范围
- OS：Ubuntu `24+`、银河麒麟 `V10 SP3`
- 架构：`x86_64`、`aarch64`

## 文件说明
- `manifest.json`：离线包版本与路径映射（客户端读取）。
- `python/`：`python-build-standalone` 的 `install_only.tar.gz`。
- `ansible/`：`pip wheelhouse` 打包（`tar.gz`）。
- `os_pkgs/`：控制端常用系统工具的离线包（当前提供 Ubuntu 的 `sshpass/unzip` `.deb`，用于尽量自动补齐依赖）。
- `bootstrap/install_control_runtime.sh`：控制端执行的安装脚本（幂等）。

## 生成/更新离线包
在仓库根目录执行：
- `bash tools/offline/fetch_offline_deps.sh`

说明：
- 该脚本会按 `assets/offline/manifest.json` 的版本下载/生成离线包（需要联网）。
- 离线包体积较大，建议配合 Git LFS；否则仓库会快速膨胀。
