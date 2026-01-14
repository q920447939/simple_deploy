import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class AppLogger {
  final Directory logsDir;
  final String filePrefix;
  final IOSink _sink;

  Future<void> _writeChain = Future<void>.value();

  AppLogger._({
    required this.logsDir,
    required this.filePrefix,
    required IOSink sink,
  }) : _sink = sink;

  static Future<AppLogger> create({
    required Directory logsDir,
    required String filePrefix,
  }) async {
    await logsDir.create(recursive: true);
    final filename = '$filePrefix-${_yyyymmdd(DateTime.now())}.log';
    final file = File(p.join(logsDir.path, filename));
    final sink = file.openWrite(mode: FileMode.append);
    return AppLogger._(logsDir: logsDir, filePrefix: filePrefix, sink: sink);
  }

  void info(String event, {Map<String, Object?>? data}) =>
      _log('INFO', event, data);
  void warn(String event, {Map<String, Object?>? data}) =>
      _log('WARN', event, data);
  void error(String event, {Map<String, Object?>? data}) =>
      _log('ERROR', event, data);

  void _log(String level, String event, Map<String, Object?>? data) {
    final record = <String, Object?>{
      'ts': DateTime.now().toIso8601String(),
      'level': level,
      'event': event,
      if (data != null) 'data': data,
    };
    final line = jsonEncode(record);
    _writeChain = _writeChain.then((_) async {
      _sink.writeln(line);
      await _sink.flush();
    });
  }

  Future<void> close() async {
    await _writeChain;
    await _sink.flush();
    await _sink.close();
  }

  static String _yyyymmdd(DateTime dt) {
    String two(int x) => x >= 10 ? '$x' : '0$x';
    return '${dt.year}${two(dt.month)}${two(dt.day)}';
  }
}
