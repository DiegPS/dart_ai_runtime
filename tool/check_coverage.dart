import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final minimum = arguments.length > 1 ? double.tryParse(arguments[1]) : 90.0;
  if (arguments.length > 2 ||
      minimum == null ||
      !minimum.isFinite ||
      minimum < 0 ||
      minimum > 100) {
    stderr.writeln(
      'Usage: dart run tool/check_coverage.dart [coverage/lcov.info] [minimum-percent]',
    );
    exitCode = 64;
    return;
  }
  final input = File(
    arguments.isEmpty ? p.join('coverage', 'lcov.info') : arguments.first,
  );
  try {
    final report = parseLibraryCoverage(
      await input.readAsString(),
      Directory.current.path,
    );
    final summary = report.toJson(minimum);
    await File(
      p.join(input.parent.path, 'summary.json'),
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(summary)}\n');
    stdout.writeln(
      'Library line coverage: ${report.percentage.toStringAsFixed(2)}% '
      '(${report.hit}/${report.total}); required: ${minimum.toStringAsFixed(2)}%.',
    );
    for (final file in report.files) {
      stdout.writeln(
        '${file.percentage.toStringAsFixed(2).padLeft(6)}% '
        '${file.hit}/${file.total} ${file.path}',
      );
    }
    if (!report.passes(minimum)) {
      stderr.writeln('Coverage is below the required threshold.');
      exitCode = 1;
    }
  } on FileSystemException catch (error) {
    stderr.writeln('Cannot read/write coverage report: ${error.message}');
    exitCode = 65;
  } on FormatException catch (error) {
    stderr.writeln('Invalid LCOV report: ${error.message}');
    exitCode = 65;
  }
}

LibraryCoverage parseLibraryCoverage(String lcov, String root) {
  final library = p.canonicalize(p.join(root, 'lib'));
  final files = <String, Map<int, bool>>{};
  Map<int, bool>? lines;
  for (final raw in const LineSplitter().convert(lcov)) {
    if (raw.startsWith('SF:')) {
      final source = p.canonicalize(p.absolute(root, raw.substring(3)));
      lines = p.isWithin(library, source)
          ? files.putIfAbsent(source, () => {})
          : null;
    } else if (raw == 'end_of_record') {
      lines = null;
    } else if (raw.startsWith('DA:') && lines != null) {
      final fields = raw.substring(3).split(',');
      final line = int.tryParse(fields.first);
      final hits = fields.length > 1 ? int.tryParse(fields[1]) : null;
      if (line == null || line <= 0 || hits == null || hits < 0) {
        throw const FormatException(
          'DA entries require a positive line and nonnegative hit count.',
        );
      }
      lines[line] = (lines[line] ?? false) || hits > 0;
    }
  }
  final details = [
    for (final entry in files.entries)
      CoverageFile(
        p.posix.joinAll(p.split(p.relative(entry.key, from: root))),
        entry.value.values.where((hit) => hit).length,
        entry.value.length,
        entry.value.entries
            .where((line) => !line.value)
            .map((line) => line.key)
            .toList()
          ..sort(),
      ),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final report = LibraryCoverage(details);
  if (report.total == 0) {
    throw const FormatException('No executable library lines found.');
  }
  return report;
}

class LibraryCoverage {
  LibraryCoverage(this.files);
  final List<CoverageFile> files;
  int get hit => files.fold(0, (sum, file) => sum + file.hit);
  int get total => files.fold(0, (sum, file) => sum + file.total);
  double get percentage => 100 * hit / total;
  bool passes(double minimum) => hit * 100 >= minimum * total;
  Map<String, Object> toJson(double minimum) => {
    'metric': 'executable line coverage',
    'scope': 'lib/',
    'hit': hit,
    'total': total,
    'percentage': percentage,
    'minimum': minimum,
    'passed': passes(minimum),
    'files': [
      for (final file in files)
        {
          'path': file.path,
          'hit': file.hit,
          'total': file.total,
          'percentage': file.percentage,
          'uncoveredLines': file.missing,
        },
    ],
  };
}

class CoverageFile {
  CoverageFile(this.path, this.hit, this.total, this.missing);
  final String path;
  final int hit;
  final int total;
  final List<int> missing;
  double get percentage => total == 0 ? 100 : 100 * hit / total;
}
