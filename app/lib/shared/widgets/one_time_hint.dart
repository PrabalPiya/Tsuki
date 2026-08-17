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
    this.duration = const Duration(seconds: 5),
  });

  final String id;
  final IconData icon;
  final String text;
  final Duration duration;

  @override
  State<OneTimeHint> createState() =>
      _OneTimeHintState();
}

class _OneTimeHintState extends State<OneTimeHint>
    with SingleTickerProviderStateMixin {
  static const String _prefix =
      'tsuki_hint_seen_';

  late final AnimationController _controller;

  Timer? _timer;

  bool _checked = false;
  bool _visible = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(
        milliseconds: 900,
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _checkAndShow(),
    );
  }

  Future<void> _checkAndShow() async {
    final prefs =
        await SharedPreferences.getInstance();

    final key =
        '$_prefix${widget.id}';

    final bool seen =
        prefs.getBool(key) ?? false;

    if (!mounted) return;

    if (seen) {
      setState(() {
        _checked = true;
        _visible = false;
      });

      return;
    }

    /*
     * Mark it seen immediately.
     *
     * Even if the user navigates away before the
     * animation finishes, it will not show again.
     */
    await prefs.setBool(
      key,
      true,
    );

    if (!mounted) return;

    setState(() {
      _checked = true;
      _visible = true;
    });

    /*
     * Same blink behaviour as Discover.
     */
    _controller.repeat(
      reverse: true,
    );

    _timer?.cancel();

    _timer = Timer(
      widget.duration,
      _hide,
    );
  }

  Future<void> _hide() async {
    if (!mounted || !_visible) {
      return;
    }

    _timer?.cancel();

    await _controller.animateTo(
      0.0,
      duration: const Duration(
        milliseconds: 220,
      ),
      curve: Curves.easeOut,
    );

    if (!mounted) return;

    setState(() {
      _visible = false;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    if (!_checked || !_visible) {
      return const SizedBox.shrink();
    }

    return IgnorePointer(
      child: FadeTransition(
        opacity: CurvedAnimation(
          parent: _controller,
          curve: Curves.easeInOut,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 9,
          ),
          decoration: BoxDecoration(
            color: AppColors.glass,
            borderRadius: BorderRadius.circular(
              24,
            ),
            border: Border.all(
              color: AppColors.outline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 18,
                color: Colors.white,
              ),

              const SizedBox(
                width: 8,
              ),

              Text(
                widget.text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}