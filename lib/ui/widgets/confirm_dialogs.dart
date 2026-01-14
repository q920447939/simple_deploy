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
