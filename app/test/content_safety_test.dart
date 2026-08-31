import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/models/manga.dart';

Manga _manga({
  String title = 'Example Manga',
  String synopsis = 'A harmless adventure.',
  List<String> genres = const [],
  bool isAdult = false,
}) => Manga(
  id: 'anilist:1',
  title: title,
  coverUrl: '',
  synopsis: synopsis,
  status: MangaStatus.ongoing,
  chapterCount: 0,
  genres: genres,
  isAdult: isAdult,
);

void main() {
  test('filters Ecchi and mature metadata genres', () {
    expect(_manga(genres: const ['Ecchi']).isFriendlyContent, isFalse);
    expect(_manga(genres: const ['Mature Themes']).isFriendlyContent, isFalse);
  });

  test('filters explicit advisory text and unsafe searches', () {
    expect(
      _manga(synopsis: 'Contains explicit content.').isFriendlyContent,
      isFalse,
    );
    expect(Manga.isFriendlySearchText('18+ manga'), isFalse);
    expect(Manga.isFriendlySearchText('ecchi'), isFalse);
  });

  test('allows non-Latin manga title searches', () {
    expect(Manga.isFriendlySearchText('ダンダダン'), isTrue);
    expect(Manga.isFriendlySearchText('나 혼자만 레벨업'), isTrue);
    expect(Manga.isFriendlySearchText('斗罗大陆'), isTrue);
  });

  test('does not mistake a volume expression for an age rating', () {
    expect(
      _manga(synopsis: 'The final side story appears in volume 18+1.')
          .isFriendlyContent,
      isTrue,
    );
  });
}
