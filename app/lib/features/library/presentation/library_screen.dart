import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/manga.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/cover_art.dart';
import '../../../shared/widgets/one_time_hint.dart';

/* ===========================================================
 * LIBRARY PROVIDER
 * ========================================================= */

final libraryItemsProvider = FutureProvider.autoDispose<List<Manga>>((
  ref,
) async {
  final state = ref.watch(
    userLibraryProvider.select(
      (value) => (
        bookmarks: value.bookmarks,
        bookmarkedManga: value.bookmarkedManga,
        adultContent: value.adultContent,
      ),
    ),
  );

  final repository = ref.watch(catalogProvider);

  final items = <Manga>[];

  for (final id in state.bookmarks) {
    try {
      final manga =
          repository.cached(id) ??
          state.bookmarkedManga[id] ??
          await repository.details(id);

      if (manga != null) {
        repository.remember(manga);
        items.add(manga);
        if (manga.isAdult == state.adultContent) {
          unawaited(
            repository.prewarmChapters(manga, allowAdult: state.adultContent),
          );
        }
      }
    } catch (_) {
      // Keep loading other bookmarks.
    }
  }

  items.sort((a, b) => a.title.compareTo(b.title));

  return items;
});

/* ===========================================================
 * DRAG METRICS
 * ========================================================= */

class _DragMetrics {
  const _DragMetrics({
    required this.pull,
    required this.active,
    required this.target,
  });

  final double pull;
  final bool active;
  final Offset? target;
}

