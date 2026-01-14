import 'package:flutter/material.dart' as m;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../../model/server.dart';
import '../../../services/app_services.dart';
import '../../../services/core/app_error.dart';
import '../../controllers/servers_controller.dart';
import '../../widgets/app_error_dialog.dart';
import '../../widgets/project_guard.dart';

class ServersPage extends StatelessWidget {
  const ServersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(ServersController());

    Widget toggle(String type, String label) {
      return Obx(() {
        final selected = controller.filterType.value == type;
        return selected
            ? SecondaryButton(
                onPressed: () => controller.filterType.value = type,
                child: Text(label),
              )
            : OutlineButton(
                onPressed: () => controller.filterType.value = type,
                child: Text(label),
              );
      });
    }

    return ProjectGuard(
      child: Padding(
        padding: EdgeInsets.all(16.r),
        child: Row(
          children: [
            SizedBox(
              width: 360.w,
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(12.r),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text('服务器').p()),
                          PrimaryButton(
                            density: ButtonDensity.icon,
                            onPressed: () async {
                              final created = await showDialog<Server>(
                                context: context,
                                builder: (context) => _ServerEditDialog(
                                  initial: null,
                                  defaultType: controller.filterType.value,
                                ),
                              );
                              if (created == null) return;
                              try {
                                await controller.upsert(created);
                              } on AppException catch (e) {
                                if (context.mounted) {
                                  await showAppErrorDialog(context, e);
                                }
                              }
                            },
                            child: const Icon(Icons.add),
                          ),
                        ],
                      ),
                      SizedBox(height: 12.h),
                      Wrap(
                        spacing: 8.w,
                        children: [
                          toggle(ServerType.control, '控制端'),
                          toggle(ServerType.managed, '被控端'),
                        ],
                      ),
                      SizedBox(height: 12.h),
                      Expanded(
                        child: Obx(() {
                          final items = controller.filtered.toList();
                          if (items.isEmpty) {
                            return const Center(child: Text('暂无服务器'));
                          }
                          return m.ListView.builder(
                            itemCount: items.length,
                            itemBuilder: (context, i) {
                              final s = items[i];
                              final selected =
                                  controller.selectedId.value == s.id;
                              final lastTest = _formatLastTest(s);
                              return m.ListTile(
                                selected: selected,
                                title: Text(s.name),
                                subtitle: Column(
                                  crossAxisAlignment:
                                      m.CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${s.ip}:${s.port}  ·  ${s.username}',
                                    ).muted(),
                                    Text(lastTest).muted(),
                                  ],
                                ),
                                trailing: s.enabled
                                    ? null
                                    : const Icon(Icons.block),
                                onTap: () => controller.selectedId.value = s.id,
                              );
                            },
                          );
                        }),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: 16.w),
            Expanded(
              child: Obx(() {
                final s = controller.selected;
                if (s == null) {
                  return const Card(child: Center(child: Text('选择一个服务器查看详情')));
                }
                return _ServerDetail(server: s);
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerDetail extends StatelessWidget {
  final Server server;

  const _ServerDetail({required this.server});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ServersController>();
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.r),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(server.name).h2()),
                GhostButton(
                  onPressed: () async {
                    final updated = await showDialog<Server>(
                      context: context,
                      builder: (context) => _ServerEditDialog(
                        initial: server,
                        defaultType: server.type,
                      ),
                    );
                    if (updated == null) return;
                    try {
                      await controller.upsert(updated);
                    } on AppException catch (e) {
                      if (context.mounted) {
                        await showAppErrorDialog(context, e);
                      }
                    }
                  },
                  child: const Text('编辑'),
                ),
                SizedBox(width: 8.w),
                DestructiveButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('删除服务器？'),
                        content: Text('将删除：${server.name}'),
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
                    if (ok != true) return;
                    try {
                      await controller.deleteSelected();
                    } on AppException catch (e) {
                      if (context.mounted) {
                        await showAppErrorDialog(context, e);
                      }
                    }
                  },
                  child: const Text('删除'),
                ),
              ],
            ),
            SizedBox(height: 12.h),
            Text('类型: ${server.type}').mono(),
            SizedBox(height: 6.h),
            Text('地址: ${server.ip}:${server.port}').mono(),
            SizedBox(height: 6.h),
            Text('用户名: ${server.username}').mono(),
            SizedBox(height: 6.h),
            Text('启用: ${server.enabled}').mono(),
            SizedBox(height: 6.h),
            Text('最后测试: ${_formatLastTest(server)}').mono(),
            if ((server.lastTestMessage ?? '').trim().isNotEmpty) ...[
              SizedBox(height: 6.h),
              Text('测试信息: ${server.lastTestMessage}').mono(),
            ],
            SizedBox(height: 16.h),
            Row(
              children: [
                Text('快速操作').p(),
                SizedBox(width: 12.w),
                Expanded(
                  child: Obx(() {
                    final isTesting = controller.testingId.value == server.id;
                    final mode = controller.testingMode.value;

                    final label = server.type == ServerType.control
                        ? '控制端连接测试（uname -a）'
                        : 'SSH 登录测试（uname -a）';

                    Widget progressLabel(String text) {
                      return Row(
                        mainAxisSize: m.MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 14.w,
                            height: 14.w,
                            child: const m.CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8.w),
                          Text(text),
                        ],
                      );
                    }

                    return Wrap(
                      spacing: 8.w,
                      runSpacing: 8.h,
                      children: [
                        OutlineButton(
                          onPressed: isTesting
                              ? null
                              : () async {
                                  try {
                                    final r = await controller
                                        .testSshConnectivity(server);
                                    if (!context.mounted) return;
                                    await showDialog<void>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: Text(
                                          r.exitCode == 0 ? '连接成功' : '连接失败',
                                        ),
                                        content: SizedBox(
                                          width: 640.w,
                                          child: m.SingleChildScrollView(
                                            child: Text(
                                              r.exitCode == 0
                                                  ? (r.stdout.trim().isEmpty
                                                        ? 'ok'
                                                        : r.stdout.trim())
                                                  : (r.stderr.trim().isEmpty
                                                        ? r.stdout.trim()
                                                        : r.stderr.trim()),
                                            ).mono(),
                                          ),
                                        ),
                                        actions: [
                                          PrimaryButton(
                                            onPressed: () =>
                                                Navigator.of(context).pop(),
                                            child: const Text('知道了'),
                                          ),
                                        ],
                                      ),
                                    );
                                  } on AppException catch (e) {
                                    if (context.mounted) {
                                      await showAppErrorDialog(context, e);
                                    }
                                  }
                                },
                          child: (isTesting && mode == 'ssh')
                              ? progressLabel('测试中...')
                              : Text(label),
                        ),
                        if (server.type == ServerType.control)
                          OutlineButton(
                            onPressed: isTesting
                                ? null
                                : () async {
                                    try {
                                      final r = await controller
                                          .selfCheckControlEnvironment(server);
                                      if (!context.mounted) return;
                                      await showDialog<void>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: Text(
                                            r.ok ? '环境自检通过' : '环境自检失败',
                                          ),
                                          content: SizedBox(
                                            width: 760.w,
                                            child: m.SingleChildScrollView(
                                              child: Text(r.details).mono(),
                                            ),
                                          ),
                                          actions: [
                                            PrimaryButton(
                                              onPressed: () =>
                                                  Navigator.of(context).pop(),
                                              child: const Text('知道了'),
                                            ),
                                          ],
                                        ),
                                      );
                                    } on AppException catch (e) {
                                      if (context.mounted) {
                                        await showAppErrorDialog(context, e);
                                      }
                                    }
                                  },
                            child: (isTesting && mode == 'selfcheck')
                                ? progressLabel('自检中...')
                                : const Text('环境自检'),
                          ),
                      ],
                    );
                  }),
                ),
              ],
            ),
            SizedBox(height: 8.h),
            Text('注意：v1 明文保存密码，仅适用于内网/单人/受控环境。').muted(),
          ],
        ),
      ),
    );
  }
}

