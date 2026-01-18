import 'package:get/get.dart';

import '../../model/playbook_meta.dart';
import '../../model/task.dart';
import '../../services/app_services.dart';
import '../../services/core/app_error.dart';
import '../../services/core/app_logger.dart';
import 'projects_controller.dart';

class PlaybooksController extends GetxController {
  final ProjectsController projects = Get.find<ProjectsController>();

  final RxList<PlaybookMeta> playbooks = <PlaybookMeta>[].obs;
  final RxList<String> bulkSelectedIds = <String>[].obs;
  final RxnString selectedId = RxnString();
  final RxnString currentText = RxnString();
  final RxString editingText = ''.obs;
  final RxBool dirty = false.obs;

  AppLogger get _logger => AppServices.I.logger;

  String? get projectId => projects.selectedId.value;

  bool isBulkSelected(String id) => bulkSelectedIds.contains(id);

  void setBulkSelected(String id, bool selected) {
    if (selected) {
      if (!bulkSelectedIds.contains(id)) {
        bulkSelectedIds.add(id);
      }
    } else {
      bulkSelectedIds.remove(id);
    }
  }

  void clearBulkSelection() => bulkSelectedIds.clear();

  void selectAllForBulk() {
    bulkSelectedIds.assignAll(playbooks.map((p) => p.id));
  }

  @override
  void onInit() {
    super.onInit();
    ever<String?>(projects.selectedId, (_) => load());
    ever<String?>(selectedId, (_) => loadSelectedText());
    load();
  }

  Future<void> load() async {
    final pid = projectId;
    if (pid == null) {
      playbooks.clear();
      selectedId.value = null;
      currentText.value = null;
      editingText.value = '';
      dirty.value = false;
      return;
    }
    final list = await AppServices.I.playbooksStore(pid).listMeta();
    playbooks.assignAll(list);
    bulkSelectedIds.removeWhere((id) => !list.any((p) => p.id == id));
    final current = selectedId.value;
    if (current == null) {
      selectedId.value = list.isEmpty ? null : list.first.id;
    } else {
      if (!list.any((p) => p.id == current)) {
        selectedId.value = list.isEmpty ? null : list.first.id;
      }
    }
  }

  PlaybookMeta? get selected {
    final id = selectedId.value;
    if (id == null) {
      return null;
    }
    return playbooks.firstWhereOrNull((p) => p.id == id);
  }

  Future<void> _assertNotReferencedByTasks(List<String> ids) async {
    final pid = projectId;
    if (pid == null || ids.isEmpty) {
      return;
    }
    final deleting = ids.toSet();
    final tasks = await AppServices.I.tasksStore(pid).list();
    final affected = tasks
        .where((t) => t.playbookId != null && deleting.contains(t.playbookId))
        .toList();
    if (affected.isEmpty) {
      return;
    }

    final byId = {for (final p in playbooks) p.id: p};
    final byPlaybook = <String, List<Task>>{};
    for (final t in affected) {
      (byPlaybook[t.playbookId!] ??= <Task>[]).add(t);
    }

    final buf = StringBuffer();
    var shown = 0;
    const maxShown = 30;
    for (final entry in byPlaybook.entries) {
      final pb = byId[entry.key];
      buf.writeln(
        '- ${pb?.name ?? entry.key.substring(0, 8)} (${entry.key.substring(0, 8)}):',
      );
      for (final t in entry.value) {
        shown++;
        if (shown > maxShown) break;
        buf.writeln('  - ${t.name} (${t.id.substring(0, 8)})');
      }
      if (shown > maxShown) break;
    }
    if (shown > maxShown) {
      buf.writeln('  - ...（仅展示前 $maxShown 条）');
    }

    throw AppException(
      code: AppErrorCode.validation,
      title: 'Playbook 被任务引用',
      message: '以下 Playbook 正在被任务引用，无法删除：\n$buf',
      suggestion: '先修改/删除相关任务（改绑到其他 Playbook）后再删除。',
    );
  }

  Future<void> loadSelectedText() async {
    final pid = projectId;
    final meta = selected;
    if (pid == null || meta == null) {
      currentText.value = null;
      editingText.value = '';
      dirty.value = false;
      return;
    }
    final text = await AppServices.I.playbooksStore(pid).readPlaybookText(meta);
    currentText.value = text;
    editingText.value = text;
    dirty.value = false;
  }

  void updateEditingText(String text) {
    editingText.value = text;
    final base = currentText.value ?? '';
    dirty.value = text != base;
  }