/* ===========================================================
 * LIBRARY SCREEN
 * ========================================================= */

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  bool _dragging = false;
  bool _removeActive = false;

  final GlobalKey _removeTargetKey = GlobalKey();

  static const double _pullStartDistance = 175.0;

  static const double _deleteDistance = 78.0;

  Offset? _removeTargetCenter() {
    final targetContext = _removeTargetKey.currentContext;

    if (targetContext == null) {
      return null;
    }

    final box = targetContext.findRenderObject() as RenderBox?;

    if (box == null || !box.hasSize) {
      return null;
    }

    return box.localToGlobal(
      Offset(box.size.width / 2.0, box.size.height / 2.0),
    );
  }

  void _startDrag() {
    HapticFeedback.mediumImpact();

    if (!mounted) return;

    setState(() {
      _dragging = true;
      _removeActive = false;
    });
  }

  _DragMetrics _dragMetrics(Offset finger) {
    final target = _removeTargetCenter();

    if (target == null) {
      return const _DragMetrics(pull: 0.0, active: false, target: null);
    }

    final double distance = (finger - target).distance;

    final bool active = distance <= _deleteDistance;

    double pull = 0.0;

    if (distance <= _deleteDistance) {
      pull = 1.0;
    } else if (distance < _pullStartDistance) {
      final double raw =
          1.0 -
          ((distance - _deleteDistance) /
              (_pullStartDistance - _deleteDistance));

      pull = Curves.easeInCubic.transform(raw.clamp(0.0, 1.0).toDouble());
    }

    if (active != _removeActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;

        if (_removeActive == active) {
          return;
        }

        setState(() {
          _removeActive = active;
        });

        if (active) {
          HapticFeedback.selectionClick();
        }
      });
    }

    return _DragMetrics(pull: pull, active: active, target: target);
  }

  void _cancelDrag() {
    if (!mounted) return;

    setState(() {
      _dragging = false;
      _removeActive = false;
    });
  }

  void _removeManga(Manga manga) {
    HapticFeedback.mediumImpact();

    ref.read(userLibraryProvider.notifier).toggleBookmark(manga);

    if (!mounted) return;

    setState(() {
      _dragging = false;
      _removeActive = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final libraryState = ref.watch(userLibraryProvider);

    final itemsState = ref.watch(libraryItemsProvider);

    final allItems = itemsState.valueOrNull ?? const <Manga>[];

    /*
     * Adult visibility filter only.
     */
    final items = allItems
        .where((manga) => manga.isAdult == libraryState.adultContent)
        .toList();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,

        title: Text(libraryState.adultContent ? 'Adult Library' : 'Library'),

        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),

            child: IconButton(
              onPressed: () {
                context.push('/settings');
              },

              icon: const Icon(Icons.settings_outlined),

              tooltip: 'Settings',
            ),
          ),
        ],
      ),

      body: Stack(
        children: [
          Positioned.fill(
            child: _buildContent(libraryState, itemsState, items, allItems),
          ),

          /*
           * ONE-TIME HINT.
           *
           * SharedPreferences ensures this is
           * shown only once per installation.
           */
          if (items.isNotEmpty && !_dragging)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 28,
              child: Center(
                child: OneTimeHint(
                  id: 'library_drag_remove',
                  icon: Icons.touch_app_rounded,
                  text: 'Hold & drag down to remove',
                ),
              ),
            ),

          /*
           * Background blur.
           */
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                opacity: _dragging ? 1.0 : 0.0,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
                  child: Container(color: Colors.black.withValues(alpha: 0.48)),
                ),
              ),
            ),
          ),

          /*
           * Delete target.
           */
          AnimatedPositioned(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutBack,
            left: 0.0,
            right: 0.0,
            bottom: _dragging ? 12.0 : -90.0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: _dragging ? 1.0 : 0.0,
                child: _RemoveButton(
                  key: _removeTargetKey,
                  active: _removeActive,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
    dynamic libraryState,
    AsyncValue<List<Manga>> itemsState,
    List<Manga> items,
    List<Manga> allItems,
  ) {
    if (libraryState.loading || itemsState.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (itemsState.hasError) {
      return _LibraryMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Library unavailable',
        message: 'Your library could not be loaded right now.',
        actionLabel: 'Retry',
        onAction: () {
          ref.invalidate(libraryItemsProvider);
        },
      );
    }

    if (items.isEmpty && allItems.isNotEmpty) {
      return _LibraryMessage(
        icon: Icons.visibility_off_rounded,
        title: libraryState.adultContent
            ? 'No adult bookmarks in this mode'
            : 'Adult bookmarks hidden',
        message: libraryState.adultContent
            ? 'Your normal bookmarks remain saved and return when Adult Mode is turned off.'
            : 'Your adult bookmarks remain saved and return when Adult Mode is turned on.',
      );
    }

    if (items.isEmpty) {
      return const _LibraryMessage(
        icon: Icons.bookmark_border_rounded,
        title: 'Your library is empty',
        message: 'Manga you bookmark will appear here.',
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.60,
        crossAxisSpacing: 14,
        mainAxisSpacing: 18,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        return _LibraryItem(
          manga: items[index],
          onDragStarted: _startDrag,
          dragMetrics: _dragMetrics,
          onCancel: _cancelDrag,
          onRemove: _removeManga,
        );
      },
    );
  }
}

/* ===========================================================
 * LIBRARY ITEM
 * ========================================================= */

class _LibraryItem extends StatefulWidget {
  const _LibraryItem({
    required this.manga,
    required this.onDragStarted,
    required this.dragMetrics,
    required this.onCancel,
    required this.onRemove,
  });

  final Manga manga;

  final VoidCallback onDragStarted;

  final _DragMetrics Function(Offset position) dragMetrics;

  final VoidCallback onCancel;

  final ValueChanged<Manga> onRemove;

  @override
  State<_LibraryItem> createState() => _LibraryItemState();
}

class _LibraryItemState extends State<_LibraryItem> {
  OverlayEntry? _overlay;

  bool _dragging = false;
  bool _deleting = false;

  Offset _finger = Offset.zero;

  double _pull = 0.0;

  Offset? _target;

  Size _size = Size.zero;

