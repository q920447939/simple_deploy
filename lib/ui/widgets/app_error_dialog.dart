import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../services/core/app_error.dart';

Future<void> showAppErrorDialog(BuildContext context, AppException e) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text('${e.title} (${e.code})'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(e.message),
            if (e.suggestion != null) ...[
              SizedBox(height: 12.h),
              Text('建议：${e.suggestion}').muted(),
            ],
            if (e.cause != null) ...[
              SizedBox(height: 12.h),
              Text('原因：${e.cause}').muted(),
            ],
          ],
        ),
        actions: [
          PrimaryButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      );
    },
  );
}
