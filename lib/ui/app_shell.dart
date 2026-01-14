import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'controllers/nav_controller.dart';
import 'controllers/playbooks_controller.dart';
import 'controllers/projects_controller.dart';
import 'pages/batches/batches_page.dart';
import 'pages/playbooks/playbooks_page.dart';
import 'pages/projects/projects_page.dart';
import 'pages/servers/servers_page.dart';
import 'pages/tasks/tasks_page.dart';
import 'widgets/about_dialog.dart';
import 'widgets/confirm_dialogs.dart';

class AppShell extends StatelessWidget {
  final Widget? subtitle;

  AppShell({super.key, this.subtitle});

  final NavController nav = Get.put(NavController(), permanent: true);
  final ProjectsController projects = Get.put(
    ProjectsController(),
    permanent: true,
  );

  NavigationItem _item(String label, IconData icon) {
    return NavigationItem(label: Text(label), child: Icon(icon));
  }

  @override
  Widget build(BuildContext context) {
    Future<bool> confirmLeavePlaybooksIfNeeded() async {
      if (nav.index.value != 2) {
        return true;
      }
      if (!Get.isRegistered<PlaybooksController>()) {
        return true;
      }
      final pc = Get.find<PlaybooksController>();
      if (!pc.dirty.value) {
        return true;
      }
      final ok = await confirmDiscardChanges(
        context,
        message: '当前 Playbook 有未保存修改，离开页面将丢失这些修改。',
        discardLabel: '丢弃并离开',
      );
      if (!ok) return false;
      pc.discardEdits();
      return true;
    }

    return Scaffold(
      headers: [
        AppBar(
          title: const Text('Simple Deploy'),
          subtitle: Obx(() {
            final p = projects.selected;
            if (p == null) {
              return subtitle ?? const SizedBox.shrink();
            }
            return Text('${p.name}  ·  ${p.id.substring(0, 8)}');
          }),
          trailing: [
            GhostButton(
              density: ButtonDensity.icon,
              onPressed: () {
                // ignore: unawaited_futures
                showAboutAndHelpDialog(context);
              },
              child: const Icon(Icons.help_outline),
            ),
          ],
        ),
        const Divider(),
      ],
      child: Row(
        children: [
          SizedBox(
            width: 220,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Obx(() {
                    final p = projects.selected;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('当前项目').muted(),
                            const SizedBox(height: 6),
                            Text(p?.name ?? '未选择').p(),
                            if (p != null) ...[
                              const SizedBox(height: 4),
                              Text(p.id.substring(0, 8)).mono(),
                            ],
                            const SizedBox(height: 10),
                            PrimaryButton(
                              onPressed: () async {
                                if (nav.index.value == 0) return;
                                final ok =
                                    await confirmLeavePlaybooksIfNeeded();
                                if (!ok) return;
                                nav.select(0);
                              },
                              child: const Text('切换项目'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
                Expanded(
                  child: Obx(
                    () => NavigationRail(
                      index: nav.index.value,
                      onSelected: (i) async {
                        if (i == nav.index.value) return;
                        final ok = await confirmLeavePlaybooksIfNeeded();
                        if (!ok) return;
                        nav.select(i);
                      },
                      children: [
                        _item('项目', Icons.folder),
                        _item('服务器', Icons.dns),
                        _item('Playbook', Icons.description),
                        _item('任务', Icons.checklist),
                        _item('批次', Icons.playlist_play),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(),
          Expanded(
            child: Obx(() {
              return switch (nav.index.value) {
                0 => const ProjectsPage(),
                1 => const ServersPage(),
                2 => const PlaybooksPage(),
                3 => const TasksPage(),
                4 => const BatchesPage(),
                _ => const SizedBox.shrink(),
              };
            }),
          ),
        ],
      ),
    );
  }
}