  void _onLongPressStart(LongPressStartDetails details) {
    final box = context.findRenderObject() as RenderBox?;

    if (box == null) return;

    _size = box.size;
    _finger = details.globalPosition;

    _dragging = true;

    widget.onDragStarted();

    _updateMetrics(_finger);

    _overlay = OverlayEntry(
      builder: (context) {
        return _FloatingManga(
          manga: widget.manga,
          finger: _finger,
          size: _size,
          target: _target,
          pull: _pull,
          deleting: _deleting,
        );
      },
    );

    Overlay.of(context).insert(_overlay!);

    setState(() {});
  }

  void _onLongPressMove(LongPressMoveUpdateDetails details) {
    if (!_dragging || _deleting) {
      return;
    }

    _finger = details.globalPosition;

    _updateMetrics(_finger);

    _overlay?.markNeedsBuild();
  }

  void _updateMetrics(Offset position) {
    final metrics = widget.dragMetrics(position);

    _pull = metrics.pull;

    _target = metrics.target;
  }

  Future<void> _onLongPressEnd(LongPressEndDetails details) async {
    if (!_dragging || _deleting) {
      return;
    }

    final metrics = widget.dragMetrics(details.globalPosition);

    _pull = metrics.pull;

    _target = metrics.target;

    if (metrics.active && _target != null) {
      await _animateDelete();
    } else {
      _cancel();
    }
  }

  Future<void> _animateDelete() async {
    _deleting = true;
    _pull = 1.0;

    _overlay?.markNeedsBuild();

    HapticFeedback.selectionClick();

    await Future.delayed(const Duration(milliseconds: 220));

    _removeOverlay();

    if (mounted) {
      setState(() {
        _dragging = false;
        _deleting = false;
      });
    }

    widget.onRemove(widget.manga);
  }

  void _cancel() {
    _removeOverlay();

    _dragging = false;
    _deleting = false;

    if (mounted) {
      setState(() {});
    }

    widget.onCancel();
  }

  void _removeOverlay() {
    _overlay?.remove();

    _overlay = null;
  }

  @override
  void dispose() {
    _removeOverlay();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,

      onLongPressStart: _onLongPressStart,

      onLongPressMoveUpdate: _onLongPressMove,

      onLongPressEnd: _onLongPressEnd,

      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),

        curve: Curves.easeOutCubic,

        opacity: _dragging ? 0.12 : 1.0,

        child: _LibraryMangaTile(manga: widget.manga),
      ),
    );
  }
}

/* ===========================================================
 * FLOATING MANGA
 * ========================================================= */

class _FloatingManga extends StatefulWidget {
  const _FloatingManga({
    required this.manga,
    required this.finger,
    required this.size,
    required this.target,
    required this.pull,
    required this.deleting,
  });

  final Manga manga;
  final Offset finger;
  final Size size;
  final Offset? target;
  final double pull;
  final bool deleting;

  @override
  State<_FloatingManga> createState() => _FloatingMangaState();
}

