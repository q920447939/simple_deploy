import 'package:get/get.dart';

import '../../model/project.dart';
import '../../services/app_services.dart';
import '../../services/core/app_error.dart';
import '../../services/core/app_logger.dart';

class ProjectsController extends GetxController {
  final RxList<Project> projects = <Project>[].obs;
  final RxnString selectedId = RxnString();

  final RxString query = ''.obs;
  final RxBool sortUpdatedAtDesc = true.obs;

  AppLogger get _logger => AppServices.I.logger;

  @override
  void onInit() {
    super.onInit();
    load();
  }

  static String _normalizeName(String name) => name.trim().toLowerCase();

  void _ensureUniqueName(String name, {String? excludingProjectId}) {
    final n = _normalizeName(name);
    if (n.isEmpty) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '参数错误',
        message: '项目名称不能为空。',
        suggestion: '请输入项目名称。',
      );
    }
    final conflict = projects.any(
      (p) => p.id != excludingProjectId && _normalizeName(p.name) == n,
    );
    if (conflict) {
      throw const AppException(
        code: AppErrorCode.projectNameConflict,
        title: '项目名称已存在',
        message: '已存在同名项目（忽略大小写与首尾空格）。',
        suggestion: '请使用不同的项目名称。',
      );
    }
  }

  List<Project> get visibleProjects {
    final q = _normalizeName(query.value);
    final filtered = q.isEmpty
        ? projects.toList()
        : projects.where((p) => _normalizeName(p.name).contains(q)).toList();
    filtered.sort((a, b) {
      final cmp = a.updatedAt.compareTo(b.updatedAt);
      return sortUpdatedAtDesc.value ? -cmp : cmp;
    });
    return filtered;
  }

  String? _defaultSelectionId(List<Project> list) {
    if (list.isEmpty) return null;
    final sorted = list.toList()
      ..sort((a, b) {
        final cmp = a.updatedAt.compareTo(b.updatedAt);
        return sortUpdatedAtDesc.value ? -cmp : cmp;
      });
    return sorted.first.id;
  }

  Future<void> load() async {
    final list = await AppServices.I.projectsStore.list();
    projects.assignAll(list);
    final current = selectedId.value;
    if (current == null && list.isNotEmpty) {
      selectedId.value = _defaultSelectionId(list);
    } else if (current != null && !list.any((p) => p.id == current)) {
      selectedId.value = _defaultSelectionId(list);
    }
  }

  Project? get selected {
    final id = selectedId.value;
    if (id == null) {
      return null;
    }
    return projects.firstWhereOrNull((p) => p.id == id);
  }

  Future<void> select(String projectId) async {
    if (selectedId.value == projectId) return;
    selectedId.value = projectId;
  }

  Future<void> create({
    required String name,
    required String description,
  }) async {
    _ensureUniqueName(name);
    final id = AppServices.I.uuid.v4();
    final now = DateTime.now();
    final project = Project(
      id: id,
      name: name.trim(),
      description: description.trim(),
      createdAt: now,
      updatedAt: now,
    );
    await AppServices.I.projectsStore.upsert(project);
    _logger.info('projects.created', data: {'id': id});
    await load();
    selectedId.value = id;
  }

  Future<void> deleteSelected() async {
    final id = selectedId.value;
    if (id == null) {
      return;
    }
    await AppServices.I.projectsStore.delete(id);
    _logger.info('projects.deleted', data: {'id': id});
    selectedId.value = null;
    await load();
  }

  Future<void> updateSelected({
    required String name,
    required String description,
  }) async {
    final p = selected;
    if (p == null) return;
    _ensureUniqueName(name, excludingProjectId: p.id);
    final updated = p.copyWith(
      name: name.trim(),
      description: description.trim(),
      updatedAt: DateTime.now(),
    );
    await AppServices.I.projectsStore.upsert(updated);
    _logger.info('projects.updated', data: {'id': updated.id});
    await load();
    selectedId.value = updated.id;
  }
}
