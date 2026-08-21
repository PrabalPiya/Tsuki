import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/models/manga.dart';

Manga _manga(MangaStatus status) => Manga(
  id: 'test:${status.name}',
  title: 'Test',
  coverUrl: '',
  synopsis: '',
  status: status,
  chapterCount: 0,
);

void main() {
  test('release status labels are explicit and stable', () {
    expect(_manga(MangaStatus.ongoing).statusLabel, 'Ongoing');
    expect(_manga(MangaStatus.completed).statusLabel, 'Completed');
    expect(_manga(MangaStatus.hiatus).statusLabel, 'Hiatus');
    expect(_manga(MangaStatus.cancelled).statusLabel, 'Cancelled');
  });
}
