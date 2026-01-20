import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:get/get.dart';

import '../../model/batch.dart';
import '../../model/run.dart';
import '../../model/run_inputs.dart';
import '../../model/server.dart';
import '../../model/task.dart';
import '../../model/upload_progress.dart';
import '../../services/app_services.dart';
import '../../services/core/app_error.dart';
import '../../services/core/app_logger.dart';
import '../../storage/atomic_file.dart';
import '../../storage/batch_lock.dart';
import 'projects_controller.dart';

class BatchesController extends GetxController {
  final ProjectsController projects = Get.find<ProjectsController>();

  final RxList<Batch> batches = <Batch>[].obs;
  final RxnString selectedBatchId = RxnString();
  final RxString filterStatus = 'all'.obs; // all|paused|running|ended

  final RxList<Server> servers = <Server>[].obs;
  final RxList<Task> tasks = <Task>[].obs;

  final RxList<Run> runs = <Run>[].obs;
  final RxnString selectedRunId = RxnString();
  final RxInt selectedTaskIndex = 0.obs;
  final RxList<String> bulkSelectedRunIds = <String>[].obs;
  final RxBool userPinnedRun = false.obs;
  final RxBool userPinnedTask = false.obs;

  final RxMap<String, Run> lastRunByBatchId = <String, Run>{}.obs;

  final RxList<String> currentLogLines = <String>[].obs;
  final RxInt logMaxLines = 2000.obs;
  final RxnInt currentLogFileSize = RxnInt();
  final Rxn<UploadProgress> uploadProgress = Rxn<UploadProgress>();

  Timer? _poller;
  bool _ticking = false;
  int _tickCount = 0;

  int? _lastRenderedLogBytes;
  int _lastRenderedLogMaxLines = 0;
  String? _lastRenderedRunId;
  int? _lastRenderedTaskIndex;
  String? _lastBatchId;
  String? _lastUploadProgressRunId;
  DateTime? _lastUploadProgressMtime;

  AppLogger get _logger => AppServices.I.logger;

  String? get projectId => projects.selectedId.value;

  bool isRunBulkSelected(String id) => bulkSelectedRunIds.contains(id);

  void setRunBulkSelected(String id, bool selected) {
    if (selected) {
      if (!bulkSelectedRunIds.contains(id)) {
        bulkSelectedRunIds.add(id);
      }
    } else {
      bulkSelectedRunIds.remove(id);
    }
  }

  void clearRunBulkSelection() => bulkSelectedRunIds.clear();

  void selectAllRunsForBulk() {
    bulkSelectedRunIds.assignAll(runs.map((r) => r.id));
  }

  void userSelectRun(String runId) {
    userPinnedRun.value = true;
    userPinnedTask.value = false;
    selectedRunId.value = runId;
  }

  void userSelectTask(int index) {
    userPinnedRun.value = true;
    userPinnedTask.value = true;
    selectedTaskIndex.value = index;
  }

