import 'package:app/local/project_order.dart';
import 'package:flutter_test/flutter_test.dart';

// applyOrder overlays a per-device presentation order (project names/paths) on a
// list, keeping unknown (newly-added) items at the end in their original order.
void main() {
  List<String> ord(List<String> items, List<String> order) =>
      applyOrder(items, order, (s) => s);

  group('applyOrder', () {
    test('empty order leaves items unchanged', () {
      expect(ord(['a', 'b', 'c'], const []), ['a', 'b', 'c']);
    });

    test('reorders known keys into the order sequence', () {
      expect(ord(['a', 'b', 'c'], ['c', 'a', 'b']), ['c', 'a', 'b']);
    });

    test('unknown keys keep original relative order at the end', () {
      expect(ord(['a', 'b', 'c', 'd'], ['b']), ['b', 'a', 'c', 'd']);
    });

    test('mix of known (ordered) then unknown (original order)', () {
      expect(ord(['a', 'b', 'c', 'd'], ['d', 'a']), ['d', 'a', 'b', 'c']);
    });

    test('order keys absent from items are ignored', () {
      expect(ord(['a', 'b'], ['z', 'b', 'a']), ['b', 'a']);
    });

    test('single item returned as-is', () {
      expect(ord(['x'], ['y', 'x']), ['x']);
    });
  });
}
