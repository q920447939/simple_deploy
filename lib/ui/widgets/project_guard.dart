import 'package:get/get.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../controllers/nav_controller.dart';
import '../controllers/projects_controller.dart';

class ProjectGuard extends StatelessWidget {
  final Widget child;

  const ProjectGuard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final projects = Get.find<ProjectsController>();
    final nav = Get.find<NavController>();

    return Obx(() {
      if (projects.selectedId.value == null) {
        return Padding(
          padding: EdgeInsets.all(24.r),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('未选择项目').h2(),
              SizedBox(height: 12.h),
              const Text('请先创建/选择一个项目，再管理服务器/Playbook/任务/批次。').muted(),
              SizedBox(height: 16.h),
              PrimaryButton(
                onPressed: () => nav.select(0),
                child: const Text('去选择项目'),
              ),
            ],
          ),
        );
      }
      return child;
    });
  }
}
