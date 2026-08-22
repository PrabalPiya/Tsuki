import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/storage/image_cache.dart';

class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    required this.url,
    required this.title,
    this.borderRadius = 16,
  });
  final String url, title;
  final double borderRadius;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(borderRadius),
    child: AspectRatio(
      aspectRatio: .68,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final logicalWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final decodeWidth =
              (logicalWidth * MediaQuery.devicePixelRatioOf(context))
                  .ceil()
                  .clamp(64, 1200);

          return Stack(
            fit: StackFit.expand,
            children: [
              url.isEmpty
                  ? _fallback()
                  : CachedNetworkImage(
                      imageUrl: url,
                      cacheManager: MangaImageCache.instance,
                      memCacheWidth: decodeWidth,
                      fit: BoxFit.cover,
                      fadeInDuration: const Duration(milliseconds: 120),
                      fadeOutDuration: Duration.zero,
                      placeholder: (_, _) => _fallback(),
                      errorWidget: (_, _, _) => _fallback(),
                    ),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.outline),
                  borderRadius: BorderRadius.circular(borderRadius),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
  Widget _fallback() => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF39325F), Color(0xFF1A1923)],
      ),
    ),
    padding: const EdgeInsets.all(14),
    alignment: Alignment.bottomLeft,
    child: Text(
      title,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: AppColors.text,
        fontWeight: FontWeight.w700,
        fontSize: 16,
      ),
    ),
  );
}
