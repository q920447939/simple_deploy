import 'package:get/get.dart';
import 'package:flutter/material.dart' as m;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../controllers/nav_controller.dart';
import '../controllers/projects_controller.dart';

class ProjectGuard extends StatelessWidget {
  final Widget child;

  const ProjectGuard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // final projects = Get.find<ProjectsController>(); // Used in GetX builder
    final nav = Get.find<NavController>();
    final projects = Get.find<ProjectsController>();

    return Obx(() {
      if (projects.selectedId.value == null) {
        return Center(
          child: Padding(
            padding: EdgeInsets.all(24.r),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('未选择项目', style: m.Theme.of(context).textTheme.titleLarge),
                SizedBox(height: 12.h),
                Text(
                  '请先创建/选择一个项目，再管理服务器/Playbook/任务/批次。',
                  style: m.Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: m.Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                SizedBox(height: 16.h),
                PrimaryButton(
                  onPressed: () => nav.select(0),
                  child: const Text('去选择项目'),
                ),
              ],
            ),
          ),
        );
      }
      return child;
    });
  }
}
