# simple_deploy

简易 Ansible 部署升级桌面工具（v1）原型：Flutter Desktop（Windows/Linux）+ 本地 JSON 存储 + SSH 下发到控制端执行。

## 大文件（必读）
仓库内 `assets/offline/` 含离线安装包（体积较大），使用 **Git LFS** 存储。

首次拉取/更新请执行：
- `git lfs install`
- `git lfs pull`

## 开发环境
- Flutter stable（当前工程使用 `shadcn_flutter` 作为 UI 组件库）

## 运行
- `flutter run -d linux`
- `flutter run -d windows`

## 使用说明（v1）
- `docs/使用说明.md`
- 应用内右上角 `?`：查看版本号、数据目录路径与最小使用说明（可复制数据目录路径）

## 本地数据目录
启动时会创建应用数据目录，并写入：
- `app_state.json`：记录最后启动时间（验证可读写）
- `app_logs/`：客户端运行日志（JSONL）
- `projects/projects.json`：项目索引（创建项目后写入）

应用数据根目录通过 `path_provider.getApplicationSupportDirectory()` 获取，并在其下使用 `simple_deploy/` 作为根目录。

## 代码结构（分层）
- `lib/model/`：数据模型
- `lib/storage/`：本地文件存储（含原子写入）
- `lib/services/ssh/`：SSH/SFTP（控制端连接，基于 `dartssh2`）
- `lib/services/run_engine/`：执行引擎（控制端自检/下发/执行，v1 逐步落地）
- `lib/ui/`：UI（左侧导航 + 右侧 master-detail）