class _ServerEditDialog extends StatefulWidget {
  final Server? initial;
  final String defaultType;

  const _ServerEditDialog({required this.initial, required this.defaultType});

  @override
  State<_ServerEditDialog> createState() => _ServerEditDialogState();
}

class _ServerEditDialogState extends State<_ServerEditDialog> {
  final m.TextEditingController _name = m.TextEditingController();
  final m.TextEditingController _ip = m.TextEditingController();
  final m.TextEditingController _port = m.TextEditingController(text: '22');
  final m.TextEditingController _user = m.TextEditingController(text: 'root');
  final m.TextEditingController _pwd = m.TextEditingController();

  String _type = ServerType.control;
  bool _enabled = true;
  bool _obscurePwd = true;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _type = i?.type ?? widget.defaultType;
    _enabled = i?.enabled ?? true;
    if (i != null) {
      _name.text = i.name;
      _ip.text = i.ip;
      _port.text = '${i.port}';
      _user.text = i.username;
      _pwd.text = i.password;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _ip.dispose();
    _port.dispose();
    _user.dispose();
    _pwd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ServersController>();
    final pid = controller.projectId;
    final initial = widget.initial;
    return AlertDialog(
      title: Text(initial == null ? '新增服务器' : '编辑服务器'),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            m.DropdownButtonFormField<String>(
              key: ValueKey(_type),
              initialValue: _type,
              decoration: const m.InputDecoration(labelText: '类型'),
              items: const [
                m.DropdownMenuItem(
                  value: ServerType.control,
                  child: Text('控制端（执行节点）'),
                ),
                m.DropdownMenuItem(
                  value: ServerType.managed,
                  child: Text('被控端（目标主机）'),
                ),
              ],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            SizedBox(height: 12.h),
            m.TextField(
              controller: _name,
              decoration: const m.InputDecoration(labelText: '名称'),
            ),
            SizedBox(height: 12.h),
            m.TextField(
              controller: _ip,
              decoration: const m.InputDecoration(labelText: 'IP'),
            ),
            SizedBox(height: 12.h),
            Row(
              children: [
                Expanded(
                  child: m.TextField(
                    controller: _port,
                    decoration: const m.InputDecoration(labelText: '端口'),
                    keyboardType: m.TextInputType.number,
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: m.TextField(
                    controller: _user,
                    decoration: const m.InputDecoration(labelText: '用户名'),
                  ),
                ),
              ],
            ),
            SizedBox(height: 12.h),
            m.TextField(
              controller: _pwd,
              obscureText: _obscurePwd,
              decoration: m.InputDecoration(
                labelText: '密码',
                suffixIcon: m.IconButton(
                  tooltip: _obscurePwd ? '显示密码' : '隐藏密码',
                  onPressed: () => setState(() => _obscurePwd = !_obscurePwd),
                  icon: Icon(
                    _obscurePwd ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
            ),
            SizedBox(height: 12.h),
            m.SwitchListTile(
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
              title: const Text('启用'),
            ),
            if (pid == null) ...[
              SizedBox(height: 12.h),
              const Text('未选择项目，无法保存。').muted(),
            ],
          ],
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        PrimaryButton(
          onPressed: pid == null
              ? null
              : () async {
                  final name = _name.text.trim();
                  final ip = _ip.text.trim();
                  final portText = _port.text.trim();
                  final port = int.tryParse(portText) ?? 22;
                  final username = _user.text.trim().isEmpty
                      ? 'root'
                      : _user.text.trim();

                  final validationError = _validateServerInputs(
                    name: name,
                    host: ip,
                    port: port,
                    username: username,
                  );
                  if (validationError != null) {
                    await showAppErrorDialog(
                      context,
                      AppException(
                        code: AppErrorCode.validation,
                        title: '输入不合法',
                        message: validationError,
                        suggestion: '请修正后再保存。',
                      ),
                    );
                    return;
                  }

                  final id = initial?.id ?? AppServices.I.uuid.v4();
                  final base =
                      initial ??
                      Server(
                        id: id,
                        name: name,
                        type: _type,
                        ip: ip,
                        port: port,
                        username: username,
                        password: _pwd.text,
                        enabled: _enabled,
                      );

                  Navigator.of(context).pop(
                    base.copyWith(
                      name: name,
                      type: _type,
                      ip: ip,
                      port: port,
                      username: username,
                      password: _pwd.text,
                      enabled: _enabled,
                    ),
                  );
                },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

String _formatLastTest(Server s) {
  final at = s.lastTestedAt;
  if (at == null) return '未测试';
  final ok = s.lastTestOk;
  final status = ok == true ? '成功' : (ok == false ? '失败' : '未知');
  return '${_formatDateTime(at)} · $status';
}

String _formatDateTime(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  final y = dt.year.toString().padLeft(4, '0');
  return '$y-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

String? _validateServerInputs({
  required String name,
  required String host,
  required int port,
  required String username,
}) {
  if (name.isEmpty) return '名称不能为空。';
  if (host.isEmpty) return 'IP/域名不能为空。';
  if (!_isValidHost(host)) return 'IP/域名格式不正确。';
  if (port < 1 || port > 65535) return '端口必须在 1~65535。';
  if (username.isEmpty) return '用户名不能为空。';
  return null;
}

bool _isValidHost(String host) {
  final h = host.trim();
  final ipv4 = RegExp(
    r'^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$',
  );
  if (ipv4.hasMatch(h)) return true;
  // Simplified hostname (RFC 1123-ish), allows "localhost".
  final hostname = RegExp(
    r'^(?=.{1,253}$)([A-Za-z0-9-]{1,63}\.)*[A-Za-z0-9-]{1,63}$',
  );
  return hostname.hasMatch(h);
}
