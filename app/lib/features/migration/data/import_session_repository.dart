// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'migration_models.dart';

class ImportSessionRepository {
  ImportSessionRepository({Future<SharedPreferences>? preferences})
    : _preferences = preferences;

  final Future<SharedPreferences>? _preferences;
  final List<Map<String, Object?>> _memory = [];
  static const _key = 'tsuki.importSessions.v1';

  Future<String> record({
    required MigrationDocument document,
    required int matchedCount,
    required int needsReviewCount,
    required int unmatchedCount,
    required int conflictCount,
    required int errorCount,
    required Iterable<String> mangaIds,
  }) async {
    final now = DateTime.now();
    final id = 'import-${now.microsecondsSinceEpoch}';
    final session = <String, Object?>{
      'id': id,
      'createdAt': now.toIso8601String(),
      'sources': document.sources,
      'entryCount': document.entries.length,
      'matchedCount': matchedCount,
      'needsReviewCount': needsReviewCount,
      'unmatchedCount': unmatchedCount,
      'conflictCount': conflictCount,
      'errorCount': errorCount,
      'canonicalMangaIds': mangaIds.toSet().toList(),
    };
    final preferences = _preferences;
    if (preferences == null) {
      _memory.insert(0, session);
      if (_memory.length > 20) _memory.removeLast();
      return id;
    }
    final prefs = await preferences;
    List<dynamic> previous;
    try {
      previous = jsonDecode(prefs.getString(_key) ?? '[]') as List;
    } catch (_) {
      previous = [];
    }
    await prefs.setString(_key, jsonEncode([session, ...previous.take(19)]));
    return id;
  }
}
