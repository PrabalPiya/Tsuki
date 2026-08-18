import '../core/models/chapter.dart';
import '../core/models/manga.dart';

const demoCatalog = <Manga>[
  Manga(
    id: 'demo:paper-moon',
    title: 'Paper Moon',
    coverUrl: '',
    synopsis: 'A quiet cartographer discovers that every map she finishes erases one memory of home. She crosses a shifting archipelago to find the source before the last path back disappears.',
    status: MangaStatus.ongoing,
    rating: 8.6,
    chapterCount: 42,
    aliases: ['The Paper Moon'],
  ),
  Manga(
    id: 'demo:after-rain',
    title: 'After the Violet Rain',
    coverUrl: '',
    synopsis: 'In a city where storms reveal hidden thoughts, a withdrawn courier carries messages no one else can safely touch. A missing letter draws her into a restrained supernatural mystery.',
    status: MangaStatus.ongoing,
    rating: 8.2,
    chapterCount: 27,
  ),
  Manga(
    id: 'demo:salt-and-iron',
    title: 'Salt & Iron',
    coverUrl: '',
    synopsis: 'Two rival cooks inherit a failing harbor restaurant and a debt owed to the local fleet. Their uneasy partnership becomes a warm story about craft, family, and starting over.',
    status: MangaStatus.completed,
    rating: 7.9,
    chapterCount: 64,
  ),
  Manga(
    id: 'demo:lantern-keeper',
    title: 'The Last Lantern Keeper',
    coverUrl: '',
    synopsis: 'The final keeper of an ancient road guides travelers through a night that no longer ends. Each journey brings the fading world closer to dawn—and the keeper closer to a difficult choice.',
    status: MangaStatus.hiatus,
    rating: null,
    chapterCount: 18,
  ),
];
List<CanonicalChapter> demoChapters(Manga manga) =>
    List.generate(manga.chapterCount.clamp(1, 80).toInt(), (i) {
      final published = DateTime.now().subtract(
        Duration(days: (manga.chapterCount - i) * 7),
      );
      return CanonicalChapter(
        id: '${manga.id}:chapter:${i + 1}',
        number: (i + 1).toDouble(),
        title: 'Chapter ${i + 1}',
        publishedAt: published,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: 'demo',
            chapterId: '${manga.id}:chapter:${i + 1}',
            reliability: 1,
            publishedAt: published,
          ),
        ],
      );
    });
ChapterPages demoPages(String chapterId) => ChapterPages(
  chapterId: chapterId,
  sourceId: 'demo',
  urls: List.generate(12, (i) => 'demo://page/${i + 1}'),
);
