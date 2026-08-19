import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsuki/core/models/chapter.dart';
import 'package:tsuki/core/storage/chapter_index_cache.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('chapter index survives a local cache round trip', () async {
    final cache = ChapterIndexCache();
    final chapters = [
      CanonicalChapter(
        id: 'chapter:number:124',
        number: 124,
        title: 'Chapter 124',
        publishedAt: DateTime.utc(2026, 8, 19),
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: 'comick',
            chapterId: 'chapter-124',
            reliability: .88,
            publishedAt: DateTime.utc(2026, 8, 19),
            attribution: 'ComicK',
          ),
        ],
      ),
    ];

    await cache.writeChapters(
      'anilist:1|adult:false',
      chapters,
      markChecked: true,
    );

    final restored = await cache.readChapters('anilist:1|adult:false');

    expect(restored, isNotNull);
    expect(restored, hasLength(1));
    expect(restored!.single.number, 124);
    expect(restored.single.sourceCopies.single.sourceId, 'comick');
  });

  test('source mappings are persisted locally', () async {
    final cache = ChapterIndexCache();

    await cache.writeMapping('anilist:1|comick', 'hid|slug');

    expect(await cache.readMapping('anilist:1|comick'), 'hid|slug');
  });
}
