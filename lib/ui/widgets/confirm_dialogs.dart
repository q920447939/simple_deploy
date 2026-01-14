import 'package:shadcn_flutter/shadcn_flutter.dart';

Future<bool> confirmDiscardChanges(
  BuildContext context, {
  String title = '放弃未保存修改？',
  required String message,
  String discardLabel = '放弃',
  String cancelLabel = '取消',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        DestructiveButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(discardLabel),
        ),
      ],
    ),
  );
  return ok == true;
}

Future<bool> confirmDeleteProject(
  BuildContext context, {
  required String projectName,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除项目？'),
      content: Text(
        '将删除项目“$projectName”的所有数据：服务器、Playbook、任务、批次、Run、日志（不可恢复）。',
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        DestructiveButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return ok == true;
}

Future<bool> confirmProceedUnsupportedControlAutoInstall(
  BuildContext context, {
  required String detected,
  required List<String> missingRequired,
}) async {
  final missingText = missingRequired.isEmpty
      ? '（未知：未检测到缺失项）'
      : missingRequired.map((x) => '- $x').join('\n');

  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('控制端系统不在支持列表'),
      content: SizedBox(
        width: 760,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('该控制端不满足自动安装白名单，但你选择继续后，仍会尝试上传离线包并通过 sudo 安装依赖（可能失败）。'),
            const SizedBox(height: 12),
            const Text('检测到：').p(),
            CodeSnippet(code: Text(detected).mono()),
            const SizedBox(height: 12),
            const Text('缺失项（将尝试安装）：').p(),
            CodeSnippet(code: Text(missingText).mono()),
            const SizedBox(height: 12),
            const Text('建议：优先在控制端手工安装 python3.12 与 ansible-playbook。').muted(),
          ],
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        DestructiveButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('继续并尝试自动安装'),
        ),
      ],
    ),
  );
  return ok == true;
}
