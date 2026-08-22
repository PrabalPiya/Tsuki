import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/manga.dart';
import '../models/reading_progress.dart';
import 'user_store.dart';

class FirestoreUserStore implements UserStore {
  FirestoreUserStore({FirebaseFirestore? firestore, UserStore? local})
    : _db = firestore ?? FirebaseFirestore.instance,
      _local = local ?? LocalUserStore();

  final FirebaseFirestore _db;
  final UserStore _local;
  final Map<String, Set<String>> _remoteBookmarkIds = {};

  @override
  Future<UserSnapshot> load(String uid) async {
    final local = await _local.load(uid);
    try {
      final user = _db.collection('users').doc(uid);
      final results = await Future.wait([
        user.collection('bookmarks').get(),
        user.collection('progress').get(),
      ]);

      final bookmarkDocs = results[0].docs;
      final remoteManga = <String, Manga>{};
      for (final doc in bookmarkDocs) {
        final data = doc.data();
        final rawManga = data['manga'];
        if (rawManga is Map) {
          try {
            final manga = Manga.fromJson(Map<String, dynamic>.from(rawManga));
            if (manga.isFriendlyContent) remoteManga[doc.id] = manga;
          } catch (_) {
            // Ignore malformed remote bookmark metadata.
          }
        }
      }

      final mergedManga = {...local.bookmarkedManga, ...remoteManga};
      final remoteBookmarks = bookmarkDocs.map((d) => d.id).toSet();
      _remoteBookmarkIds[uid] = remoteBookmarks;
      final safeBookmarks = remoteBookmarks
          .where((id) => mergedManga[id]?.isFriendlyContent == true)
          .toSet();

      final progress = <String, ReadingProgress>{...local.progress};
      for (final doc in results[1].docs) {
        final data = doc.data();
        final stamp = data['updatedAt'];
        final remote = ReadingProgress.fromJson({
          ...data,
          'updatedAt': stamp is Timestamp
              ? stamp.toDate().toIso8601String()
              : stamp,
        });
        final localValue = progress[doc.id];
        if (localValue == null ||
            remote.updatedAt.isAfter(localValue.updatedAt)) {
          progress[doc.id] = remote;
        }
      }

      final safeBookmarkedManga = <String, Manga>{};
      for (final id in safeBookmarks) {
        final manga = mergedManga[id];
        if (manga != null) safeBookmarkedManga[id] = manga;
      }

      return UserSnapshot(
        bookmarks: safeBookmarks,
        bookmarkedManga: safeBookmarkedManga,
        progress: progress,
      );
    } catch (_) {
      return local;
    }
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
    final safeIds = ids.where((id) => !blockedIds.contains(id)).toSet();

    await _local.saveBookmarks(uid, safeIds, safeManga);
    final ref = _db.collection('users').doc(uid).collection('bookmarks');
    final previous =
        _remoteBookmarkIds[uid] ??
        (await ref.get()).docs.map((document) => document.id).toSet();
    final removed = previous.difference(safeIds);
    final added = safeIds.difference(previous);
    if (removed.isEmpty && added.isEmpty) return;

    final batch = _db.batch();

    for (final id in removed) {
      batch.delete(ref.doc(id));
    }
    for (final id in added) {
      final manga = safeManga[id];
      final data = <String, Object?>{
        'mangaId': id,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (manga != null) data['manga'] = manga.toJson();
      batch.set(ref.doc(id), data);
    }
    await batch.commit();
    _remoteBookmarkIds[uid] = Set<String>.unmodifiable(safeIds);
  }

  @override
  Future<void> saveProgress(String uid, ReadingProgress value) async {
    await _local.saveProgress(uid, value);
    await _db
        .collection('users')
        .doc(uid)
        .collection('progress')
        .doc(value.mangaId)
        .set({...value.toJson(), 'updatedAt': FieldValue.serverTimestamp()});
  }

  @override
  Future<void> clearSession(String uid) => _local.clearSession(uid);
}
