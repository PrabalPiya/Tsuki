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
      _total = _selectedCount(preview);
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
      final importedCount = await ref
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
      if (importedCount == 0) {
        setState(() {
          _error = 'No selected manga could be verified. Review the matches and try again.';
        });
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            importedCount == 1
                ? 'Imported 1 manga into your library.'
                : 'Imported $importedCount manga into your library.',
          ),
        ),
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = 'The library could not be updated.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  int _selectedCount(ImportPreview preview) {
    var count = 0;
    for (var index = 0; index < preview.matches.length; index++) {
      final status = preview.matches[index].status;
      if (status == ImportMatchStatus.matched ||
          status == ImportMatchStatus.conflict ||
          _reviewChoices[index] != null) {
        count++;
      }
    }
    return count;
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
              matches: [
                for (var index = 0; index < preview.matches.length; index++)
                  if (preview.matches[index].status ==
                      ImportMatchStatus.unmatched)
                    (index: index, match: preview.matches[index]),
              ],
              choices: _reviewChoices,
              onChanged: (index, value) => setState(() {
                _reviewChoices[index] = value;
              }),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _working || _selectedCount(preview) == 0
                  ? null
                  : _commit,
              child: Text(
                _selectedCount(preview) == 0
                    ? 'Select manga to import'
                    : 'Import selected manga',
              ),
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
  const _UnmatchedSection({
    required this.matches,
    required this.choices,
    required this.onChanged,
  });

  final List<({int index, ImportMatch match})> matches;
  final Map<int, Manga?> choices;
  final void Function(int index, Manga? value) onChanged;

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
          'Search for each title and select the correct manga, or leave it skipped.',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        children: [
          const Divider(height: 1),
          for (final item in matches)
            _ManualMatchItem(
              key: ValueKey(item.match.entry.sourceKey),
              match: item.match,
              value: choices[item.index],
              onChanged: (value) => onChanged(item.index, value),
            ),
        ],
      ),
    );
  }
}

class _ManualMatchItem extends ConsumerStatefulWidget {
  const _ManualMatchItem({
    super.key,
    required this.match,
    required this.value,
    required this.onChanged,
  });

  final ImportMatch match;
  final Manga? value;
  final ValueChanged<Manga?> onChanged;

  @override
  ConsumerState<_ManualMatchItem> createState() => _ManualMatchItemState();
}

class _ManualMatchItemState extends ConsumerState<_ManualMatchItem> {
  late final TextEditingController _query = TextEditingController(
    text: widget.match.entry.title,
  );
  List<Manga> _results = const [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.length < 2) {
      setState(() => _error = 'Enter at least 2 characters.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await ref.read(catalogProvider).searchMetadataOnly(query);
      if (!mounted) return;
      setState(() {
        _results = results.take(8).toList(growable: false);
        if (_results.isEmpty) _error = 'No manga matched this title.';
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Search failed. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.match.entry.title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: 'Find this manga',
              suffixIcon: IconButton(
                onPressed: _loading ? null : _search,
                tooltip: 'Search metadata',
                icon: _loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search_rounded),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(
              _error!,
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ],
          if (widget.value != null) ...[
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check_circle, color: AppColors.accent),
              title: Text(widget.value!.title),
              subtitle: const Text('Selected for import'),
              trailing: IconButton(
                onPressed: () => widget.onChanged(null),
                tooltip: 'Clear selection',
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
          for (final manga in _results)
            if (manga.id != widget.value?.id)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(
                  width: 36,
                  height: 52,
                  child: CoverArt(
                    url: manga.coverUrl,
                    title: manga.title,
                    borderRadius: 6,
                  ),
                ),
                title: Text(
                  manga.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(manga.publicationTypeLabel),
                trailing: const Icon(Icons.add_circle_outline_rounded),
                onTap: () => widget.onChanged(manga),
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
