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
    // Inject controller
    final controller = Get.put(ServersController());

    return ProjectGuard(
      child: Scaffold(
        child: Row(
          children: [
            // Sidebar: 320px fixed
            SizedBox(width: 320.w, child: const _ServerSidebar()),
            const VerticalDivider(width: 1),
            // Main Content
            Expanded(
              child: Obx(() {
                final s = controller.selected;
                if (s == null) {
                  return const Center(child: Text('请选择一个服务器查看详情'));
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

class _ServerSidebar extends StatelessWidget {
  const _ServerSidebar();

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ServersController>();

    Widget toggle(String type, String label) {
      return Obx(() {
        final selected = controller.filterType.value == type;
        return Expanded(
          child: GestureDetector(
            onTap: () => controller.filterType.value = type,
            behavior: HitTestBehavior.opaque,
            child: Container(
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(vertical: 6.h),
              decoration: BoxDecoration(
                color: selected
                    ? m.Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.1)
                    : null,
                border: Border(
                  bottom: BorderSide(
                    color: selected
                        ? m.Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: selected
                      ? m.Theme.of(context).colorScheme.primary
                      : m.Theme.of(context).colorScheme.onSurface,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.normal,
                  fontSize: 13.sp,
                ),
              ),
            ),
          ),
        );
      });
    }

    return Column(
      children: [
        // Sidebar Header
        Container(
          height: 50.h,
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: m.Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '服务器',
                  style: m.Theme.of(context).textTheme.titleMedium,
                ),
              ),
              GhostButton(
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
                child: const Icon(Icons.add, size: 18),
              ),
            ],
          ),
        ),
        // Filter Tabs
        Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: m.Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              toggle(ServerType.control, '控制端'),
              const SizedBox(height: 20, child: VerticalDivider(width: 1)),
              toggle(ServerType.managed, '被控端'),
            ],
          ),
        ),
        // List
        Expanded(
          child: Obx(() {
            final items = controller.filtered.toList();
            if (items.isEmpty) {
              return const Center(child: Text('暂无服务器'));
            }
            return m.ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final s = items[i];
                final selected = controller.selectedId.value == s.id;
                return m.Material(
                  color: selected
                      ? m.Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.05)
                      : Colors.transparent,
                  child: m.InkWell(
                    onTap: () => controller.selectedId.value = s.id,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12.w,
                        vertical: 10.h,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  s.name,
                                  style: m.Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w500,
                                        color: selected
                                            ? m.Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : null,
                                      ),
                                ),
                              ),
                              if (!s.enabled)
                                Icon(
                                  Icons.block,
                                  size: 14,
                                  color: m.Theme.of(context).colorScheme.error,
                                ),
                            ],
                          ),
                          SizedBox(height: 4.h),
                          Text(
                            '${s.ip}:${s.port}  ·  ${s.username}',
                            style: m.Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: m.Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.6),
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          }),
        ),
      ],
    );
  }
}

class _ServerDetail extends StatelessWidget {
  final Server server;

  const _ServerDetail({required this.server});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ServersController>();

    final labelStyle = TextStyle(
      color: m.Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
      fontSize: 13.sp,
    );
    final valueStyle = TextStyle(
      fontFamily: 'GeistMono', // Ensure monospaced for values
      fontSize: 13.sp,
    );

