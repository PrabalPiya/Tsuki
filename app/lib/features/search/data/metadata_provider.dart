import '../../../core/models/manga.dart';

abstract interface class MetadataProvider {
  String get id;
  Future<List<Manga>> search(String query, {required bool includeAdult});
  Future<Manga?> getById(String id);
}

abstract interface class SynopsisService {
  String summarize(String rawDescription);
}

class DeterministicSynopsisService implements SynopsisService {
  const DeterministicSynopsisService();
  @override
  String summarize(String rawDescription) {
    final plain = rawDescription
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'[_*~`>#]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (plain.isEmpty) return 'Synopsis unavailable.';
    final sentences = plain
        .split(RegExp(r'(?<=[.!?])\s+'))
        .where((v) => v.length > 20)
        .take(8)
        .toList();
    final selected = sentences.isEmpty ? plain : sentences.join(' ');
    return selected.length <= 1000
        ? selected
        : '${selected.substring(0, 997).trimRight()}…';
  }
}
