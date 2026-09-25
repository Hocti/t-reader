import 'dart:convert';

import 'package:epub_reader/src/reader_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const voices = [
    SystemVoice(name: 'en-gb', locale: 'en_GB'),
    SystemVoice(name: 'en-us', locale: 'en-US'),
    SystemVoice(name: 'yue', locale: 'yue-HK'),
    SystemVoice(name: 'hk', locale: 'zh-HK'),
    SystemVoice(name: 'tw', locale: 'zh-TW'),
    SystemVoice(name: 'cn', locale: 'zh-CN'),
  ];

  test('cantonese prefers a yue voice', () {
    expect(pickSystemVoice(voices, SpeechLanguage.cantonese)?.name, 'yue');
  });

  test('mandarin prefers zh-TW and skips Cantonese', () {
    expect(pickSystemVoice(voices, SpeechLanguage.mandarin)?.name, 'tw');
    expect(voiceMatchesLanguage('zh-HK', SpeechLanguage.mandarin), isFalse);
  });

  test('english prefers en-US', () {
    expect(pickSystemVoice(voices, SpeechLanguage.english)?.locale, 'en-US');
  });

  test('top and bottom margins are their own setting', () {
    const layout = ReaderLayout(margin: MarginStep.narrow, marginV: MarginStep.wide);
    final back = ReaderLayout.fromJson(layout.toJson());
    expect(back.margin, MarginStep.narrow);
    expect(back.marginV, MarginStep.wide);
    expect(back.marginPx, 12);
    expect(back.marginVPx, 32);
    expect(ReaderLayout.fromJson({'margin': 'wide'}).marginV, MarginStep.normal);
  });

  test('an empty voice list does not invent a voice', () {
    expect(pickSystemVoice(const [], SpeechLanguage.cantonese), isNull);
    expect(preferredSpeechLocale(SpeechLanguage.cantonese), 'zh-HK');
  });

  test('speech defaults to system Cantonese, and cloud cannot stay selected', () async {
    SharedPreferences.setMockInitialValues({});
    final fresh = ReaderStore();
    expect(fresh.engine, SpeechEngine.system);
    expect(fresh.language, SpeechLanguage.cantonese);

    SharedPreferences.setMockInitialValues({
      'reader_v1': jsonEncode({
        'engine': 'cloud',
        'language': 'english',
      }),
    });
    final saved = ReaderStore();
    await saved.load();
    expect(saved.engine, SpeechEngine.system);
    expect(saved.language, SpeechLanguage.english);

    SharedPreferences.setMockInitialValues({
      'reader_v1': jsonEncode({'voiceLocale': 'zh_TW'}),
    });
    final legacy = ReaderStore();
    await legacy.load();
    expect(legacy.language, SpeechLanguage.mandarin);
  });
}
