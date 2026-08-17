import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/storage/image_cache.dart';

class CoverArt extends StatelessWidget {
  const CoverArt(
      {super.key,
      required this.url,
      required this.title,
      this.borderRadius = 16});
  final String url, title;
  final double borderRadius;
  @override
  Widget build(BuildContext context) => DecoratedBox(
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: const [
            BoxShadow(
                color: Color(0x59000000), blurRadius: 18, offset: Offset(0, 10))
          ]),
      child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: AspectRatio(
              aspectRatio: .68,
              child: Stack(fit: StackFit.expand, children: [
                url.isEmpty
                    ? _fallback()
                    : CachedNetworkImage(
                        imageUrl: url,
                        cacheManager: MangaImageCache.instance,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => _fallback(),
                        errorWidget: (_, __, ___) => _fallback()),
                DecoratedBox(
                    decoration: BoxDecoration(
                        border: Border.all(color: AppColors.outline),
                        borderRadius: BorderRadius.circular(borderRadius)))
              ]))));
  Widget _fallback() => Container(
      decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF39325F), Color(0xFF1A1923)])),
      padding: const EdgeInsets.all(14),
      alignment: Alignment.bottomLeft,
      child: Text(title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: AppColors.text,
              fontWeight: FontWeight.w700,
              fontSize: 16)));
}
