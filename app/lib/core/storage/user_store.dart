import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/manga.dart';
import '../models/reading_progress.dart';

class UserSnapshot {
  const UserSnapshot(
      {required this.bookmarks,
      required this.bookmarkedManga,
      required this.progress,
      required this.adultContent});
  final Set<String> bookmarks;
  final Map<String, Manga> bookmarkedManga;
  final Map<String, ReadingProgress> progress;
  final bool adultContent;
}

abstract interface class UserStore {
  Future<UserSnapshot> load(String uid);
  Future<void> saveBookmarks(
      String uid, Set<String> ids, Map<String, Manga> manga);
  Future<void> saveProgress(String uid, ReadingProgress progress);
  Future<void> saveAdultContent(String uid, bool enabled);
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
            bookmarkedManga[entry.key] =
                Manga.fromJson(entry.value as Map<String, dynamic>);
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
            progress[entry.key] =
                ReadingProgress.fromJson(entry.value as Map<String, dynamic>);
          } catch (_) {
            // Keep valid progress if one legacy entry is malformed.
          }
        }
      } catch (_) {
        // A corrupt local progress blob should never prevent app startup.
      }
    }
    return UserSnapshot(
        bookmarks: bookmarks,
        bookmarkedManga: bookmarkedManga,
        progress: progress,
        adultContent: p.getBool('${prefix}adult') ?? false);
  }

  @override
  Future<void> saveBookmarks(
      String uid, Set<String> ids, Map<String, Manga> manga) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('user.$uid.bookmarks', ids.toList());
    await p.setString('user.$uid.catalog',
        jsonEncode(manga.map((key, value) => MapEntry(key, value.toJson()))));
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
  Future<void> saveAdultContent(String uid, bool enabled) async {
    await (await SharedPreferences.getInstance())
        .setBool('user.$uid.adult', enabled);
  }

  @override
  Future<void> clearSession(String uid) async {
    final p = await SharedPreferences.getInstance();
    final prefix = 'user.$uid.';
    await Future.wait([
      p.remove('${prefix}bookmarks'),
      p.remove('${prefix}catalog'),
      p.remove('${prefix}progress'),
      p.remove('${prefix}adult')
    ]);
  }
}
