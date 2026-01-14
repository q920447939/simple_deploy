import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../services/app_services.dart';

Future<void> showAboutAndHelpDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _AboutAndHelpDialog(),
  );
}

class _AboutAndHelpDialog extends StatefulWidget {
  const _AboutAndHelpDialog();

  @override
  State<_AboutAndHelpDialog> createState() => _AboutAndHelpDialogState();
}

class _AboutAndHelpDialogState extends State<_AboutAndHelpDialog> {
  PackageInfo? _info;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    // ignore: unawaited_futures
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _info = info);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e);
    }
  }

  String _versionText() {
    final info = _info;
    if (info == null) {
      return _loadError == null ? '加载中…' : '读取失败';
    }
    final build = info.buildNumber.trim();
    return build.isEmpty ? info.version : '${info.version}+$build';
  }

  @override
  Widget build(BuildContext context) {
    final dataDir = AppServices.I.paths.rootDir.path;

    return AlertDialog(
      title: const Text('关于 / 使用说明'),
      content: SizedBox(
        width: 860,
        height: 560,
        child: ListView(
          children: [
            Row(
              children: [
                Expanded(child: Text('Simple Deploy').h3()),
                Text('版本: ${_versionText()}').mono(),
              ],
            ),
            const SizedBox(height: 8),
            Text('数据目录: $dataDir').mono(),
            if (_loadError != null) ...[
              const SizedBox(height: 6),
              Text('版本信息读取失败：$_loadError').muted(),
            ],
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),
            Text('风险提示').p(),
            const SizedBox(height: 6),
            Text('v1 明文保存密码，仅适用于内网/单人/受控环境。').muted(),
            const SizedBox(height: 16),
            Text('控制端依赖（必须）').p(),
            const SizedBox(height: 6),
            const CodeSnippet(
              code: Text(
                'ansible-playbook\nsshpass\nunzip\nssh（系统自带）',
              ),
            ),
            const SizedBox(height: 12),
            Text('被控端依赖（必须）').p(),
            const SizedBox(height: 6),
            const CodeSnippet(code: Text('Linux + Python >= 3.8')),
            const SizedBox(height: 16),
            Text('首次配置步骤（最小）').p(),
            const SizedBox(height: 6),
            Steps(
              children: const [
                StepItem(
                  title: Text('创建项目'),
                  content: [Text('项目用于隔离服务器/Playbook/任务/批次。')],
                ),
                StepItem(
                  title: Text('添加服务器'),
                  content: [Text('至少 1 控制端 + 1 被控端（root/密码）。')],
                ),
                StepItem(
                  title: Text('创建 Playbook'),
                  content: [Text('在 Playbook 页面新建并保存（会做 YAML 语法校验）。')],
                ),
                StepItem(
                  title: Text('创建任务'),
                  content: [Text('任务绑定 Playbook，可声明文件槽位（可选/必选/多文件）。')],
                ),
                StepItem(
                  title: Text('创建批次'),
                  content: [Text('选择 1 控制端、>=1 被控端、>=1 任务并排序。')],
                ),
                StepItem(
                  title: Text('执行'),
                  content: [Text('执行前按任务槽位选择文件；失败会停止后续任务。')],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('常见错误').p(),
            const SizedBox(height: 6),
            const CodeSnippet(
              code: Text(
                '- SSH 连接失败：检查 IP/端口/密码/防火墙\n'
                '- 控制端自检失败：缺少 ansible-playbook/sshpass/unzip 或 /tmp 不可写\n'
                '- 解包失败：控制端 unzip 缺失或权限不足\n'
                '- ansible-playbook exit!=0：查看批次详情的任务日志定位原因',
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: dataDir));
            if (!context.mounted) return;
            showToast(
              context: context,
              builder: (context, overlay) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Expanded(child: Text('已复制数据目录路径')),
                      GhostButton(
                        density: ButtonDensity.icon,
                        onPressed: overlay.close,
                        child: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
          child: const Text('复制数据目录'),
        ),
        PrimaryButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