  void discardEdits() {
    final base = currentText.value ?? '';
    editingText.value = base;
    dirty.value = false;
  }

  Future<void> create({
    required String name,
    required String description,
    required String fileName,
  }) async {
    final pid = projectId;
    if (pid == null) {
      return;
    }
    final trimmedName = name.trim();
    final trimmedDesc = description.trim();
    final normalizedFileName = _normalizeFileNameOrThrow(fileName);
    final id = AppServices.I.uuid.v4();
    final now = DateTime.now();
    final store = AppServices.I.playbooksStore(pid);
    final relativePath = 'playbooks/$normalizedFileName';
    final existing = await store.listMeta();
    if (existing.any((p) => p.relativePath == relativePath)) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '文件名冲突',
        message: '该文件名已存在，请换一个文件名。',
        suggestion: '建议使用：deploy.yml / upgrade.yml / xxx.yaml。',
      );
    }
    if (await store.playbookFile(relativePath).exists()) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '文件已存在',
        message: '目标 YAML 文件已存在，请换一个文件名。',
        suggestion: '删除同名文件或使用新文件名创建。',
      );
    }
    final meta = PlaybookMeta(
      id: id,
      name: trimmedName,
      description: trimmedDesc,
      relativePath: relativePath,
      updatedAt: now,
    );
    await store.writePlaybookText(meta, _defaultPlaybookTemplate());
    await store.upsertMeta(meta);
    _logger.info('playbooks.created', data: {'project_id': pid, 'id': id});
    await load();
    selectedId.value = id;
  }

  Future<void> saveSelected({required String text}) async {
    final pid = projectId;
    final meta = selected;
    if (pid == null || meta == null) {
      return;
    }
    final updated = meta.copyWith(updatedAt: DateTime.now());
    final store = AppServices.I.playbooksStore(pid);
    await store.writePlaybookText(updated, text);
    await store.upsertMeta(updated);
    _logger.info(
      'playbooks.saved',
      data: {'project_id': pid, 'id': updated.id},
    );
    await load();
    currentText.value = text;
    editingText.value = text;
    dirty.value = false;
  }

  Future<void> deleteMany(List<String> ids) async {
    final pid = projectId;
    if (pid == null || ids.isEmpty) {
      return;
    }
    await _assertNotReferencedByTasks(ids);
    final store = AppServices.I.playbooksStore(pid);
    for (final id in ids) {
      await store.deletePlaybook(id);
      _logger.info('playbooks.deleted', data: {'project_id': pid, 'id': id});
    }
    clearBulkSelection();
    if (ids.contains(selectedId.value)) {
      selectedId.value = null;
      currentText.value = null;
      editingText.value = '';
      dirty.value = false;
    }
    await load();
  }

  Future<void> deleteSelected() async {
    final pid = projectId;
    final id = selectedId.value;
    if (pid == null || id == null) {
      return;
    }
    await _assertNotReferencedByTasks([id]);
    await AppServices.I.playbooksStore(pid).deletePlaybook(id);
    _logger.info('playbooks.deleted', data: {'project_id': pid, 'id': id});
    bulkSelectedIds.remove(id);
    selectedId.value = null;
    currentText.value = null;
    editingText.value = '';
    dirty.value = false;
    await load();
  }

  static String _normalizeFileNameOrThrow(String raw) {
    var s = raw.trim();
    if (s.isEmpty) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '文件名不能为空',
        message: '请填写 Playbook 文件名。',
        suggestion: '例如：deploy.yml。',
      );
    }
    if (s.contains('/') || s.contains('\\')) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '文件名不合法',
        message: '文件名不能包含路径分隔符。',
        suggestion: '只填写文件名，例如：deploy.yml。',
      );
    }
    if (s.contains('..')) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '文件名不合法',
        message: '文件名不能包含 .. 。',
        suggestion: '使用简单文件名，例如：deploy.yml。',
      );
    }

    final lower = s.toLowerCase();
    if (!(lower.endsWith('.yml') || lower.endsWith('.yaml'))) {
      s = '$s.yml';
    }

    final fileNameRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.(yml|yaml)$');
    if (!fileNameRe.hasMatch(s)) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '文件名不合法',
        message: '仅支持字母/数字/._-，且扩展名为 .yml 或 .yaml。',
        suggestion: '例如：deploy.yml / upgrade.yaml。',
      );
    }
    return s;
  }

  static String _defaultPlaybookTemplate() {
    return [
      '---',
      '- name: Example play',
      '  hosts: all',
      '  gather_facts: false',
      '  tasks: []',
      '',
    ].join('\n');
  }
}
