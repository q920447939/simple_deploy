import 'package:flutter/material.dart' as m;
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
          title: Obx(() {
            final p = projects.selected;
            if (p == null) {
              return const Text('未选择项目');
            }
            return Text(p.name);
          }),
          subtitle: Obx(() {
            final p = projects.selected;
            if (p == null) {
              return subtitle ?? const SizedBox.shrink();
            }
            return Text(p.id.substring(0, 8)).mono();
          }),
          trailing: [
            OutlineButton(
              onPressed: () async {
                if (nav.index.value == 0) return;
                final ok = await confirmLeavePlaybooksIfNeeded();
                if (!ok) return;
                nav.select(0);
              },
              child: const Text('切换项目'),
            ),
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
            width: 180,
            child: Obx(() {
              m.Widget tile(int index, String label, IconData icon) {
                final selected = nav.index.value == index;
                return m.ListTile(
                  dense: true,
                  selected: selected,
                  leading: Icon(icon, size: 18),
                  title: selected ? Text(label) : Text(label).muted(),
                  onTap: () async {
                    if (index == nav.index.value) return;
                    final ok = await confirmLeavePlaybooksIfNeeded();
                    if (!ok) return;
                    nav.select(index);
                  },
                );
              }

              return m.ListView(
                padding: const m.EdgeInsets.symmetric(vertical: 8),
                children: [
                  tile(0, '项目', Icons.folder),
                  tile(1, '服务器', Icons.dns),
                  tile(2, 'Playbook', Icons.description),
                  tile(3, '任务', Icons.checklist),
                  tile(4, '批次', Icons.playlist_play),
                ],
              );
            }),
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
