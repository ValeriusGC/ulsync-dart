import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync_example/tap.dart';

void main() {
  test('empty log value is 0', () {
    final log = TapLog();
    expect(log.value, 0);
  });

  test('one tap of delta 1 yields value 1', () {
    final log = TapLog();
    log.apply(const Tap(id: 'a', delta: 1));
    expect(log.value, 1);
  });

  test('same id applied twice keeps value 1 and returns false second time', () {
    final log = TapLog();
    const tap = Tap(id: 'a', delta: 1);
    expect(log.apply(tap), isTrue);
    expect(log.apply(tap), isFalse);
    expect(log.value, 1);
  });

  test('two different ids yield value 2', () {
    final log = TapLog();
    log.apply(const Tap(id: 'a', delta: 1));
    log.apply(const Tap(id: 'b', delta: 1));
    expect(log.value, 2);
  });

  test('byId returns null when missing and same fields when present', () {
    final log = TapLog();
    expect(log.byId('missing'), isNull);
    const tap = Tap(id: 'a', delta: 1);
    log.apply(tap);
    final loaded = log.byId('a');
    expect(loaded, isNotNull);
    expect(loaded!.id, tap.id);
    expect(loaded.delta, tap.delta);
  });

  test('delta 2 then delta 1 on different ids yields value 3', () {
    final log = TapLog();
    log.apply(const Tap(id: 'a', delta: 2));
    log.apply(const Tap(id: 'b', delta: 1));
    expect(log.value, 3);
  });
}
