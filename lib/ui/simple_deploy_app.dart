import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../services/app_services.dart';
import 'app_shell.dart';

class SimpleDeployApp extends StatelessWidget {
  const SimpleDeployApp({super.key});

  @override
  Widget build(BuildContext context) {
    final paths = AppServices.I.paths;

    return ScreenUtilInit(
      designSize: const Size(1920, 1080),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, child) {
        return ShadcnApp(
          title: 'Simple Deploy',
          theme: ThemeData(
            colorScheme: LegacyColorSchemes.darkZinc(),
            radius: 0.7,
          ),
          home: AppShell(subtitle: Text(paths.rootDir.path)),
        );
      },
    );
  }
}
