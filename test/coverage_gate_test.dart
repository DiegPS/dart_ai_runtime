import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/check_coverage.dart';

void main() {
  final root = Directory.current.path;
  test('coverage threshold merges repeated records and excludes tests and dependencies', () {
    final source = p.join(root, 'lib', 'example.dart');
    final report = parseLibraryCoverage('''
SF:$source
DA:1,0
DA:2,1
end_of_record
SF:$source
DA:1,1
DA:2,0
DA:3,0
end_of_record
SF:${p.join(root, 'test', 'ignored.dart')}
DA:1,100
end_of_record
''', root);
    expect(report.hit, 2);
    expect(report.total, 3);
    expect(report.files.single.missing, [3]);
    expect(report.passes(66), isTrue);
    expect(report.passes(67), isFalse);
    expect(report.toJson(90)['passed'], isFalse);
  });
  test('empty and malformed reports cannot produce a passing result', () {
    expect(() => parseLibraryCoverage('', root), throwsFormatException);
    expect(
      () => parseLibraryCoverage(
        'SF:${p.join(root, 'lib', 'x.dart')}\nDA:1,-1\n',
        root,
      ),
      throwsFormatException,
    );
  });
}
