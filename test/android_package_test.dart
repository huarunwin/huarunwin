import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/download_platform.dart';

void main() {
  DownloadLink apk(String arch, [String suffix = '']) => DownloadLink(
    url: 'https://example.com/$arch$suffix.apk',
    label: arch,
    platform: 'Android',
    kind: 'apk',
    architecture: arch,
  );
  test('Android recommends exact ABI, then universal, with no guessing', () {
    final arm = apk('arm64'), x64 = apk('x64'), universal = apk('universal');
    expect(recommendedAndroidPackage([x64, arm, universal], 'arm64'), arm);
    expect(recommendedAndroidPackage([x64, universal], 'arm64'), universal);
    expect(recommendedAndroidPackage([x64], 'arm64'), isNull);
    expect(recommendedAndroidPackage([arm], null), isNull);
    expect(
      recommendedAndroidPackage([arm, apk('arm64', '-other')], 'arm64'),
      isNull,
    );
  });
}
