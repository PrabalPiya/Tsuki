import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga.dart';
import '../models/reading_progress.dart';

class UserSnapshot {
  const UserSnapshot({
    required this.bookmarks,
    required this.bookmarkedManga,
    required this.progress,
  });

  final Set<String> bookmarks;
  final Map<String, Manga> bookmarkedManga;
  final Map<String, ReadingProgress> progress;
}

abstract interface class UserStore {
  Future<UserSnapshot> load(String uid);
  Future<void> saveBookmarks(
    String uid,
    Set<String> ids,
    Map<String, Manga> manga,
  );
  Future<void> saveProgress(String uid, ReadingProgress progress);
  Future<void> clearSession(String uid);
}

class LocalUserStore implements UserStore {
  const LocalUserStore();

  @override
  Future<UserSnapshot> load(String uid) async {
    final p = await SharedPreferences.getInstance();
    final prefix = 'user.$uid.';
    final bookmarks =
        p.getStringList('${prefix}bookmarks')?.toSet() ?? <String>{};
    final progress = <String, ReadingProgress>{};
    final bookmarkedManga = <String, Manga>{};

    final catalog = p.getString('${prefix}catalog');
    if (catalog != null) {
      try {
        final map = jsonDecode(catalog) as Map<String, dynamic>;
        for (final entry in map.entries) {
          try {
            final manga = Manga.fromJson(entry.value as Map<String, dynamic>);
            if (manga.isFriendlyContent) bookmarkedManga[entry.key] = manga;
          } catch (_) {
            // Ignore one corrupt legacy entry instead of losing the library.
          }
        }
      } catch (_) {
        // Optional metadata can be fetched again from the provider.
      }
    }

    final encoded = p.getString('${prefix}progress');
    if (encoded != null) {
      try {
        final map = jsonDecode(encoded) as Map<String, dynamic>;
        for (final entry in map.entries) {
          try {
            progress[entry.key] = ReadingProgress.fromJson(
              entry.value as Map<String, dynamic>,
            );
          } catch (_) {
            // Keep valid progress if one legacy entry is malformed.
          }
        }
      } catch (_) {
        // A corrupt local progress blob should never prevent app startup.
      }
    }

    // Remove the obsolete adult-mode preference if it exists from an old build.
    await p.remove('${prefix}adult');

    final safeBookmarks = bookmarks
        .where((id) => bookmarkedManga[id]?.isFriendlyContent == true)
        .toSet();

    return UserSnapshot(
      bookmarks: safeBookmarks,
      bookmarkedManga: {
        for (final entry in bookmarkedManga.entries)
          if (safeBookmarks.contains(entry.key)) entry.key: entry.value,
      },
      progress: progress,
    );
  }

  @override
  Future<void> saveBookmarks(
    String uid,
    Set<String> ids,
    Map<String, Manga> manga,
  ) async {
    final blockedIds = manga.entries
        .where((entry) => !entry.value.isFriendlyContent)
        .map((entry) => entry.key)
        .toSet();
    final safeManga = <String, Manga>{
      for (final entry in manga.entries)
        if (entry.value.isFriendlyContent) entry.key: entry.value,
    };
    final safeIds = ids
        .where((id) => !blockedIds.contains(id))
        .toList(growable: false);
    final p = await SharedPreferences.getInstance();
    await p.setStringList('user.$uid.bookmarks', safeIds);
    await p.setString(
      'user.$uid.catalog',
      jsonEncode(
        safeManga.map((key, value) => MapEntry(key, value.toJson())),
      ),
    );
  }

  @override
  Future<void> saveProgress(String uid, ReadingProgress value) async {
    final p = await SharedPreferences.getInstance();
    final key = 'user.$uid.progress';
    Map<String, dynamic> map;
    try {
      map = jsonDecode(p.getString(key) ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      map = <String, dynamic>{};
    }
    map[value.mangaId] = value.toJson();
    await p.setString(key, jsonEncode(map));
  }

  @override
  Future<void> clearSession(String uid) async {
    final p = await SharedPreferences.getInstance();
    final prefix = 'user.$uid.';
    await Future.wait([
      p.remove('${prefix}bookmarks'),
      p.remove('${prefix}catalog'),
      p.remove('${prefix}progress'),
      p.remove('${prefix}adult'),
    ]);
  }
}
