import 'package:flutter_cache_manager/flutter_cache_manager.dart';

abstract final class MangaImageCache {
  // CacheManager bounds the on-disk cache by entry count. Flutter's decoded
  // in-memory image cache is bounded separately during app startup.
  static final CacheManager instance = CacheManager(
    Config(
      'mangaImagesV1',
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 400,
    ),
  );
}
