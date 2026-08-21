import 'dart:io';

import 'package:dio/dio.dart';
import 'package:tsuki/features/reader/data/mangadex_source.dart';
import 'package:tsuki/features/search/data/anilist_metadata_provider.dart';

Future<void> main(List<String> args) async {
  final queries = args.where((arg) => !arg.startsWith('--')).toList();
  final titles = queries.isEmpty
      ? const ['Naruto', 'One Piece', 'Berserk']
      : queries.take(3).toList(growable: false);
  final metadata = AniListMetadataProvider();
  final mangaDex = MangaDexSource();

  for (final query in titles) {
    stdout.writeln('');
    stdout.writeln('=== Search query: $query ===');
    try {
      final results = await metadata.search(query);
      if (results.isEmpty) {
        stdout.writeln('AniList returned no safe manga.');
        continue;
      }
      final manga = results.firstWhere(
        (value) => value.isFriendlyContent,
        orElse: () => results.first,
      );
      if (!manga.isFriendlyContent) {
        stdout.writeln('Only blocked results were returned.');
        continue;
      }
      stdout.writeln('Canonical title: ${manga.title}');
      stdout.writeln('AniList ID: ${manga.anilistId}');
      stdout.writeln('AniList aliases: ${manga.aliases.take(8).join(' | ')}');
      final diagnostic = await mangaDex.debugMangaDexFeed(manga);
      stdout.writeln(diagnostic);
    } on DioException catch (error) {
      stdout.writeln('[DioException]');
      stdout.writeln('uri: ${error.requestOptions.uri}');
      stdout.writeln('status: ${error.response?.statusCode}');
      stdout.writeln('body: ${error.response?.data}');
    }
  }
}
