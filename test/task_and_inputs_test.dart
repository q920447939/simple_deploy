import 'package:flutter_test/flutter_test.dart';
import 'package:simple_deploy/model/run_inputs.dart';
import 'package:simple_deploy/model/task.dart';

void main() {
  test('Task.fromJson supports legacy v1 shape (playbook task)', () {
    final t = Task.fromJson({
      'id': 't1',
      'name': 'Deploy',
      'description': 'desc',
      'playbook_id': 'pb1',
      'file_slots': [
        {'name': 'artifact', 'required': true, 'multiple': false},
      ],
    });
    expect(t.type, TaskType.ansiblePlaybook);
    expect(t.isAnsiblePlaybook, isTrue);
    expect(t.playbookId, 'pb1');
    expect(t.script, isNull);
    expect(t.fileSlots.length, 1);
    expect(t.variables, isEmpty);
  });

  test('Task roundtrip (local_script with vars)', () {
    final t = Task(
      id: 't1',
      name: 'Prepare',
      description: '',
      type: TaskType.localScript,
      playbookId: null,
      script: const TaskScript(shell: 'bash', content: 'echo ok'),
      fileSlots: const [],
      variables: const [
        TaskVariable(
          name: 'version',
          description: 'app version',
          defaultValue: '1.0.0',
          required: true,
        ),
      ],
    );
    final t2 = Task.fromJson(t.toJson());
    expect(t2.type, TaskType.localScript);
    expect(t2.script?.shell, 'bash');
    expect(t2.script?.content, 'echo ok');
    expect(t2.variables.length, 1);
    expect(t2.variables.first.name, 'version');
    expect(t2.variables.first.defaultValue, '1.0.0');
  });

  test('RunInputs.fromJson parses file_inputs + vars', () {
    final inputs = RunInputs.fromJson({
      'file_inputs': {
        't1': {
          'artifact': ['/a/b/c.tar.gz'],
        },
      },
      'vars': {
        't1': {'version': '2.0.0'},
      },
    });
    expect(inputs.fileInputs['t1']?['artifact'], ['/a/b/c.tar.gz']);
    expect(inputs.vars['t1']?['version'], '2.0.0');
  });
}

