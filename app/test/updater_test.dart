import 'package:curated_score/updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("an answer can't send the download or the page anywhere but GitHub, nor name a file outside Downloads", () {
    Release? read(String url, {String page = 'https://github.com/xy057/curator/releases/tag/v9.0.0'}) =>
        Release.fromJson({
          'tag_name': 'v9.0.0',
          'html_url': page,
          'assets': [
            {'name': 'Curator-9.0.0-macos.zip', 'browser_download_url': url, 'size': 'big'},
          ],
        }, platform: 'macos');
    for (final url in [
      'http://github.com/a/Curator.zip',
      'https://evil.example/Curator.zip',
      'file:///etc/passwd',
      'https://github.com.evil.example/x.zip',
    ]) {
      expect(read(url)!.download, isNull, reason: url);
    }
    for (final page in ['file:///Applications/Calculator.app', 'javascript:alert(1)', 'https://evil.example/']) {
      expect(read('https://github.com/x.zip', page: page)!.pageUrl, '$repositoryUrl/releases', reason: page);
    }
    expect(read('https://github.com/x.zip')!.downloadSize, isNull, reason: 'a size that is no number');
    for (final name in ['..', '..%2F..%2F.zshrc', '..%5Cevil.zip', 'Curator.app', '.hidden.zip']) {
      expect(read('https://github.com/d/$name')!.fileName, 'Curator-9.0.0-macos.zip', reason: name);
    }
    final local = Release.fromJson({
      'tag_name': 'v9.0.0',
      'assets': [
        {'name': 'Curator-9.0.0-macos.zip', 'browser_download_url': 'http://127.0.0.1:8080/dl/a.zip'},
      ],
    }, platform: 'macos', origin: Uri.parse('http://127.0.0.1:8080/latest'));
    expect(local!.download, isNotNull, reason: 'the server asked');
  });
}
