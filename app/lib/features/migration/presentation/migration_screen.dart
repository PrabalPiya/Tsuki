import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../core/models/manga.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/cover_art.dart';
import '../data/migration_models.dart';
import '../data/migration_service.dart';

class MigrationScreen extends ConsumerStatefulWidget {
  const MigrationScreen({super.key});

  @override
  ConsumerState<MigrationScreen> createState() => _MigrationScreenState();
}

class _MigrationScreenState extends ConsumerState<MigrationScreen> {
  final Map<int, Manga?> _reviewChoices = {};
  ImportPreview? _preview;
  String? _selectedFileName;
  String? _error;
  int _completed = 0;
  int _total = 0;
  bool _working = false;

  Future<void> _selectAndPrepare() async {
    setState(() {
      _working = true;
      _error = null;
      _completed = 0;
      _total = 0;
    });
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || !mounted) return;

      final file = result.files.single;

      setState(() {
        _selectedFileName = file.name;
        _preview = null;
        _reviewChoices.clear();
      });

      if (file.size > MigrationValidator.maxBytes) {
        throw const MigrationValidationException(
          'Migration file is too large.',
        );
      }

      final bytes = file.bytes;
      if (bytes == null) {
        throw const MigrationValidationException(
          'The selected file could not be read.',
        );
      }
      final rawJson = utf8.decode(bytes);
      if (!mounted) return;
      final preview = await ref
          .read(migrationServiceProvider)
          .prepare(
            rawJson,
            existingProgress: ref.read(userLibraryProvider).progress,
            onProgress: (completed, total) {
              if (mounted) {
                setState(() {
                  _completed = completed;
                  _total = total;
                });
              }
            },
          );
      if (mounted) {
        setState(() {
          _preview = preview;
        });
      }
    } on MigrationValidationException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FormatException {
      if (mounted) {
        setState(() => _error = 'The selected file is not valid UTF-8 JSON.');
      }
    } on MissingPluginException {
      if (mounted) {
        setState(
          () => _error = 'The file picker is not ready. Fully stop and restart the app, then try again.',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        final detail = error.message?.trim();
        setState(
          () => _error = detail == null || detail.isEmpty
              ? 'The file picker could not be opened.'
              : 'The file picker could not be opened: $detail',
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Migration file selection failed: $error\n$stackTrace');
      if (mounted) {
        setState(() => _error = 'The migration file could not be opened.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _commit() async {
    final preview = _preview;
    if (preview == null) return;
    setState(() {
      _working = true;
      _error = null;
      _completed = 0;
      _total = preview.matches.where((match) {
        final selected =
            match.status == ImportMatchStatus.matched ||
            match.status == ImportMatchStatus.conflict ||
            _reviewChoices[preview.matches.indexOf(match)] != null;
        return selected;
      }).length;
    });
    try {
      final resolved = <ImportMatch>[];
      for (var index = 0; index < preview.matches.length; index++) {
        final match = preview.matches[index];
        final choice = _reviewChoices[index];
        resolved.add(
          choice == null
              ? match
              : ImportMatch(
                  entry: match.entry,
                  status: ImportMatchStatus.matched,
                  manga: choice,
                  confidence: match.confidence,
                ),
        );
      }
      await ref
          .read(migrationServiceProvider)
          .commit(
            ImportPreview(document: preview.document, matches: resolved),
            ref.read(userLibraryProvider.notifier),
            onEnrichmentProgress: (completed, total) {
              if (!mounted) return;
              setState(() {
                _completed = completed;
                _total = total;
              });
            },
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Migration imported into your library.')),
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = 'The library could not be updated.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Tsuki Migration')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Select the JSON file exported by the Tsuki browser extension. Manga bookmarks will be matched and imported.',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _working ? null : _selectAndPrepare,
            icon: const Icon(Icons.upload_file_rounded),
            label: Text(
              _preview == null ? 'Select export file' : 'Select another file',
            ),
          ),
          if (_selectedFileName != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(
                  Icons.description_outlined,
                  size: 16,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _selectedFileName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_working) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _total <= 0 ? null : _completed / _total,
            ),
            const SizedBox(height: 6),
            Text(
              _total <= 0
                  ? 'Reading file…'
                  : preview == null
                  ? 'Matched $_completed of $_total'
                  : 'Loading chapters $_completed of $_total',
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          if (preview != null) ...[
            const SizedBox(height: 20),
            _Summary(preview: preview),
            for (var index = 0; index < preview.matches.length; index++)
              if (preview.matches[index].status ==
                  ImportMatchStatus.needsReview)
                _ReviewItem(
                  match: preview.matches[index],
                  value: _reviewChoices[index],
                  onChanged: (value) => setState(() {
                    _reviewChoices[index] = value;
                  }),
                ),
            _UnmatchedSection(
              matches: preview.matches
                  .where((match) => match.status == ImportMatchStatus.unmatched)
                  .toList(growable: false),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _working ? null : _commit,
              child: const Text('Import matched manga'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.preview});
  final ImportPreview preview;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 18,
        runSpacing: 8,
        children: [
          Text('${preview.matches.length} entries'),
          Text('✓ ${preview.count(ImportMatchStatus.matched)} matched'),
          Text('? ${preview.count(ImportMatchStatus.needsReview)} review'),
          Text('! ${preview.count(ImportMatchStatus.conflict)} conflicts'),
          Text('× ${preview.count(ImportMatchStatus.unmatched)} unmatched'),
          Text('! ${preview.count(ImportMatchStatus.error)} errors'),
        ],
      ),
    ),
  );
}

class _UnmatchedSection extends StatelessWidget {
  const _UnmatchedSection({required this.matches});

  final List<ImportMatch> matches;

  @override
  Widget build(BuildContext context) {
    if (matches.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: ExpansionTile(
        leading: const Icon(Icons.search_off_rounded, color: AppColors.muted),
        title: Text(
          'Unmatched manga (${matches.length})',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: const Text(
          'These entries will be skipped during import.',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        children: [
          const Divider(height: 1),
          for (final match in matches)
            ListTile(
              dense: true,
              leading: const Icon(Icons.menu_book_outlined, size: 20),
              title: Text(match.entry.title),
              subtitle: Text(
                '${match.entry.source} · ${match.entry.rawChapter ?? 'no progress'}',
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReviewItem extends StatelessWidget {
  const _ReviewItem({
    required this.match,
    required this.value,
    required this.onChanged,
  });

  final ImportMatch match;
  final Manga? value;
  final ValueChanged<Manga?> onChanged;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            match.entry.title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            '${match.entry.source} · ${match.entry.rawChapter ?? 'no progress'}',
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          DropdownButton<Manga?>(
            isExpanded: true,
            itemHeight: 64,
            menuMaxHeight: 360,
            value: value,
            hint: const Text('Leave unmatched'),
            items: [
              const DropdownMenuItem<Manga?>(value: null, child: Text('Skip')),
              ...match.candidates.map(
                (candidate) => DropdownMenuItem<Manga?>(
                  value: candidate,
                  child: _ReviewCandidate(manga: candidate),
                ),
              ),
            ],
            onChanged: onChanged,
          ),
        ],
      ),
    ),
  );
}

class _ReviewCandidate extends StatelessWidget {
  const _ReviewCandidate({required this.manga});

  final Manga manga;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 34,
          height: 50,
          child: CoverArt(
            url: manga.coverUrl,
            title: manga.title,
            borderRadius: 6,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            manga.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
