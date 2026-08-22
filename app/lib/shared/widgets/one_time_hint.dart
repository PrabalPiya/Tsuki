import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';

class OneTimeHint extends StatefulWidget {
  const OneTimeHint({
    super.key,
    required this.id,
    required this.icon,
    required this.text,
    this.duration = const Duration(seconds: 7),
  });

  final String id;
  final IconData icon;
  final String text;
  final Duration duration;

  @override
  State<OneTimeHint> createState() => _OneTimeHintState();
}

class _OneTimeHintState extends State<OneTimeHint>
    with SingleTickerProviderStateMixin {
  static const String _prefix = 'tsuki_hint_seen_';

  late final AnimationController _controller;

  Timer? _timer;

  bool _checked = false;
  bool _visible = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAndShow());
  }

  Future<void> _checkAndShow() async {
    final prefs = await SharedPreferences.getInstance();

    final key = '$_prefix${widget.id}';

    final bool seen = prefs.getBool(key) ?? false;

    if (!mounted) return;

    if (seen) {
      setState(() {
        _checked = true;
        _visible = false;
      });

      return;
    }

    setState(() {
      _checked = true;
      _visible = true;
    });
    await _controller.forward(from: 0);
    if (!mounted || !_visible) return;
    await _markSeen();

    _timer?.cancel();
    _timer = Timer(widget.duration, _hide);
  }

  Future<void> _hide() async {
    if (!mounted || !_visible) {
      return;
    }

    _timer?.cancel();
    _controller.stop();
    setState(() {
      _visible = false;
    });
    await _markSeen();
  }

  Future<void> _markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_prefix${widget.id}', true);
    } catch (_) {
      // Hint persistence is optional and must never affect navigation.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked || !_visible) {
      return const SizedBox.shrink();
    }

    final animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return Semantics(
      liveRegion: true,
      label: widget.text,
      button: true,
      hint: 'Tap to dismiss',
      child: FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.18),
            end: Offset.zero,
          ).animate(animation),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width - 32,
            ),
            child: Material(
              color: AppColors.glass,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: AppColors.outline),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _hide,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, size: 18, color: AppColors.accent),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          widget.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const ExcludeSemantics(
                        child: Icon(
                          Icons.close_rounded,
                          size: 17,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
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