class _FloatingMangaState extends State<_FloatingManga> {
  bool _entered = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      setState(() {
        _entered = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final Offset targetCenter = widget.target ?? widget.finger;

    final double attraction = widget.deleting ? 1.0 : widget.pull * 0.34;

    final Offset displayCenter = Offset.lerp(
      widget.finger,
      targetCenter,
      attraction,
    )!;

    final double liftedScale = _entered ? 1.04 : 1.0;

    final double scale = widget.deleting
        ? 0.05
        : liftedScale - (widget.pull * 0.54);

    final double rawOpacity = widget.deleting
        ? 0.0
        : 1.0 - (widget.pull * 0.16);

    final double opacity = rawOpacity.clamp(0.0, 1.0).toDouble();

    final double lift = _entered ? 6.0 : 0.0;

    return AnimatedPositioned(
      duration: Duration(milliseconds: widget.deleting ? 220 : 75),

      curve: widget.deleting ? Curves.easeInCubic : Curves.easeOutCubic,

      left: displayCenter.dx - widget.size.width / 2.0,

      top: displayCenter.dy - widget.size.height / 2.0 - lift,

      child: IgnorePointer(
        child: AnimatedScale(
          duration: Duration(milliseconds: widget.deleting ? 220 : 180),

          curve: widget.deleting ? Curves.easeInCubic : Curves.easeOutCubic,

          scale: scale,

          child: AnimatedOpacity(
            duration: Duration(milliseconds: widget.deleting ? 180 : 130),

            curve: Curves.easeOut,

            opacity: opacity,

            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),

              curve: Curves.easeOutCubic,

              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),

                boxShadow: _entered
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.48),
                          blurRadius: 28,
                          spreadRadius: 1,
                          offset: const Offset(0, 12),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
              ),

              child: Material(
                color: Colors.transparent,

                child: SizedBox(
                  width: widget.size.width,

                  height: widget.size.height,

                  child: _LibraryMangaTile(
                    manga: widget.manga,

                    interactive: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/* ===========================================================
 * TILE
 * ========================================================= */

class _LibraryMangaTile extends StatelessWidget {
  const _LibraryMangaTile({required this.manga, this.interactive = true});

  final Manga manga;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,

      children: [
        Expanded(
          child: CoverArt(
            url: manga.coverUrl,

            title: manga.title,

            borderRadius: 16,
          ),
        ),

        const SizedBox(height: 10),

        Text(
          manga.title,

          maxLines: 1,

          overflow: TextOverflow.ellipsis,

          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700, height: 1.2),
        ),
      ],
    );

    if (!interactive) {
      return content;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(18),

      onTap: () {
        context.push('/manga/${Uri.encodeComponent(manga.id)}');
      },

      child: content,
    );
  }
}

/* ===========================================================
 * REMOVE BUTTON
 * ========================================================= */

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({super.key, required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AnimatedScale(
        duration: const Duration(milliseconds: 150),

        curve: Curves.easeOutCubic,

        scale: active ? 1.06 : 1.0,

        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),

          curve: Curves.easeOutCubic,

          height: 56,

          padding: const EdgeInsets.symmetric(horizontal: 18),

          decoration: BoxDecoration(
            color: active ? AppColors.danger : AppColors.raised,

            borderRadius: BorderRadius.circular(18),

            border: Border.all(
              color: active
                  ? Colors.white.withValues(alpha: 0.18)
                  : AppColors.outline,
            ),

            boxShadow: [
              BoxShadow(
                color: active
                    ? AppColors.danger.withValues(alpha: 0.34)
                    : Colors.black.withValues(alpha: 0.30),

                blurRadius: active ? 28 : 18,

                spreadRadius: active ? 2 : 0,

                offset: const Offset(0, 7),
              ),
            ],
          ),

          child: Row(
            mainAxisSize: MainAxisSize.min,

            children: [
              Icon(
                active ? Icons.delete_rounded : Icons.delete_outline_rounded,

                size: 21,

                color: active ? Colors.white : AppColors.muted,
              ),

              const SizedBox(width: 9),

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 120),

                child: Text(
                  active ? 'Release to remove' : 'Remove bookmark',

                  key: ValueKey<bool>(active),

                  style: TextStyle(
                    color: active ? Colors.white : AppColors.text,

                    fontSize: 14,

                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ===========================================================
 * MESSAGE
 * ========================================================= */

class _LibraryMessage extends StatelessWidget {
  const _LibraryMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;

  final String? actionLabel;

  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),

        child: Column(
          mainAxisSize: MainAxisSize.min,

          children: [
            Container(
              width: 58,
              height: 58,

              decoration: BoxDecoration(
                color: AppColors.raised.withValues(alpha: 0.65),

                borderRadius: BorderRadius.circular(18),

                border: Border.all(color: AppColors.outline),
              ),

              child: Icon(icon, size: 27, color: AppColors.accent),
            ),

            const SizedBox(height: 18),

            Text(
              title,

              textAlign: TextAlign.center,

              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),

            const SizedBox(height: 7),

            Text(
              message,

              textAlign: TextAlign.center,

              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: AppColors.muted, height: 1.4),
            ),

            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),

              OutlinedButton.icon(
                onPressed: onAction,

                icon: const Icon(Icons.refresh_rounded),

                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
