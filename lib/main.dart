import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'services/app_services.dart';
import 'ui/simple_deploy_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppServices.init();
  runApp(const SimpleDeployApp());
}
