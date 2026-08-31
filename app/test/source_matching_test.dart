import 'package:flutter_test/flutter_test.dart';

import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/reader/data/source_matching.dart';

Manga _manga(String id, String title, {List<String> aliases = const []}) =>
    Manga(
      id: id,
      title: title,
      aliases: aliases,
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 0,
    );

void main() {
  test('matches harmless title variations', () {
    expect(
      SourceMatching.similarity(
        'The Greatest Estate Developer',
        'Greatest Estate Developer (Official)',
      ),
      1,
    );
    expect(SourceMatching.similarity('Pokémon', 'Pokemon'), 1);
    expect(SourceMatching.similarity('Moon Knight II', 'Moon Knight 2'), 1);
    expect(
      SourceMatching.similarity(
        'Hero Academy Season II',
        'Hero Academy 2nd Season',
      ),
      1,
    );
  });

  test('search queries include useful variants without growing unbounded', () {
    final queries = SourceMatching.searchQueries(
      _manga(
        'canonical:1',
        'The Greatest Estate Developer (Official)',
        aliases: const ['The Greatest Estate Developer'],
      ),
    );
    expect(queries, contains('Greatest Estate Developer (Official)'));
    expect(queries, contains('The Greatest Estate Developer'));
    expect(queries.length, lessThanOrEqualTo(8));
  });

  test('selects a variation but rejects similar series and editions', () {
    final canonical = _manga('canonical:1', 'The Beginning After the End');
    expect(
      SourceMatching.bestMatchId(
        canonical,
        [
          _manga('source:right', 'Beginning After the End (Official)'),
          _manga('source:wrong', 'Beginning After the End Remake'),
        ],
        sourcePrefix: 'source:',
        minimumScore: .9,
      ),
      'right',
    );
    expect(
      SourceMatching.similarity('One Piece', 'One Piece Party'),
      lessThan(.9),
    );
    expect(SourceMatching.similarity('Hero Academy', 'Hero Academy 2'), 0);
    expect(SourceMatching.similarity('Moon Story', 'Moon Story Remake'), 0);
  });

  test('refuses an unresolved tie', () {
    expect(
      SourceMatching.bestMatchId(
        _manga('canonical:1', 'Blue Star'),
        [
          _manga('source:a', 'The Blue Star'),
          _manga('source:b', 'Blue Star (Official)'),
        ],
        sourcePrefix: 'source:',
        minimumScore: .9,
      ),
      isNull,
    );
  });
}
