import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/updater.dart';

void main() {
  group('a comparação de versões', () {
    test('é por número, não por texto', () {
      expect(compareVersions('2.10.0', '2.9.1'), 1);
      expect(compareVersions('2.4.0', '2.4.1'), -1);
    });

    test('ignora o v da tag e o que falta no fim', () {
      expect(compareVersions('v2.5.0', '2.5.0'), 0);
      expect(compareVersions('2.5', '2.5.0'), 0);
      expect(compareVersions('v3', '2.99.99'), 1);
    });
  });

  group('o SHA256SUMS', () {
    const a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const b = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
    const sums =
        '$a  maestria_2.5.0-1_amd64.deb\n'
        '$b *maestria_2.5.0-1_macos.dmg\n';

    test('acha o hash pelo nome exato do arquivo', () {
      expect(expectedSum(sums, 'maestria_2.5.0-1_amd64.deb'), a);
      // O `*` do modo binário não faz parte do nome, e o hash sai minúsculo.
      expect(expectedSum(sums, 'maestria_2.5.0-1_macos.dmg'), b.toLowerCase());
    });

    test('não acha o que não está lá', () {
      expect(expectedSum(sums, 'maestria_2.5.0-1_amd64.deb.zip'), isNull);
      expect(expectedSum('', 'x'), isNull);
    });
  });

  group('a release do GitHub', () {
    Map<String, dynamic> json({bool sums = true}) => {
      'tag_name': 'v2.5.0',
      'assets': [
        {'name': 'maestria_2.5.0-1_amd64.deb', 'browser_download_url': 'https://x/deb'},
        {'name': 'maestria_2.5.0-1_macos.dmg', 'browser_download_url': 'https://x/dmg'},
        if (sums) {'name': 'SHA256SUMS', 'browser_download_url': 'https://x/sums'},
      ],
    };

    test('pega o anexo do sistema e o SHA256SUMS', () {
      final r = MxRelease.fromJson(json(), '_macos.dmg')!;
      expect(r.version, '2.5.0');
      expect(r.asset, 'maestria_2.5.0-1_macos.dmg');
      expect(r.assetUrl, 'https://x/dmg');
      expect(r.sumsUrl, 'https://x/sums');
    });

    test('sem o anexo do sistema não há release', () {
      expect(MxRelease.fromJson(json(), '_arm64.deb'), isNull);
    });

    test('uma release antiga, sem SHA256SUMS, fica sem o que conferir', () {
      expect(MxRelease.fromJson(json(sums: false), '_amd64.deb')!.sumsUrl, isNull);
    });
  });

  test('um build sem MAESTRIA_VERSION não se atualiza', () {
    expect(Updater(current: '').enabled, isFalse);
  });
}
