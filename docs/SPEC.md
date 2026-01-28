# 简易 Ansible 部署升级桌面工具（Simple Deploy）需求&技术规格（v1）

最后更新：2026-01-13  
目标平台：Windows / Linux 桌面应用（单人使用）  
核心约束：不额外部署后端服务；所有数据本地文件保存；通过 SSH 将 playbook+文件下发到控制端执行

---

# 总体需求描述

## 1. 背景与问题
当前有小批量 Linux 服务器（x86/arm 均可能），软件以“分布式/集群”方式部署（包含纯命令与 Docker 容器两类）。人工在多台机器重复操作会导致：
- 升级部署耗时高；
- 误操作概率高；
- 执行过程与结果缺少结构化留存与回溯。

## 2. 目标
构建一个“单人使用”的桌面工具，基于 Ansible Playbook 实现标准化部署/升级：
- 在客户端完成：项目/服务器/playbook/任务/执行批次的配置与管理；
- 执行时：将 playbook 与本次涉及的业务文件下发到“控制端服务器”（已安装 ansible），由控制端 SSH 直连被控端执行；
- 执行结果：记录 Ansible 结果（退出码/日志），并可选记录业务状态（由 playbook 产出）。

## 3. 非目标（v1 不做）
- 不提供多用户、登录、RBAC、审计权限体系；
- 不做密码加密/脱敏（仅本地明文文件保存）；
- 不做复杂 inventory 分组/角色模型（仅控制端/被控端两类逻辑实体）；
- 不做自动队列调度（无“排队中”概念；只允许手动点击执行）；
- 不做断点续跑（失败即结束，需要人工修复后重新执行）；
- 不做日志自动清理/归档下载。

## 4. 核心名词
- 客户端：本桌面应用（负责配置、下发、触发执行、展示日志/结果）。
- 控制端：安装了 `ansible-playbook` 的 Linux 服务器；客户端把执行包发送到控制端，由控制端执行 playbook。
- 被控端：部署目标 Linux 服务器；控制端通过 SSH 直连（root/密码）。
- 项目：配置隔离单元（服务器、playbook、任务、批次都归属某个项目）。
- Playbook：项目目录下的 YAML 文件 + 元信息（名称、简述等）。
- 任务（Task）：绑定一个 playbook，并声明“是否需要用户上传文件槽位”。
- 执行批次（Batch）：选择 1 控制端 + N 被控端 + 任务列表（有序）；批次可多次执行。
- 执行记录（Run）：一次真实执行（批次的一次运行）；日志与结果按 Run 留存。

## 5. 前置条件（必须满足）
- 控制端：
  - Linux；
  - 已安装 `ansible-playbook`（或由客户端在支持的系统上自动安装：Ubuntu 24+ / 银河麒麟 V10 SP3，x86_64/aarch64）；
  - 能 SSH 直连所有被控端；
  - 支持密码方式 SSH（建议安装 `sshpass`；见“技术文档-执行协议”）。
- 被控端：
  - Linux；
  - Python 版本 >= 3.8；
  - 提供 root/密码登录。
- 网络：
  - 客户端能 SSH 连接到控制端；
  - 控制端能 SSH 连接到所有被控端。

## 6. 状态机（v1）
### 6.1 批次状态（Batch）
仅三态：
- 暂停：可编辑批次配置（控制端/被控端/任务顺序/文件槽位绑定等）。
- 运行中：该批次当前存在且仅存在 1 个 Run 处于运行中；禁止编辑与重复执行。
- 结束：该批次最近一次 Run 已结束（成功/失败写在 Run 中）；允许“重置为暂停”后再编辑并重新执行。

规则：
- 同一批次同一时间最多 1 个 Run 运行（批次级锁）。
- 同一项目下不同批次允许运行多个 Run（并发）。

### 6.2 执行记录状态（Run）
- 运行中
- 结束（成功/失败）

## 7. 功能需求（按模块）

### 7.1 项目管理
- 新增/编辑/删除/列表：
  - 项目名称（唯一/建议唯一）；
  - 项目简介；
  - 创建时间/更新时间（系统自动维护）。

### 7.2 服务器管理（项目内）
支持增删改查。服务器条目分两类逻辑实体：
- 控制端实体：可被选择为“执行节点”（控制端）。
- 被控端实体：可被选择为“部署目标”（被控端）。

