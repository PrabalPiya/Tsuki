import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/providers.dart';
import '../../../core/storage/image_cache.dart';
import '../../../core/theme/app_theme.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(userLibraryProvider);
    final session = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(titleSpacing: 16, title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        children: [
          _SectionCard(
            title: 'Reading preferences',
            children: [
              _SwitchRow(
                icon: Icons.shield_moon_rounded,
                title: 'Adult content',
                subtitle:
                    'Allow mature titles in search. Discover stays filtered.',
                value: state.adultContent,
                onChanged: ref
                    .read(userLibraryProvider.notifier)
                    .setAdultContent,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SectionCard(
            title: 'Storage',
            children: [
              _ActionRow(
                icon: Icons.image_rounded,
                title: 'Image cache',
                subtitle: 'Stores covers so pages load faster.',
                action: TextButton(
                  onPressed: () async {
                    await MangaImageCache.instance.emptyCache();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Image cache cleared')),
                      );
                    }
                  },
                  child: const Text('Clear'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SectionCard(
            title: session.isLocalProfile ? 'Local profile' : 'Account',
            children: session.isLocalProfile
                ? [
                    const _InfoRow(
                      icon: Icons.phone_android_rounded,
                      title: 'On-device library',
                      subtitle: 'Bookmarks and progress stay on this phone.',
                    ),
                    _ActionRow(
                      icon: Icons.delete_outline_rounded,
                      title: 'Clear local data',
                      subtitle: 'Remove bookmarks, progress, and settings.',
                      destructive: true,
                      onTap: () => _confirmClearLocal(context, ref),
                    ),
                  ]
                : [
                    _ActionRow(
                      icon: Icons.logout_rounded,
                      title: 'Log out',
                      subtitle: 'Switch to another Google account.',
                      onTap: () => _confirmSignOut(context, ref),
                    ),
                    _ActionRow(
                      icon: Icons.delete_outline_rounded,
                      title: 'Delete account & data',
                      subtitle: 'Permanently remove synced app data.',
                      destructive: true,
                      onTap: () => _confirmDelete(context, ref),
                    ),
                  ],
          ),
          const SizedBox(height: 28),
          const Text(
            'Tsuki is open source. Manga content remains with external providers under their applicable terms.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final accepted = await _showConfirmDialog(
      context: context,
      icon: Icons.logout_rounded,
      title: 'Log out?',
      message: 'Make sure you want to leave this account before continuing.',
      confirmLabel: 'Log out',
    );
    if (accepted == true) {
      await ref.read(authProvider.notifier).signOut();
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final accepted = await _showConfirmDialog(
      context: context,
      icon: Icons.delete_outline_rounded,
      title: 'Delete account?',
      message: 'This permanently deletes bookmarks, progress, settings, and the authentication account.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (accepted == true) {
      final error = await ref.read(authProvider.notifier).deleteAccount();
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }

  Future<void> _confirmClearLocal(BuildContext context, WidgetRef ref) async {
    final accepted = await _showConfirmDialog(
      context: context,
      icon: Icons.delete_outline_rounded,
      title: 'Clear local data?',
      message: 'This removes all bookmarks, reading progress, and settings from this device.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (accepted == true) {
      await ref.read(userLibraryProvider.notifier).clearAll();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Local data cleared')));
      }
    }
  }

  Future<bool?> _showConfirmDialog({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) => showDialog<bool>(
    context: context,
    builder: (context) => _ConfirmDialog(
      icon: icon,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      destructive: destructive,
    ),
  );
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.icon,
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.destructive,
  });
  final IconData icon;
  final String title;
  final String message;
  final String confirmLabel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final accent = destructive ? AppColors.danger : AppColors.accent;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 28,
              offset: Offset(0, 16),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, color: accent, size: 25),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: destructive
                          ? AppColors.text
                          : AppColors.background,
                    ),
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(confirmLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => _RowShell(
    icon: icon,
    title: title,
    subtitle: subtitle,
    trailing: const SizedBox.shrink(),
  );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
    this.onTap,
    this.destructive = false,
  });
  final IconData icon;
  final String title, subtitle;
  final Widget? action;
  final VoidCallback? onTap;
  final bool destructive;
  @override
  Widget build(BuildContext context) => _RowShell(
    icon: icon,
    title: title,
    subtitle: subtitle,
    iconColor: destructive ? AppColors.danger : null,
    titleColor: destructive ? AppColors.danger : null,
    iconBackgroundColor: destructive
        ? AppColors.danger.withValues(alpha: .12)
        : null,
    trailing:
        action ??
        Icon(
          Icons.chevron_right_rounded,
          color: destructive ? AppColors.danger : null,
        ),
    onTap: onTap,
  );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final String title, subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => _RowShell(
    icon: icon,
    title: title,
    subtitle: subtitle,
    trailing: Switch(value: value, onChanged: onChanged),
    onTap: () => onChanged(!value),
  );
}

class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.iconColor,
    this.titleColor,
    this.iconBackgroundColor,
    this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final Widget trailing;
  final Color? iconColor;
  final Color? titleColor;
  final Color? iconBackgroundColor;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(18),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: iconBackgroundColor ?? AppColors.raised,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: iconColor?.withValues(alpha: .18) ?? AppColors.outline,
              ),
            ),
            child: Icon(icon, color: iconColor, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: titleColor ?? AppColors.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    ),
  );
}
