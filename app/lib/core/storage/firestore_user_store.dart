import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/manga.dart';
import '../models/reading_progress.dart';
import 'user_store.dart';

class FirestoreUserStore implements UserStore {
  FirestoreUserStore({FirebaseFirestore? firestore, UserStore? local})
    : _db = firestore ?? FirebaseFirestore.instance,
      _local = local ?? const LocalUserStore();
  final FirebaseFirestore _db;
  final UserStore _local;
  @override
  Future<UserSnapshot> load(String uid) async {
    final local = await _local.load(uid);
    try {
      final user = _db.collection('users').doc(uid);
      final results = await Future.wait([
        user.collection('bookmarks').get(),
        user.collection('progress').get(),
        user.get(),
      ]);
      final bookmarks = (results[0] as QuerySnapshot<Map<String, dynamic>>).docs
          .map((d) => d.id)
          .toSet();
      final progress = <String, ReadingProgress>{};
      for (final doc
          in (results[1] as QuerySnapshot<Map<String, dynamic>>).docs) {
        final data = doc.data();
        final stamp = data['updatedAt'];
        progress[doc.id] = ReadingProgress.fromJson({
          ...data,
          'updatedAt': stamp is Timestamp
              ? stamp.toDate().toIso8601String()
              : stamp,
        });
      }
      final settings = (results[2] as DocumentSnapshot<Map<String, dynamic>>)
          .data();
      return UserSnapshot(
        bookmarks: bookmarks,
        bookmarkedManga: {
          for (final id in bookmarks)
            if (local.bookmarkedManga[id] case final manga?) id: manga,
        },
        progress: progress,
        adultContent: settings?['adultContent'] as bool? ?? false,
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
    await _local.saveBookmarks(uid, ids, manga);
    final ref = _db.collection('users').doc(uid).collection('bookmarks');
    final current = await ref.get();
    final batch = _db.batch();
    for (final doc in current.docs) {
      if (!ids.contains(doc.id)) batch.delete(doc.reference);
    }
    for (final id in ids) {
      batch.set(ref.doc(id), {
        'mangaId': id,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
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
  Future<void> saveAdultContent(String uid, bool enabled) async {
    await _local.saveAdultContent(uid, enabled);
    await _db.collection('users').doc(uid).set({
      'adultContent': enabled,
    }, SetOptions(merge: true));
  }

  @override
  Future<void> clearSession(String uid) => _local.clearSession(uid);
}