约束：
- 一台物理机器允许同时存在两条记录（同 IP），分别作为控制端与被控端两个逻辑实体；
- v1 不做业务分组/标签；inventory 只需支持“全量主机集合”。

字段建议（可调整）：
- `id`、`name`、`ip`、`port`、`username`、`password`
- `type`: `control` | `managed`
- `enabled`: bool

### 7.3 Playbook 管理（项目内）
- Playbook 文件统一存放于项目目录下（本地文件）；
- 支持：
  - 列表（名称/简述/更新时间）；
  - 新增（创建文件）；
  - 在线编辑（文本编辑器）；
  - 删除/批量删除；
  - 查看（只读）。
- 保存时校验：
  - YAML 基础语法校验（至少确保可解析）；
  - （可选）业务状态约定校验（见“业务状态文件约定”）。

### 7.4 任务（Task）管理（项目内）
- 任务定义至少包含：
  - 任务名称/简述；
  - 绑定一个 Playbook；
  - 文件槽位声明（可选）：如 `artifacts`、`package` 等，仅声明“需不需要/允许几个”，不关心文件类型与目标路径（交由 playbook 使用）。

示例槽位结构（概念）：
- 槽位名：`artifacts`
- 必选：true/false
- 多文件：true/false

### 7.5 执行批次（Batch）管理（项目内）
#### 7.5.1 创建/编辑
批次必须包含：
- 选择 1 个控制端（必选，且仅 1 个）；
- 选择 >=1 个被控端（必选）；
- 选择 >=1 个任务（必选，按顺序执行）。

编辑规则：
- 批次处于“暂停”时允许编辑：
  - 控制端/被控端；
  - 任务顺序；
  - 任务对应的文件槽位绑定（本次执行用的具体文件，建议与 Run 强绑定，见“执行流程”）。
- 批次处于“运行中”禁止编辑。

#### 7.5.2 执行与重置
- 点击“执行”：
  - 若存在必选文件槽位：必须在执行前完成本次文件选择并落盘；
  - 创建新的 Run（保留历史 Run）；
  - 批次进入“运行中”。
- 执行结束：
  - 任一任务失败 -> 本次 Run 失败，批次进入“结束”；
  - 全部任务成功 -> 本次 Run 成功，批次进入“结束”。
- “重置为暂停”：
  - 仅针对批次（Batch）；
  - 允许再次编辑并重新执行；
  - 不修改历史 Run（只读保留）。

### 7.6 执行日志与可视化
批次详情页：
- 上方：任务进度条（每个任务一个节点）：
  - 等待中 / 执行中 / 成功 / 失败
- 下方：日志区域：
  - 默认展示当前执行中的任务日志；
  - 若无执行中任务（全部结束），默认展示最后一个任务日志；
  - 支持切换查看任意任务日志；
  - 支持在“历史 Run 列表”中选择某次 Run 查看其日志。

实时更新：
- v1 以最简单实现为准：轮询追加（或按需拉取远程日志并本地追加）。

## 8. 成功/失败与业务状态
### 8.1 Ansible 成功/失败（强制记录）
- 以每个任务执行的 `ansible-playbook` 退出码判定：
  - `0`：成功
  - 非 `0`：失败（批次整体失败并结束）

### 8.2 业务状态（可选记录，强烈建议）
允许 playbook 在执行过程中产出结构化业务状态（例如健康检查结果、版本号、服务状态等）：
- 若存在业务状态文件：客户端解析并记录到 Run；
- 若不存在：业务状态记为 `unknown`（不影响 Ansible 成败判定）。

业务状态文件约定见“技术栈描述-执行协议/Playbook 模板”。

---

# 技术栈描述

## 1. 客户端形态与运行方式
- 仅开发桌面应用（Flutter Desktop）：
  - Windows（x64）
  - Linux（x64）
- 单人使用：配置、文件、日志均存本机。

## 2. 主要技术选型（建议）
- 语言/框架：Flutter（Dart）
- SSH/SFTP：Dart SSH 客户端库（例如 `dartssh2`，具体以实现时评估为准）
- 本地文件存储：
  - JSON + 目录结构（不引入数据库）
  - 通过 `path_provider` 获取应用数据目录（Windows/Linux）