  @override
  void onInit() {
    super.onInit();
    ever<String?>(projects.selectedId, (_) => loadAll());
    ever<String?>(selectedBatchId, (_) => loadRuns());
    ever<String?>(selectedRunId, (_) {
      _resetLogView();
      // ignore: unawaited_futures
      refreshLog();
      // ignore: unawaited_futures
      refreshUploadProgress();
    });
    ever<int>(selectedTaskIndex, (_) {
      _resetLogView();
      // ignore: unawaited_futures
      refreshLog();
    });
    loadAll();
    _poller = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void onClose() {
    _poller?.cancel();
    super.onClose();
  }

  Future<void> loadAll() async {
    final pid = projectId;
    if (pid == null) {
      batches.clear();
      servers.clear();
      tasks.clear();
      runs.clear();
      selectedBatchId.value = null;
      selectedRunId.value = null;
      bulkSelectedRunIds.clear();
      userPinnedRun.value = false;
      userPinnedTask.value = false;
      _lastBatchId = null;
      currentLogLines.clear();
      lastRunByBatchId.clear();
      uploadProgress.value = null;
      _lastUploadProgressRunId = null;
      _lastUploadProgressMtime = null;
      return;
    }
    final svc = AppServices.I;
    final store = svc.batchesStore(pid);
    final list = await store.list();
    batches.assignAll(list);
    servers.assignAll(await svc.serversStore(pid).list());
    tasks.assignAll(await svc.tasksStore(pid).list());
    final current = selectedBatchId.value;
    if (current == null) {
      selectedBatchId.value = list.isEmpty ? null : list.first.id;
    } else if (!list.any((b) => b.id == current)) {
      selectedBatchId.value = list.isEmpty ? null : list.first.id;
    }

    await _loadLastRuns(pid, list);
  }

  List<Batch> get visibleBatches {
    final f = filterStatus.value;
    if (f == 'all') return batches.toList(growable: false);
    return batches.where((b) => b.status == f).toList(growable: false);
  }

  Batch? get selectedBatch {
    final id = selectedBatchId.value;
    if (id == null) return null;
    return batches.firstWhereOrNull((b) => b.id == id);
  }

  Future<void> loadRuns() async {
    final pid = projectId;
    final batch = selectedBatch;
    if (pid == null || batch == null) {
      runs.clear();
      selectedRunId.value = null;
      selectedTaskIndex.value = 0;
      bulkSelectedRunIds.clear();
      userPinnedRun.value = false;
      userPinnedTask.value = false;
      currentLogLines.clear();
      uploadProgress.value = null;
      _lastUploadProgressRunId = null;
      _lastUploadProgressMtime = null;
      _lastBatchId = null;
      return;
    }
    if (_lastBatchId != batch.id) {
      _lastBatchId = batch.id;
      selectedRunId.value = null;
      selectedTaskIndex.value = 0;
      bulkSelectedRunIds.clear();
      userPinnedRun.value = false;
      userPinnedTask.value = false;
      uploadProgress.value = null;
      _lastUploadProgressRunId = null;
      _lastUploadProgressMtime = null;
    }
    final list = await AppServices.I.runsStore(pid).listByBatch(batch.id);
    runs.assignAll(list);
    bulkSelectedRunIds.removeWhere((id) => !list.any((r) => r.id == id));
    if (selectedRunId.value != null &&
        !list.any((r) => r.id == selectedRunId.value)) {
      selectedRunId.value = null;
      userPinnedRun.value = false;
      userPinnedTask.value = false;
    }

    if (list.isNotEmpty) {
      final latest = list.first;
      // 运行中：默认跟随最新 Run；若用户手动选择则保持不变。
      if (!userPinnedRun.value) {
        if (latest.status == RunStatus.running) {
          selectedRunId.value = latest.id;
        } else {
          selectedRunId.value ??= latest.id;
        }
      }
      lastRunByBatchId[batch.id] = latest;
    } else {
      selectedRunId.value = null;
      selectedTaskIndex.value = 0;
      userPinnedRun.value = false;
      userPinnedTask.value = false;
      currentLogLines.clear();
      uploadProgress.value = null;
      _lastUploadProgressRunId = null;
      _lastUploadProgressMtime = null;
      return;
    }

    final run = selectedRun;
    if (!userPinnedTask.value && run != null && run.taskResults.isNotEmpty) {
      if (run.status == RunStatus.running) {
        final idx = run.taskResults.indexWhere(
          (t) => t.status == TaskExecStatus.running,
        );
        if (idx >= 0) {
          selectedTaskIndex.value = idx;
        }
      } else {
        selectedTaskIndex.value = run.taskResults.length - 1;
      }
    }
    await refreshLog();
    await refreshUploadProgress();
  }

  Run? get selectedRun {
    final id = selectedRunId.value;
    if (id == null) return null;
    return runs.firstWhereOrNull((r) => r.id == id);
  }

  Server? serverById(String id) => servers.firstWhereOrNull((s) => s.id == id);

  Task? taskById(String id) => tasks.firstWhereOrNull((t) => t.id == id);

  Future<void> upsertBatch(Batch batch) async {
    final pid = projectId;
    if (pid == null) return;
    final existing = await AppServices.I.batchesStore(pid).getById(batch.id);
    if (existing != null && existing.status != BatchStatus.paused) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '批次不可编辑',
        message: '仅 paused 状态允许编辑批次配置。',
        suggestion: '先将批次重置为 paused 后再编辑。',
      );
    }
    await AppServices.I.batchesStore(pid).upsert(batch);
    _logger.info('batches.upsert', data: {'project_id': pid, 'id': batch.id});
    await loadAll();
    selectedBatchId.value = batch.id;
  }

  Future<void> deleteSelectedBatch() async {
    final pid = projectId;
    final id = selectedBatchId.value;
    if (pid == null || id == null) return;
    await AppServices.I.batchesStore(pid).delete(id);
    _logger.info('batches.deleted', data: {'project_id': pid, 'id': id});
    selectedBatchId.value = null;
    await loadAll();
  }

  Future<void> resetToPaused() async {
    final pid = projectId;
    final batch = selectedBatch;
    if (pid == null || batch == null) return;
    if (batch.status != BatchStatus.ended) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '状态不允许',
        message: '仅 ended 状态允许重置为 paused。',
        suggestion: '如批次仍在 running，请使用“强制解锁/重置”。',
      );
    }
    final pp = AppServices.I.projectPaths(pid);
    await BatchLock.release(pp.batchLockFile(batch.id));
    final updated = batch.copyWith(
      status: BatchStatus.paused,
      updatedAt: DateTime.now(),
    );
    await AppServices.I.batchesStore(pid).upsert(updated);
    _logger.info(
      'batches.reset_to_paused',
      data: {'project_id': pid, 'id': batch.id},
    );
    await loadAll();
  }

  Future<void> forceUnlockAndReset() async {
    final pid = projectId;
    final batch = selectedBatch;
    if (pid == null || batch == null) return;
    final pp = AppServices.I.projectPaths(pid);
    await BatchLock.release(pp.batchLockFile(batch.id));
    final updated = batch.copyWith(
      status: BatchStatus.paused,
      updatedAt: DateTime.now(),
    );
    await AppServices.I.batchesStore(pid).upsert(updated);
    _logger.info(
      'batches.force_unlock_reset',
      data: {'project_id': pid, 'id': batch.id},
    );
    await loadAll();
  }

  Future<BatchLockInfo?> readLockInfo() async {
    final pid = projectId;
    final batch = selectedBatch;
    if (pid == null || batch == null) return null;
    final pp = AppServices.I.projectPaths(pid);
    return BatchLock.readOrNull(pp.batchLockFile(batch.id));
  }

  Future<void> refreshLog() async {
    final pid = projectId;
    final run = selectedRun;
    if (pid == null || run == null) {
      currentLogLines.clear();
      currentLogFileSize.value = null;
      return;
    }
    final pp = AppServices.I.projectPaths(pid);
    final file = pp.taskLogFile(run.id, selectedTaskIndex.value);
    final exists = await file.exists();
    final len = exists ? await file.length() : null;
    currentLogFileSize.value = len;

    final currentRunId = run.id;
    final currentTaskIndex = selectedTaskIndex.value;
    final currentMaxLines = logMaxLines.value;
    if (_lastRenderedRunId == currentRunId &&
        _lastRenderedTaskIndex == currentTaskIndex &&
        _lastRenderedLogMaxLines == currentMaxLines &&
        _lastRenderedLogBytes == len) {
      return;
    }

    final raw = await _readTailLines(
      file,
      maxLines: currentMaxLines,
      maxBytes: _maxBytesForLines(currentMaxLines),
    );
    final lines = const LineSplitter().convert(raw);
    currentLogLines.assignAll(_filterLogLines(lines));

    _lastRenderedRunId = currentRunId;
    _lastRenderedTaskIndex = currentTaskIndex;
    _lastRenderedLogMaxLines = currentMaxLines;
    _lastRenderedLogBytes = len;
  }

  Future<void> refreshUploadProgress() async {
    final pid = projectId;
    final run = selectedRun;
    if (pid == null || run == null) {
      uploadProgress.value = null;
      _lastUploadProgressRunId = null;
      _lastUploadProgressMtime = null;
      return;
    }

    final pp = AppServices.I.projectPaths(pid);
    final file = pp.runUploadProgressFile(run.id);
    final exists = await file.exists();
    if (!exists) {
      uploadProgress.value = null;
      _lastUploadProgressRunId = run.id;
      _lastUploadProgressMtime = null;
      return;
    }

    final stat = await file.stat();
    if (_lastUploadProgressRunId == run.id &&
        _lastUploadProgressMtime != null &&
        stat.modified.isAtSameMomentAs(_lastUploadProgressMtime!)) {
      return;
    }

    final raw = await AtomicFile.readJsonOrNull(file);
    if (raw is Map) {
      uploadProgress.value = UploadProgress.fromJson(
        raw.cast<String, Object?>(),
      );
    } else {
      uploadProgress.value = null;
    }
    _lastUploadProgressRunId = run.id;
    _lastUploadProgressMtime = stat.modified;
  }

  Future<void> loadMoreLog() async {
    logMaxLines.value = (logMaxLines.value + 2000).clamp(2000, 20000);
    await refreshLog();
  }

  Future<void> loadFullLog() async {
    logMaxLines.value = 1000000; // Large enough for most cases
    await refreshLog();
  }

  void _resetLogView() {
    logMaxLines.value = 2000;
    currentLogFileSize.value = null;
    _lastRenderedLogBytes = null;
    _lastRenderedLogMaxLines = 0;
    _lastRenderedRunId = null;
    _lastRenderedTaskIndex = null;
  }

  void _tick() {
    // ignore: unawaited_futures
    _tickAsync();
  }

  Future<void> _tickAsync() async {
    if (_ticking) return;
    _ticking = true;
    try {
      // 始终轮询 runs：这样即使上一次选中的是 ended，也能自动发现新 Run。
      await loadRuns();

      await refreshLog();
      await refreshUploadProgress();

      // 批次列表轮询频率低一点，避免 IO 过于频繁。
      _tickCount++;
      if (_tickCount % 2 == 0) {
        await loadAll();
      }
    } finally {
      _ticking = false;
    }
  }

  static int _maxBytesForLines(int maxLines) {
    // 粗略估算：每行平均 512B，且至少读取 64KB；上限 128MB (was 8MB)
    // Supports full logs better.
    final bytes = maxLines * 512;
    if (bytes < 64 * 1024) return 64 * 1024;
    if (bytes > 128 * 1024 * 1024) return 128 * 1024 * 1024;
    return bytes;
  }

  static Future<String> _readTailLines(
    File file, {
    required int maxLines,
    required int maxBytes,
  }) async {
    if (!await file.exists()) {
      return '';
    }
    final raf = await file.open();
    try {
      final len = await raf.length();

      // If requesting full log or log is small enough, read from start
      if (maxLines >= 100000 || len < maxBytes) {
        await raf.setPosition(0);
        final all = await raf.read(len);
        return utf8.decode(all, allowMalformed: true);
      }

      var pos = len;

      final chunks = <List<int>>[];
      var bytesRead = 0;
      var newlines = 0;

      while (pos > 0 && bytesRead < maxBytes && newlines <= maxLines) {
        final chunkSize = (pos >= 64 * 1024) ? 64 * 1024 : pos.toInt();
        pos -= chunkSize;
        await raf.setPosition(pos);
        final chunk = await raf.read(chunkSize);
        bytesRead += chunk.length;
        for (final b in chunk) {
          if (b == 0x0A) newlines++;
        }
        chunks.add(chunk);
      }

      final builder = BytesBuilder(copy: false);
      for (var i = chunks.length - 1; i >= 0; i--) {
        builder.add(chunks[i]);
      }
      final all = builder.takeBytes();

      var start = 0;
      var seen = 0;
      for (var i = all.length - 1; i >= 0; i--) {
        if (all[i] == 0x0A) {
          seen++;
          if (seen == maxLines + 1) {
            start = i + 1;
            break;
          }
        }
      }

      return utf8.decode(all.sublist(start), allowMalformed: true);
    } finally {
      await raf.close();
    }
  }

  static List<String> _filterLogLines(List<String> lines) {
    final out = <String>[];
    for (final line in lines) {
      if (_isNoisyLine(line)) continue;
      out.add(line);
    }
    return out;
  }

  static bool _isNoisyLine(String line) {
    final trimmed = line.trimRight();
    if (trimmed.contains('zip_data')) return true;
    if (trimmed.length > 5000 && _looksLikeBase64(trimmed)) return true;
    return false;
  }

  static bool _looksLikeBase64(String text) {
    if (text.length < 200) return false;
    final base64Re = RegExp(r'^[A-Za-z0-9+/=]+$');
    return base64Re.hasMatch(text);
  }

  Future<void> startRunWithInputs(
    RunInputs inputs, {
    bool allowUnsupportedControlOsAutoInstall = false,
  }) async {
    final pid = projectId;
    final batch = selectedBatch;
    if (pid == null || batch == null) return;
    if (batch.status != BatchStatus.paused) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '批次不可执行',
        message: '仅 paused 状态允许执行。',
        suggestion: '若已 ended，请先“重置为暂停”；若仍 running，请等待或使用“强制解锁/重置”。',
      );
    }

    await _writeLastInputs(batch.id, inputs);

    // Fire-and-forget: 让 UI 可以立即轮询展示进度/日志。
    // 错误会落盘到 runs/<run_id>.json，并写入 app_logs。
    // ignore: unawaited_futures
    AppServices.I.runEngine
        .startBatchRun(
          projectId: pid,
          batch: batch,
          inputs: inputs,
          allowUnsupportedControlOsAutoInstall:
              allowUnsupportedControlOsAutoInstall,
        )
        .catchError((e, st) {
          _logger.error(
            'run.background.failed',
            data: {
              'project_id': pid,
              'batch_id': batch.id,
              'error': e.toString(),
            },
          );
        });

    await Future<void>.delayed(const Duration(milliseconds: 200));
    await loadAll();
    await loadRuns();
  }

  Future<RunInputs?> readLastInputs(String batchId) async {
    final pid = projectId;
    if (pid == null) return null;
    final pp = AppServices.I.projectPaths(pid);
    final raw = await AtomicFile.readJsonOrNull(
      pp.batchLastInputsFile(batchId),
    );
    if (raw is Map) {
      final parsed = RunInputs.fromJson(raw.cast<String, Object?>());
      if (parsed.fileInputs.isNotEmpty || parsed.vars.isNotEmpty) {
        return parsed;
      }
    }
    return null;
  }

  Future<void> _writeLastInputs(String batchId, RunInputs inputs) async {
    final pid = projectId;
    if (pid == null) return;
    final pp = AppServices.I.projectPaths(pid);
    await AtomicFile.writeJson(
      pp.batchLastInputsFile(batchId),
      inputs.toJson(),
    );
  }

  Future<void> _loadLastRuns(String projectId, List<Batch> list) async {
    final store = AppServices.I.runsStore(projectId);
    final map = <String, Run>{};
    for (final b in list) {
      final rid = b.lastRunId;
      if (rid == null) continue;
      final r = await store.getById(rid);
      if (r == null) continue;
      map[b.id] = r;
    }
    lastRunByBatchId.assignAll(map);
  }

  Future<void> deleteRuns(List<String> runIds) async {
    final pid = projectId;
    if (pid == null || runIds.isEmpty) return;
    await AppServices.I.runsStore(pid).deleteMany(runIds);
    _logger.info(
      'runs.deleted',
      data: {'project_id': pid, 'count': runIds.length},
    );
    bulkSelectedRunIds.removeWhere(runIds.contains);
    if (runIds.contains(selectedRunId.value)) {
      selectedRunId.value = null;
      selectedTaskIndex.value = 0;
      userPinnedRun.value = false;
      userPinnedTask.value = false;
      _resetLogView();
      uploadProgress.value = null;
      _lastUploadProgressRunId = null;
      _lastUploadProgressMtime = null;
    }
    await loadRuns();
  }
}
