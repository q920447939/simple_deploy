import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'services/app_services.dart';
import 'ui/controllers/nav_controller.dart';
import 'ui/controllers/projects_controller.dart';
import 'ui/simple_deploy_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppServices.init();
  Get.put(NavController(), permanent: true);
  Get.put(ProjectsController(), permanent: true);
  runApp(const SimpleDeployApp());
}