    Widget infoRow(String label, String value) {
      return Padding(
        padding: EdgeInsets.only(bottom: 8.h),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 80.w,
              child: Text(label, style: labelStyle),
            ),
            Expanded(child: SelectableText(value, style: valueStyle)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Detail Header
        Container(
          height: 50.h,
          padding: EdgeInsets.symmetric(horizontal: 24.w),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: m.Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  server.name,
                  style: m.Theme.of(context).textTheme.titleLarge,
                ),
              ),
              GhostButton(
                density: ButtonDensity.icon,
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
                child: const Icon(Icons.edit, size: 16),
              ),
              SizedBox(width: 8.w),
              DestructiveButton(
                density: ButtonDensity.icon,
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
                child: const Icon(Icons.delete_outline, size: 16),
              ),
            ],
          ),
        ),
        // Content
        Expanded(
          child: m.SingleChildScrollView(
            padding: EdgeInsets.all(24.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('基本信息', style: m.Theme.of(context).textTheme.titleMedium),
                SizedBox(height: 16.h),
                infoRow('ID', server.id),
                infoRow('类型', server.type),
                infoRow('地址', '${server.ip}:${server.port}'),
                infoRow('用户名', server.username),
                infoRow('启用状态', server.enabled ? '已启用' : '已禁用'),
                infoRow('Last Test', _formatLastTest(server)),
                if ((server.lastTestMessage ?? '').trim().isNotEmpty)
                  infoRow('Test Msg', server.lastTestMessage!),

                SizedBox(height: 32.h),
                Text('快速操作', style: m.Theme.of(context).textTheme.titleMedium),
                SizedBox(height: 16.h),
                Text('注意：v1 简单部署工具明文保存密码，仅适用于内网/单人/受控环境。', style: labelStyle),
                SizedBox(height: 16.h),
                Obx(() {
                  final isTesting = controller.testingId.value == server.id;
                  final mode = controller.testingMode.value;

                  final label = server.type == ServerType.control
                      ? '控制端连接测试'
                      : 'SSH 登录测试';

                  Widget spinner() => const SizedBox(
                    width: 14,
                    height: 14,
                    child: m.CircularProgressIndicator(strokeWidth: 2),
                  );

                  return Wrap(
                    spacing: 12.w,
                    runSpacing: 12.h,
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
                                      content: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxHeight: 0.6.sh,
                                          maxWidth: 640.w,
                                        ),
                                        child: m.SingleChildScrollView(
                                          child: SelectableText(
                                            r.exitCode == 0
                                                ? (r.stdout.trim().isEmpty
                                                      ? '（执行成功，无输出）'
                                                      : r.stdout.trim())
                                                : (r.stderr.trim().isEmpty
                                                      ? r.stdout.trim()
                                                      : r.stderr.trim()),
                                            style: valueStyle,
                                          ),
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
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isTesting && mode == 'ssh') ...[
                              spinner(),
                              const SizedBox(width: 8),
                            ] else
                              const Icon(Icons.terminal, size: 16),
                            if (!isTesting || mode != 'ssh')
                              const SizedBox(width: 8),
                            Text(isTesting && mode == 'ssh' ? '测试中...' : label),
                          ],
                        ),
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
                                        title: Text(r.ok ? '环境自检通过' : '环境自检失败'),
                                        content: ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxHeight: 0.6.sh,
                                            maxWidth: 760.w,
                                          ),
                                          child: m.SingleChildScrollView(
                                            child: SelectableText(
                                              r.details,
                                              style: valueStyle,
                                            ),
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
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isTesting && mode == 'selfcheck') ...[
                                spinner(),
                                const SizedBox(width: 8),
                              ] else
                                const Icon(Icons.checklist, size: 16),
                              if (!isTesting || mode != 'selfcheck')
                                const SizedBox(width: 8),
                              Text(
                                isTesting && mode == 'selfcheck'
                                    ? '自检中...'
                                    : '环境自检',
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                }),
              ],
            ),
          ),
        ),
      ],
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
  String _controlOsHint = ControlOsHint.auto;
  bool _enabled = true;
  bool _obscurePwd = true;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _type = i?.type ?? widget.defaultType;
    _enabled = i?.enabled ?? true;
    _controlOsHint = i?.controlOsHint ?? ControlOsHint.auto;
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
            if (_type == ServerType.control) ...[
              SizedBox(height: 12.h),
              m.DropdownButtonFormField<String>(
                key: ValueKey('os_hint_$_controlOsHint'),
                initialValue: _controlOsHint,
                decoration: const m.InputDecoration(
                  labelText: '控制端系统类型（用于自动安装判定）',
                ),
                items: const [
                  m.DropdownMenuItem(
                    value: ControlOsHint.auto,
                    child: Text('自动识别（推荐）'),
                  ),
                  m.DropdownMenuItem(
                    value: ControlOsHint.ubuntu24Plus,
                    child: Text('Ubuntu 24+'),
                  ),
                  m.DropdownMenuItem(
                    value: ControlOsHint.kylinV10Sp3,
                    child: Text('银河麒麟 V10 SP3'),
                  ),
                  m.DropdownMenuItem(
                    value: ControlOsHint.other,
                    child: Text('其他/不确定（执行时可强制安装）'),
                  ),
                ],
                onChanged: (v) =>
                    setState(() => _controlOsHint = v ?? _controlOsHint),
              ),
            ],
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
                        controlOsHint: _type == ServerType.control
                            ? _controlOsHint
                            : ControlOsHint.auto,
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
                      controlOsHint: _type == ServerType.control
                          ? _controlOsHint
                          : ControlOsHint.auto,
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
