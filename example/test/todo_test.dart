import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync_example/session_status.dart';
import 'package:ulsync_example/todo.dart';

void main() {
  group('TodoJournal column apply', () {
    test('applyFullTitle does not reset done and deleted', () {
      final journal = TodoJournal();
      journal.setTitle('a', 'Milk');
      journal.setDone('a', true);
      journal.setDeleted('a', true);

      journal.applyFullTitle('a', 'Milk');

      final row = journal.byId('a')!;
      expect(row.done, isTrue);
      expect(row.deleted, isTrue);
    });

    test('listIds after setDeleted still contains the id', () {
      final journal = TodoJournal();
      journal.setTitle('a', 'Milk');
      journal.setDeleted('a', true);

      expect(journal.listIds(), contains('a'));
      expect(journal.activeTodos(), isEmpty);
      expect(journal.trashedTodos(), hasLength(1));
    });

    test('setDone moves lastEditedAtMs forward', () {
      final journal = TodoJournal();
      journal.setTitle('a', 'Milk');
      journal.byId('a')!.lastEditedAtMs = 1000;

      journal.setDone('a', true);

      expect(journal.byId('a')!.lastEditedAtMs, greaterThan(1000));
    });

    test('setDeleted does not reset done', () {
      final journal = TodoJournal();
      journal.setTitle('a', 'Milk');
      journal.setDone('a', true);

      journal.setDeleted('a', true);

      expect(journal.byId('a')!.done, isTrue);
      expect(journal.byId('a')!.deleted, isTrue);
    });

    test('restore with deleted false keeps done', () {
      final journal = TodoJournal();
      journal.setTitle('a', 'Milk');
      journal.setDone('a', true);
      journal.setDeleted('a', true);

      journal.setDeleted('a', false);

      final row = journal.byId('a')!;
      expect(row.deleted, isFalse);
      expect(row.done, isTrue);
      expect(journal.listIds(), contains('a'));
    });

    test('doneNotTrashedIds excludes trashed and not-done rows', () {
      final journal = TodoJournal();
      journal.setTitle('a', 'Milk');
      journal.setTitle('b', 'Bread');
      journal.setDone('a', true);
      journal.setDeleted('b', true);

      expect(journal.doneNotTrashedIds(), ['a']);
    });
  });

  group('SessionStatus banner', () {
    test('Work offline uses the offline copy without host', () {
      expect(
        SessionStatus.offline.bannerLine(host: '127.0.0.1:8080'),
        'Offline · saved on this device',
      );
    });

    test('Live status includes host prefix', () {
      expect(
        SessionStatus.live.bannerLine(host: '127.0.0.1:8080'),
        startsWith('Live ·'),
      );
    });
  });

  group('safeDeviceId', () {
    test('accepts phone and tablet names used in acceptance', () {
      expect(safeDeviceId('phone'), 'phone');
      expect(safeDeviceId('tablet'), 'tablet');
    });

    test('rejects empty and path traversal', () {
      expect(safeDeviceId(''), isNull);
      expect(safeDeviceId('../evil'), isNull);
    });
  });
}
