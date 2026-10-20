import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/mac_downloads.dart';

class MetadataPages implements HttpClientAdapter {
  MetadataPages(this.html);
  final String html;
  final requests = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri.toString());
    return ResponseBody.fromString(
      html,
      200,
      headers: {
        'content-type': ['text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final page = Uri.parse('https://github.com/owner/repo/releases/tag/v1');
  final armDigest = 'a' * 64, intelDigest = 'b' * 64;
  String row(String name, String digest) =>
      '<li><div><a href="/owner/repo/releases/download/v1/$name">$name</a></div><clipboard-copy value="sha256:$digest"></clipboard-copy></li>';

  test('a digest belongs only to the matching asset row', () {
    final packages = MacDownloadResolver.packagesFromHtml(
      '<ul>${row('mac-arm64.dmg', armDigest)}${row('mac-x64.dmg', intelDigest)}</ul>',
      page,
    );
    expect(packages.map((p) => p.sha256), [armDigest, intelDigest]);
    expect(packages.every((p) => p.checksumSource == page.toString()), isTrue);
  });

  test('malformed, conflicting and unbound hashes never count as verification metadata', () {
    for (final source in [
      row('mac-arm64.dmg', 'bad'),
      row('mac-arm64.dmg', armDigest).replaceFirst(
        '</li>',
        '<clipboard-copy value="sha256:$intelDigest"></clipboard-copy></li>',
      ),
      '<clipboard-copy value="sha256:$armDigest"></clipboard-copy><a href="/owner/repo/releases/download/v1/mac-arm64.dmg">Mac</a>',
      '<li><a href="/owner/repo/releases/download/v1/mac-arm64.dmg">Mac</a><a href="/owner/repo/releases/download/v1/mac-x64.dmg">Intel</a><clipboard-copy value="sha256:$armDigest"></clipboard-copy></li>',
    ]) {
      expect(
        MacDownloadResolver.packagesFromHtml(
          source,
          page,
        ).every((p) => p.sha256 == null),
        isTrue,
      );
    }
  });

  test('website direct links gain only matching public HTML checksums and keep query parameters', () async {
    final pages = MetadataPages(
      '<ul>${row('mac-arm64.dmg', armDigest)}${row('mac-x64.dmg', intelDigest)}</ul>',
    );
    final client = Dio()..httpClientAdapter = pages;
    final resolver = MacDownloadResolver(client: client);
    addTearDown(() => client.close(force: true));
    const url =
        'https://github.com/owner/repo/releases/download/v1/mac-arm64.dmg?download=1';
    final result = await resolver.resolve(
      const AppDetails(
        app: CatalogApp(
          id: 'fixture',
          name: 'Fixture',
          url: 'https://huarun.win/apps/fixture',
          platforms: ['macOS'],
        ),
        downloads: [
          DownloadLink(
            url: url,
            label: '官方下载',
            platform: 'macOS',
            kind: 'dmg',
            architecture: 'arm64',
          ),
        ],
      ),
    );
    expect(result.packages.single.url, url);
    expect(result.packages.single.sha256, armDigest);
    expect(result.packages.single.label, '官方下载');
    expect(pages.requests, [page.toString()]);
    expect(
      pages.requests.any((url) => url.contains('api.github.com')),
      isFalse,
    );
  });

  for (final platform in ['Android', 'Windows', 'Linux']) {
    test('$platform direct package gains its matching public HTML checksum', () async {
      final kind = switch (platform) {
        'Android' => 'apk',
        'Windows' => 'exe',
        _ => 'deb',
      };
      final name = '${platform.toLowerCase()}-arm64.$kind';
      final pages = MetadataPages('<ul>${row(name, armDigest)}</ul>');
      final client = Dio()..httpClientAdapter = pages;
      addTearDown(() => client.close(force: true));
      final result = await MacDownloadResolver(client: client).resolvePackages(
        AppDetails(
          app: CatalogApp(
            id: 'fixture',
            name: 'Fixture',
            url: 'https://huarun.win/apps/fixture',
            platforms: [platform],
          ),
          downloads: [
            DownloadLink(
              url: 'https://github.com/owner/repo/releases/download/v1/$name',
              label: kind.toUpperCase(),
              platform: platform,
              kind: kind,
              architecture: 'arm64',
            ),
          ],
        ),
        platform,
      );
      expect(result.single.sha256, armDigest);
      expect(pages.requests, [page.toString()]);
    });
  }
}
