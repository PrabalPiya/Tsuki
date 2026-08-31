// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../identity/manga_identity_resolver.dart';
import '../models/manga.dart';

class CanonicalAliasIndex {
  CanonicalAliasIndex({Future<SharedPreferences>? preferences})
    : _preferences = preferences;

  final Future<SharedPreferences>? _preferences;
  final Map<String, String> _memory = {};
  bool _loaded = false;

  static const _storageKey = 'tsuki.canonicalAliases.v1';

  Future<String?> lookup({
    String? provider,
    String? providerId,
    String? source,
    String? sourceId,
    String? title,
  }) async {
    await _load();
    final keys = <String>[
      if (provider != null && providerId != null) 'meta:$provider:$providerId',
      if (source != null && sourceId != null) 'source:$source:$sourceId',
      if (title != null) 'title:${MangaIdentityResolver.normalizeTitle(title)}',
    ];
    for (final key in keys) {
      final value = _memory[key];
      if (value != null) return value;
    }
    return null;
  }

  Future<void> learn(Manga manga) async {
    await _load();
    final canonicalId = manga.tsukiId;
    for (final entry in manga.allMetadataProviderIds.entries) {
      _memory['meta:${entry.key}:${entry.value}'] = canonicalId;
    }
    for (final entry in manga.allSourceMappings.entries) {
      _memory['source:${entry.key}:${entry.value}'] = canonicalId;
    }
    for (final title in <String>{manga.title, ...manga.aliases}) {
      final key = MangaIdentityResolver.normalizeTitle(title);
      if (key.isNotEmpty) _memory['title:$key'] = canonicalId;
    }
    await _save();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final preferences = _preferences;
    if (preferences == null) return;
    try {
      final decoded = jsonDecode(
        (await preferences).getString(_storageKey) ?? '{}',
      );
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.key is String && entry.value is String) {
            _memory[entry.key as String] = entry.value as String;
          }
        }
      }
    } catch (_) {
      // A corrupt cache is disposable; learned mappings will repopulate it.
    }
  }

  Future<void> _save() async {
    final preferences = _preferences;
    if (preferences == null) return;
    await (await preferences).setString(_storageKey, jsonEncode(_memory));
  }
}
