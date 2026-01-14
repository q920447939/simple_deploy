import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves offline installer files bundled with the Flutter desktop app.
///
/// In release bundles, assets live under:
///   exe_dir/data/flutter_assets/assetPath
///
/// In dev / tests, we fall back to `Directory.current`, which should be the
/// repository root.
class OfflineAssets {
  final Directory _root;

  const OfflineAssets._(this._root);

  static OfflineAssets locate() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = <Directory>[
      Directory(p.join(exeDir.path, 'data', 'flutter_assets')),
      Directory(p.join(exeDir.path, 'flutter_assets')),
      Directory(p.join(Directory.current.path, 'data', 'flutter_assets')),
    ];
    for (final d in candidates) {
      if (d.existsSync()) {
        return OfflineAssets._(d);
      }
    }
    return OfflineAssets._(Directory.current);
  }

  File file(String assetPath) => File(p.join(_root.path, assetPath));
}
