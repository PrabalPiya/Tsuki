import 'package:flutter_cache_manager/flutter_cache_manager.dart';

abstract final class MangaImageCache {
  // CacheManager bounds by count rather than bytes. 400 full-resolution pages
  // is an intentionally conservative approximation of the 400 MB default;
  // age eviction prevents a normal user from needing maintenance controls.
  static final CacheManager instance = CacheManager(
    Config(
      'mangaImagesV1',
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 400,
    ),
  );
}
