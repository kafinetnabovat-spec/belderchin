import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/sources/data/source_list_constants.dart';
import 'package:hiddify/features/sources/data/source_list_validator.dart';
import 'package:hiddify/features/sources/data/trusted_keys.dart';

/// Guards the file that ships inside the APK: it must verify against the
/// embedded production keys. When this test fails because the list expired,
/// re-sign it with `tools/sources/belderchin_sources.py sign --issue-now`.
void main() {
  test('bundled source list verifies with the embedded keys and is current', () async {
    final file = File(SourceListConstants.bundledAsset);
    expect(file.existsSync(), isTrue, reason: 'run tests from the project root');

    const validator = SourceListValidator(trustedKeys: kTrustedSourceKeys);
    final result = await validator.validate(await file.readAsString(), now: DateTime.now().toUtc());
    expect(result, isA<SourceListAccepted>(), reason: result.toString());

    final accepted = result as SourceListAccepted;
    expect(accepted.expired, isFalse, reason: 'bundled list expired - re-sign it before releasing');
    expect(accepted.list.warp.enabled, isTrue);
    expect(accepted.list.warp.ports, isNotEmpty);
    expect(accepted.list.warp.endpoints, isNotEmpty);
    expect(accepted.list.healthCheck, isNotNull);
    expect(accepted.list.healthCheck!.minSuccess, greaterThanOrEqualTo(1));
  });

  test('built-in mirrors are https and distinct', () {
    final mirrors = SourceListConstants.builtInMirrors;
    expect(mirrors, isNotEmpty);
    expect(mirrors.map((m) => m.scheme), everyElement('https'));
    expect(mirrors.toSet(), hasLength(mirrors.length));
  });
}