- 压缩打包：`archive`（zip）
- 文件选择：`file_picker`
- 状态管理：任选（Riverpod/Bloc/Provider）；v1 以可维护为主
- 日志展示：基于 `Stream` + 文本增量追加（可加行号/搜索为后续迭代）

## 3. 本地数据目录与文件结构（建议）
应用数据根目录（示例）：
- Windows：`%APPDATA%/simple_deploy/`
- Linux：`~/.local/share/simple_deploy/`

项目内结构建议：
- `projects/<project_id>/project.json`
- `projects/<project_id>/servers.json`
- `projects/<project_id>/playbooks/`
- `projects/<project_id>/playbooks.json`
- `projects/<project_id>/tasks.json`
- `projects/<project_id>/batches/<batch_id>.json`
- `projects/<project_id>/runs/<run_id>.json`
- `projects/<project_id>/run_artifacts/<run_id>/...`
- `projects/<project_id>/run_logs/<run_id>/task_<index>.log`
- `projects/<project_id>/locks/batch_<batch_id>.lock`

写入原则（避免 JSON 损坏）：
- 采用“写临时文件 -> 原子 rename 覆盖”；
- 批次锁使用“原子创建 lock 文件”实现互斥。

## 4. 控制端执行协议（核心）
### 4.1 控制端工作目录
每次 Run 在控制端创建独立目录（示例）：
- `/tmp/simple_deploy/<project_id>/<run_id>/`

客户端向该目录下发执行包（建议 zip）：
- `bundle.zip`
- `run.sh`（可选：由客户端生成的执行脚本）

解包后目录结构建议：
- `playbooks/`：playbook 文件
- `files/`：本次 Run 上传的业务文件（按任务/槽位组织）
- `inventory.ini`
- `vars.json`：本次 Run 的统一变量（run_id、files 映射等）
- `logs/`：控制端侧日志（每任务一个文件，最终可拉回客户端）
- `results/`：
  - `run_result.json`（客户端可写/或由 run.sh 写）
  - `biz_status.json`（可选，由 playbook 生成）

### 4.2 inventory 生成（最简）
客户端在每次 Run 生成 `inventory.ini`，示例（概念）：
- `[all]`
- `host_001 ansible_host=10.0.0.1 ansible_user=root ansible_password=xxx ansible_port=22 ansible_connection=paramiko ansible_python_interpreter=/usr/local/bin/python3.12`

说明：
- v1 不做分组；playbook 默认对 `all` 执行即可。

### 4.3 执行命令（逐任务顺序）
每个任务对应一个 playbook，控制端依次执行：
- `ansible-playbook -i inventory.ini playbooks/<task_playbook>.yml --extra-vars @vars.json`

退出策略：
- 任一任务退出码非 0：立刻停止后续任务，Run 失败，写入结果并结束。

### 4.4 密码 SSH 依赖
为降低控制端依赖，客户端默认使用 `paramiko` 连接方式（纯 Python），不强制要求安装 `sshpass`。

说明：
- 若控制端未安装 `sshpass` 也可执行；
- 若希望走系统 OpenSSH（非 `paramiko`），可在控制端安装 `sshpass` 作为密码登录补充。

## 5. Playbook 使用本次上传文件的约定
客户端将用户选择的文件存入 `files/`，并在 `vars.json` 中写入映射，例如（概念）：
```json
{
  "run_id": "run_20260113_0001",
  "run_dir": "/tmp/simple_deploy/p1/run_20260113_0001",
  "files": {
    "task_1": {
      "artifacts": [
        "files/task_1/artifacts/app.tar.gz",
        "files/task_1/artifacts/conf.zip"
      ]
    }
  }
}
```

playbook 通过变量拿到路径后自行处理（copy/unarchive/docker load 等）。客户端不关心文件类型与处理方式。

## 6. 业务状态文件约定（可选）
约定：playbook 可在结束阶段生成一个 JSON 文件到控制端 `results/biz_status.json`，客户端读取并写入本地 Run 记录。

建议字段（可扩展）：
- `status`: `ok` | `failed` | `unknown`
- `message`: string
- `version`: string（可选）
- `timestamp`: string（可选）

示例（概念，playbook 片段）：
- 在 playbook 最后增加一个“汇总/验证”步骤；
- 若验证失败使用 `assert` / `fail` 直接让任务失败（同时可写 biz_status）。

