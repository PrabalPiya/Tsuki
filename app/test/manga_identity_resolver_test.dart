import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/identity/manga_identity_resolver.dart';
import 'package:tsuki/core/models/manga.dart';

Manga _manga({
  required String id,
  required String title,
  List<String> aliases = const [],
  MangaFormat format = MangaFormat.manga,
  int? year = 2018,
  int? anilistId,
  int? malId,
  bool adult = false,
}) => Manga(
  id: id,
  anilistId: anilistId,
  malId: malId,
  title: title,
  aliases: aliases,
  coverUrl: '',
  synopsis: '',
  status: MangaStatus.ongoing,
  chapterCount: 0,
  format: format,
  startYear: year,
  isAdult: adult,
);

void main() {
  const resolver = MangaIdentityResolver();

  test('normalizes punctuation, case and repeated whitespace', () {
    expect(
      MangaIdentityResolver.normalizeTitle('Solo Leveling'),
      'solo leveling',
    );
    expect(
      MangaIdentityResolver.normalizeTitle('solo-leveling'),
      'solo leveling',
    );
    expect(
      MangaIdentityResolver.normalizeTitle('Solo   Leveling'),
      'solo leveling',
    );
  });

  test('known provider relationships resolve immediately', () {
    final match = resolver.compare(
      _manga(id: 'anilist:1', title: 'A', malId: 42),
      _manga(id: 'tsuki:kitsu:9', title: 'B', malId: 42),
    );
    expect(match.confidence, MatchConfidence.known);
    expect(match.canMerge, isTrue);
  });

  test('aliases identify the same canonical manga', () {
    final match = resolver.compare(
      _manga(
        id: 'anilist:1',
        title: 'Solo Leveling',
        aliases: const ['Ore dake Level Up na Ken'],
      ),
      _manga(id: 'tsuki:kitsu:2', title: 'Ore dake Level Up na Ken'),
    );
    expect(match.confidence, MatchConfidence.high);
  });

  test('harmless source suffixes do not create duplicate manga', () {
    final match = resolver.compare(
      _manga(id: 'anilist:1', title: 'Shared Work'),
      _manga(id: 'source:2', title: 'Shared Work Official Translation'),
    );

    expect(match.canMerge, isTrue);
  });

  test('reader decorations and status labels do not create duplicates', () {
    expect(
      resolver
          .compare(
            _manga(id: 'anilist:1', title: 'Paper Moon'),
            _manga(
              id: 'source:2',
              title: 'Read Paper Moon Manga Online - Mangakakalot',
            ),
          )
          .canMerge,
      isTrue,
    );
    expect(
      resolver
          .compare(
            _manga(id: 'anilist:1', title: 'Paper Moon'),
            _manga(id: 'source:3', title: 'Paper Moon [Completed]'),
          )
          .canMerge,
      isTrue,
    );
  });

  test('same-name works with conflicting canonical IDs remain separate', () {
    final left = _manga(
      id: 'anilist:1',
      title: 'Blue',
      anilistId: 1,
      year: 2020,
    );
    final right = _manga(
      id: 'anilist:2',
      title: 'Blue',
      anilistId: 2,
      year: 2020,
    );

    expect(resolver.compare(left, right).canMerge, isFalse);
  });

  test('protects against novel, remake and colored edition merges', () {
    expect(
      resolver
          .compare(
            _manga(id: 'a', title: 'Moon Story'),
            _manga(id: 'b', title: 'Moon Story', format: MangaFormat.novel),
          )
          .canMerge,
      isFalse,
    );
    expect(
      resolver
          .compare(
            _manga(id: 'a', title: 'Moon Story'),
            _manga(id: 'b', title: 'Moon Story Remake'),
          )
          .canMerge,
      isFalse,
    );
    expect(
      resolver
          .compare(
            _manga(id: 'a', title: 'Moon Story'),
            _manga(id: 'b', title: 'Moon Story Colored'),
          )
          .canMerge,
      isFalse,
    );
  });

  test('merged adult signal cannot be weakened by fallback metadata', () {
    final merged = resolver.merge(
      _manga(id: 'anilist:1', title: 'Title', anilistId: 1),
      _manga(id: 'kitsu:2', title: 'Title', adult: true),
    );
    expect(merged.isAdult, isTrue);
    expect(merged.isFriendlyContent, isFalse);
  });
}
