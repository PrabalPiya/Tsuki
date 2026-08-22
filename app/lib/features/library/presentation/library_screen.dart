import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/manga.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/cover_art.dart';
import '../../../shared/widgets/one_time_hint.dart';
import '../../../shared/widgets/logout_button.dart';

/* ===========================================================
 * LIBRARY PROVIDER
 * ========================================================= */

final libraryItemsProvider = Provider<List<Manga>>((ref) {
  final state = ref.watch(
    userLibraryProvider.select(
      (value) =>
          (bookmarks: value.bookmarks, bookmarkedManga: value.bookmarkedManga),
    ),
  );

  final repository = ref.watch(catalogProvider);

  final items = <Manga>[];

  for (final id in state.bookmarks) {
    try {
      final manga = repository.cached(id) ?? state.bookmarkedManga[id];

      if (manga != null && manga.isFriendlyContent) {
        repository.remember(manga);
        items.add(manga);
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
  List<Manga> _lastItems = const <Manga>[];
  final Set<String> _exitingIds = <String>{};
  final Set<String> _hiddenIds = <String>{};

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

    if (mounted) {
      setState(() {
        _dragging = false;
        _removeActive = false;
        _exitingIds.add(manga.id);
      });
    }

    ref.read(userLibraryProvider.notifier).toggleBookmark(manga);

    Future<void>.delayed(const Duration(milliseconds: 170), () {
      if (!mounted) return;

      setState(() {
        _exitingIds.remove(manga.id);
        _hiddenIds.add(manga.id);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final libraryLoading = ref.watch(
      userLibraryProvider.select((state) => state.loading),
    );
    final freshItems = ref.watch(libraryItemsProvider);

    if (_exitingIds.isEmpty) {
      _lastItems = freshItems;
    } else if (_lastItems.isEmpty) {
      _lastItems = freshItems;
    }

    final freshIds = freshItems.map((manga) => manga.id).toSet();
    final settledIds = _hiddenIds.where((id) => !freshIds.contains(id)).toSet();

    if (settledIds.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;

        setState(() {
          _hiddenIds.removeAll(settledIds);
        });
      });
    }

    final sourceItems = _exitingIds.isEmpty ? freshItems : _lastItems;
    final items = sourceItems
        .where((manga) => !_hiddenIds.contains(manga.id))
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,

        title: const Text('Library'),

        actions: const [
          Padding(padding: EdgeInsets.only(right: 16), child: LogoutButton()),
        ],
      ),

      body: Stack(
        children: [
          Positioned.fill(child: _buildContent(libraryLoading, items)),

          if (items.isNotEmpty && !_dragging)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 28,
              child: Center(
                child: OneTimeHint(
                  id: 'library_drag_remove',
                  icon: Icons.touch_app_rounded,
                  text: 'Press and hold, then drag down to remove',
                ),
              ),
            ),

          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 210),
                curve: Curves.easeInOutCubic,
                opacity: _dragging ? 1.0 : 0.0,
                child: Container(color: Colors.black.withValues(alpha: 0.62)),
              ),
            ),
          ),

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

  Widget _buildContent(bool libraryLoading, List<Manga> items) {
    if (libraryLoading && _lastItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (items.isEmpty) {
      return const _LibraryMessage(
        icon: Icons.bookmark_border_rounded,
        title: 'Your library is empty',
        message: 'Manga you bookmark will appear here.',
      );
    }

    return _AnimatedLibraryGrid(
      items: items,
      exitingIds: _exitingIds,
      itemBuilder: (context, manga, exiting) {
        return _LibraryItem(
          manga: manga,
          exiting: exiting,
          onDragStarted: _startDrag,
          dragMetrics: _dragMetrics,
          onCancel: _cancelDrag,
          onRemove: _removeManga,
        );
      },
    );
  }
}

class _AnimatedLibraryGrid extends StatelessWidget {
  const _AnimatedLibraryGrid({
    required this.items,
    required this.exitingIds,
    required this.itemBuilder,
  });

  static const int _columns = 2;
  static const double _horizontalPadding = 16.0;
  static const double _topPadding = 12.0;
  static const double _bottomPadding = 18.0;
  static const double _crossAxisSpacing = 14.0;
  static const double _mainAxisSpacing = 18.0;
  static const double _childAspectRatio = 0.60;

  final List<Manga> items;
  final Set<String> exitingIds;
  final Widget Function(BuildContext context, Manga manga, bool exiting)
  itemBuilder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gridWidth =
            constraints.maxWidth - (_horizontalPadding * 2) - _crossAxisSpacing;
        final tileWidth = gridWidth / _columns;
        final tileHeight = tileWidth / _childAspectRatio;
        final rows = (items.length / _columns).ceil();
        final rowGaps = rows <= 0 ? 0 : rows - 1;
        final contentHeight =
            _topPadding +
            _bottomPadding +
            (rows * tileHeight) +
            (rowGaps * _mainAxisSpacing);

        return SingleChildScrollView(
          child: SizedBox(
            height: contentHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var index = 0; index < items.length; index++)
                  AnimatedPositioned(
                    key: ValueKey(items[index].id),
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    left:
                        _horizontalPadding +
                        (index % _columns) * (tileWidth + _crossAxisSpacing),
                    top:
                        _topPadding +
                        (index ~/ _columns) * (tileHeight + _mainAxisSpacing),
                    width: tileWidth,
                    height: tileHeight,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOutCubic,
                      opacity: exitingIds.contains(items[index].id) ? 0.0 : 1.0,
                      child: AnimatedScale(
                        duration: const Duration(milliseconds: 150),
                        curve: Curves.easeOutCubic,
                        scale: exitingIds.contains(items[index].id)
                            ? 0.92
                            : 1.0,
                        child: itemBuilder(
                          context,
                          items[index],
                          exitingIds.contains(items[index].id),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
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
    required this.exiting,
    required this.onDragStarted,
    required this.dragMetrics,
    required this.onCancel,
    required this.onRemove,
  });

  final Manga manga;
  final bool exiting;

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
  bool _canceling = false;

  Offset _finger = Offset.zero;
  Offset _originCenter = Offset.zero;

  double _pull = 0.0;

  Offset? _target;

  Size _size = Size.zero;

  void _onLongPressStart(LongPressStartDetails details) {
    final box = context.findRenderObject() as RenderBox?;

    if (box == null) return;

    _size = box.size;
    _finger = details.globalPosition;
    _originCenter = box.localToGlobal(
      Offset(_size.width / 2.0, _size.height / 2.0),
    );

    _dragging = true;

    widget.onDragStarted();

    _updateMetrics(_finger);

    _overlay = OverlayEntry(
      builder: (context) {
        return _FloatingManga(
          manga: widget.manga,
          finger: _finger,
          originCenter: _originCenter,
          size: _size,
          target: _target,
          pull: _pull,
          deleting: _deleting,
          canceling: _canceling,
        );
      },
    );

    Overlay.of(context).insert(_overlay!);

    setState(() {});
  }

  void _onLongPressMove(LongPressMoveUpdateDetails details) {
    if (!_dragging || _deleting || _canceling) {
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
    if (!_dragging || _deleting || _canceling) {
      return;
    }

    final metrics = widget.dragMetrics(details.globalPosition);

    _pull = metrics.pull;

    _target = metrics.target;

    if (metrics.active && _target != null) {
      await _animateDelete();
    } else {
      await _cancel();
    }
  }

  Future<void> _animateDelete() async {
    _deleting = true;
    _pull = 1.0;

    _overlay?.markNeedsBuild();

    HapticFeedback.selectionClick();

    await Future.delayed(const Duration(milliseconds: 220));

    widget.onRemove(widget.manga);

    if (!mounted) return;

    await Future.delayed(const Duration(milliseconds: 80));

    _removeOverlay();

    if (!mounted) return;

    setState(() {
      _dragging = false;
      _deleting = false;
      _canceling = false;
    });
  }

  Future<void> _cancel() async {
    if (!_dragging || _deleting || _canceling) {
      return;
    }

    _canceling = true;
    _pull = 0.0;

    _overlay?.markNeedsBuild();

    await Future.delayed(const Duration(milliseconds: 240));

    _dragging = false;
    _deleting = false;
    _canceling = false;

    if (mounted) {
      setState(() {});
    }

    widget.onCancel();

    await Future.delayed(const Duration(milliseconds: 90));

    _removeOverlay();
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
    return Semantics(
      label: widget.manga.title,
      hint: 'Tap for details. Press and hold, then drag down to remove.',
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Remove from library'): () {
          widget.onRemove(widget.manga);
        },
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,

        onLongPressStart: widget.exiting ? null : _onLongPressStart,

        onLongPressMoveUpdate: widget.exiting ? null : _onLongPressMove,

        onLongPressEnd: widget.exiting ? null : _onLongPressEnd,

        onLongPressCancel: widget.exiting
            ? null
            : () {
                unawaited(_cancel());
              },

        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 140),

          curve: Curves.easeOutCubic,

          opacity: _dragging ? 0.0 : 1.0,

          child: _LibraryMangaTile(manga: widget.manga),
        ),
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
    required this.originCenter,
    required this.size,
    required this.target,
    required this.pull,
    required this.deleting,
    required this.canceling,
  });

  final Manga manga;
  final Offset finger;
  final Offset originCenter;
  final Size size;
  final Offset? target;
  final double pull;
  final bool deleting;
  final bool canceling;

  @override
  State<_FloatingManga> createState() => _FloatingMangaState();
}

class _FloatingMangaState extends State<_FloatingManga> {
  final bool _entered = true;

  @override
  Widget build(BuildContext context) {
    final bool deleting = widget.deleting;
    final bool canceling = widget.canceling;
    final int motionMs = deleting
        ? 220
        : canceling
        ? 240
        : 170;
    final int scaleMs = deleting
        ? 220
        : canceling
        ? 240
        : 210;
    final Curve motionCurve = deleting
        ? Curves.easeInCubic
        : canceling
        ? Curves.easeOutCubic
        : Curves.easeOutBack;
    final Offset targetCenter = widget.canceling
        ? widget.originCenter
        : widget.target ?? widget.finger;

    final double attraction = deleting || canceling ? 1.0 : widget.pull * 0.34;

    final Offset dragCenter = Offset.lerp(
      widget.finger,
      targetCenter,
      attraction,
    )!;

    final Offset displayCenter = Offset.lerp(
      widget.originCenter,
      dragCenter,
      _entered ? 1.0 : 0.0,
    )!;

    final double liftedScale = canceling
        ? 1.0
        : _entered
        ? 1.055
        : 0.96;

    final double scale = deleting
        ? 0.05
        : canceling
        ? 1.0
        : liftedScale - (widget.pull * 0.54);

    final double rawOpacity = deleting ? 0.0 : 1.0 - (widget.pull * 0.16);

    final double opacity = rawOpacity.clamp(0.0, 1.0).toDouble();
    final double lift = canceling
        ? 0.0
        : _entered
        ? 8.0
        : 0.0;

    final left = displayCenter.dx - widget.size.width / 2.0;
    final top = displayCenter.dy - widget.size.height / 2.0 - lift;
    final floatingChild = IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedScale(
          duration: Duration(milliseconds: scaleMs),

          curve: motionCurve,

          scale: scale,

          child: AnimatedOpacity(
            duration: Duration(milliseconds: deleting ? 180 : 120),

            curve: Curves.easeOut,

            opacity: opacity,

            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),

              curve: Curves.easeOutCubic,

              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),

                boxShadow: const [],
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

    return AnimatedPositioned(
      duration: Duration(milliseconds: deleting || canceling ? motionMs : 0),
      curve: motionCurve,
      left: left,
      top: top,
      child: floatingChild,
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
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,

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
  });

  final IconData icon;
  final String title;
  final String message;

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
          ],
        ),
      ),
    );
  }
}