---

# 开发约束
- 不引入独立后端服务；所有逻辑在桌面客户端内完成。
- 不使用数据库；本地文件（JSON + 目录）持久化。
- 支持项目内并发执行：不同批次可并行；同一批次必须互斥。
- 执行过程不得阻塞 UI：网络/文件/执行均需异步（必要时使用 isolate）。
- 失败不自动重试；提供清晰的错误提示与可定位日志。
- 配置与日志必须可回溯：批次可多次执行，Run 记录只读保留。

# 视觉约束
- 信息架构（建议）：
  - 左侧导航：项目列表 / 服务器 / playbooks / 任务 / 批次 / 运行记录
  - 右侧内容：列表 + 详情（可采用 master-detail）
- 批次详情必须包含：
  - 任务进度条（等待/执行中/成功/失败的颜色区分）
  - 日志查看（任务维度切换 + 历史 Run 切换）
- 编辑体验：
  - playbook 在线编辑：基础的 YAML 文本编辑（v1 不强制语法高亮）
  - 文件绑定：清晰展示“槽位名/必选/已选择文件列表/替换按钮”

# 其他约束
- 明文密码风险：v1 明确提示“仅适用于内网/单机/单人”，并建议操作系统层面保护应用数据目录权限。
- 可靠性：
  - JSON 原子写；
  - lock 文件互斥；
  - 客户端崩溃后提供“强制解锁/重置”入口。
- 可观测性：
  - 每个任务一份日志；
  - Run 结果包含：开始/结束时间、任务级 rc、总体 rc、错误摘要、（可选）业务状态。

---

# 任务列表

## 任务1：初始化项目与基础架构
- 创建 Flutter Desktop 工程（Windows/Linux）
- 确定目录结构（lib/ 分层、docs/、assets/）
- 引入基础依赖（SSH、zip、file picker、path provider、状态管理）

## 任务2：本地存储与数据模型
- 定义数据模型：Project/Server/PlaybookMeta/Task/Batch/Run
- 实现本地数据目录定位与初始化
- 实现 JSON 原子读写与版本迁移（v1 可仅预留版本字段）
- 实现批次锁（lock 文件）与崩溃恢复入口（强制解锁）

## 任务3：项目管理 UI
- 项目列表/新增/编辑/删除
- 项目切换后加载对应数据

## 任务4：服务器管理 UI
- 控制端/被控端分别展示与筛选
- 服务器增删改查（含 root/密码、端口）
- 连接测试（客户端 -> 控制端 SSH 可达性测试）

## 任务5：Playbook 管理与编辑器
- playbook 列表/新增/删除/批量删除
- 在线编辑与保存到本地文件
- YAML 基础语法校验（保存时提示错误定位）

## 任务6：任务（Task）管理
- 任务列表/新增/编辑/删除
- 绑定 playbook
- 配置文件槽位（必选/多文件/槽位名）

## 任务7：批次（Batch）管理
- 批次列表/新增/编辑/删除
- 选择控制端（单选）、被控端（多选）、任务（多选+排序）
- 批次状态机：暂停/运行中/结束 + 重置为暂停

## 任务8：执行引擎（核心）
- 生成 Run（run_id）与运行快照（本次选择文件与映射）
- 生成 inventory.ini 与 vars.json
- 将 playbooks + files + 配置打包为 zip
- SSH/SFTP 下发到控制端 run_dir 并解包
- 依序执行任务（ansible-playbook），捕获退出码与 stdout/stderr
- 失败即停，写入 Run 结果
- 拉取控制端侧日志/结果文件到本地（或执行时实时镜像到本地）

## 任务9：日志与进度展示
- 任务进度条（等待/执行中/成功/失败）
- 日志查看：按任务切换、按历史 Run 切换
- 实时更新（v1 轮询追加/流式二选一，以最简单实现为准）

## 任务10：健壮性与验收
- 控制端依赖自检（python3.12/ansible-playbook；可选 unzip/sshpass）
- 常见错误提示：SSH 失败、解包失败、playbook 路径错误、退出码非0
- 最小可用验收用例（手工）：
  - 单任务成功
  - 中途失败停止
  - 同项目两批次并发运行
  - 批次结束后重置为暂停并替换文件再执行
