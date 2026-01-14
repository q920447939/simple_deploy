import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_deploy/storage/atomic_file.dart';

void main() {
  test('AtomicFile.writeJson writes readable JSON', () async {
    final dir = await Directory.systemTemp.createTemp('simple_deploy_test_');
    try {
      final file = File('${dir.path}/data.json');
      await AtomicFile.writeJson(file, {'a': 1});

      final obj = await AtomicFile.readJsonOrNull(file);
      expect(obj, isA<Map>());
      expect((obj as Map)['a'], 1);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
