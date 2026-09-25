import 'dart:io';

import 'package:epub_reader/src/lookup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sample = 'word,frequency,lemmas,seven_k,pos,cefr,ranking,tc\n'
      'go,100,"[""went"",""goes"",""gone""]",1,"[""verb""]",A1,1,"vi.去,走 n.嘗試"\n'
      'run,90,"[""ran"",""runs""]",1,"[""verb""]",A1,2,"n.跑,賽跑vi.跑,奔"\n'
      'city,80,"[]",1,"[""noun""]",A2,3,n.城市\n'
      'paris,10,"[]",0,"[]",,4,\n';

  test('finds headwords, listed forms, and regular endings', () {
    final dict = WordDictionary.parse(sample);
    expect(dict.length, 4);
    expect(dict.find('Go')?.word, 'go');
    expect(dict.find('went')?.word, 'go');
    expect(dict.find('running')?.word, 'run');
    expect(dict.find('cities')?.word, 'city');
    expect(dict.find('city\u2019s')?.word, 'city');
    expect(dict.find('“Run,”')?.word, 'run');
    expect(dict.find('zzz'), isNull);
    expect(dict.find('Paris')?.chinese, '');
  });

  test('splits Chinese before part-of-speech marks', () {
    expect(splitChineseSenses('n.跑,賽跑vi.跑,奔'), ['n.跑,賽跑', 'vi.跑,奔']);
    expect(splitChineseSenses('vi.去,走 n.嘗試'), ['vi.去,走', 'n.嘗試']);
    expect(splitChineseSenses('n.城市'), ['n.城市']);
  });

  test('turns Wiktionary definitions into plain text', () {
    final meanings = parseWiktionary({
      'en': [
        {
          'partOfSpeech': 'Verb',
          'definitions': [
            {
              'definition': 'simple <a href="/wiki/past">past</a> of <i>go</i>',
              'examples': ['We <b>went</b> home &amp; slept.'],
            },
            {'definition': '<span></span>'},
          ],
        },
      ],
      'fr': [
        {
          'partOfSpeech': 'Noun',
          'definitions': [
            {'definition': 'not English'},
          ],
        },
      ],
    });
    expect(meanings, hasLength(1));
    expect(meanings.first.partOfSpeech, 'Verb');
    expect(meanings.first.senses, hasLength(1));
    expect(meanings.first.senses.first.definition, 'simple past of go');
    expect(meanings.first.senses.first.example, 'We went home & slept.');
  });

  test('the bundled word list loads and covers common forms', () {
    final dict = WordDictionary.parse(File('assets/dict/word.csv').readAsStringSync());
    expect(dict.length, greaterThan(30000));
    expect(dict.find('went')?.word, 'go');
    expect(dict.find('ran')?.word, 'run');
    expect(dict.find('mice')?.word, 'mouse');
    expect(dict.find('studies')?.word, 'study');
    expect(dict.find('stopping')?.word, 'stop');
    expect(dict.find('book')?.chinese, contains('書'));
  });
}
