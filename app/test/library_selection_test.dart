import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/core/state/app_state.dart';
import 'package:tsuki/core/state/providers.dart';
import 'package:tsuki/core/storage/user_store.dart';
import 'package:tsuki/features/library/presentation/library_screen.dart';

const _config = AppConfig(
  environment: AppEnvironment.development,
  useDemoData: false,
  firebaseProjectId: '',
  firebaseAppId: '',
  firebaseApiKey: '',
  firebaseMessagingSenderId: '',
  backendBaseUrl: '',
  remoteCatalogUrl: '',
);

const _first = Manga(
  id: 'test:first',
  title: 'First Manga',
  coverUrl: '',
  synopsis: 'First test manga.',
  status: MangaStatus.ongoing,
  chapterCount: 1,
);

const _second = Manga(
  id: 'test:second',
  title: 'Second Manga',
  coverUrl: '',
  synopsis: 'Second test manga.',
  status: MangaStatus.ongoing,
  chapterCount: 1,
);

void main() {
  testWidgets(
    'long press selects manga and bottom action removes immediately',
    (tester) async {
      final store = LocalUserStore();
      await store.saveBookmarks(
        'reader',
        {_first.id, _second.id},
        {_first.id: _first, _second.id: _second},
      );
      final controller = UserLibraryController('reader', store);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(_config),
            userLibraryProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.checklist_rounded), findsNothing);
      expect(find.text('Remove bookmark'), findsNothing);

      final firstCardTitle = find.text('First Manga').last;
      await tester.ensureVisible(firstCardTitle);
      await tester.pump();
      await tester.longPress(firstCardTitle);
      await tester.pump(const Duration(milliseconds: 220));

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.text('Remove bookmark'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      await tester.tap(find.text('Second Manga').last);
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.text('Remove 2 bookmarks'), findsOneWidget);

      await tester.tap(find.text('Remove 2 bookmarks'));
      await tester.pump();

      expect(controller.state.bookmarks, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
