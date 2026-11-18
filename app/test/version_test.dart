// Версия в UI не должна расходиться с pubspec.yaml.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:voxnica/core/version.dart';

void main() {
  test('kAppVersion совпадает с version в pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(match, isNotNull, reason: 'в pubspec.yaml нет строки version:');

    // "1.0.1+2" → "1.0.1": номер сборки в подписи интерфейса не нужен.
    final expected = match!.group(1)!.split('+').first;
    expect(kAppVersion, expected);
  });
}
