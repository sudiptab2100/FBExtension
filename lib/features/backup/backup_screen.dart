import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/backup_settings.dart';
import '../../state/backup_controller.dart';
import '../device/destination_picker.dart';

/// Backup tab — configure and run auto-backup of photos, videos and contacts
/// to a chosen drive, with de-duplication and Wi-Fi-only gating.
class BackupScreen extends ConsumerWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(backupSettingsProvider);
    final ctrl = ref.read(backupSettingsProvider.notifier);
    final run = ref.watch(backupRunnerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Header(enabled: s.enabled),
          const SizedBox(height: 8),

          // Master auto-backup switch.
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.backup_outlined),
              title: const Text('Automatic backup'),
              subtitle: Text(s.runnable
                  ? 'Runs periodically in the background'
                  : 'Needs a destination and at least one source'),
              value: s.enabled,
              onChanged: (on) => ctrl.update(s.copyWith(enabled: on)),
            ),
          ),

          const _SectionHeader('Destination'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: Text(s.hasDestination
                  ? (s.driveLabel ?? 'Selected drive')
                  : 'Choose destination'),
              subtitle: Text(s.hasDestination
                  ? (s.folder.isEmpty ? 'Drive root' : s.folder)
                  : 'Pick a drive and folder to back up into'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final dest = await showDestinationPicker(context);
                if (dest == null) return;
                await ctrl.update(s.copyWith(
                  driveUuid: dest.drive,
                  driveLabel: dest.driveLabel,
                  folder: dest.path,
                ));
              },
            ),
          ),

          const _SectionHeader('What to back up'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.photo_outlined),
                  title: const Text('Photos'),
                  value: s.photos,
                  onChanged: (v) => ctrl.update(s.copyWith(photos: v)),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.videocam_outlined),
                  title: const Text('Videos'),
                  value: s.videos,
                  onChanged: (v) => ctrl.update(s.copyWith(videos: v)),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.contacts_outlined),
                  title: const Text('Contacts (daily vCard)'),
                  value: s.contacts,
                  onChanged: (v) => ctrl.update(s.copyWith(contacts: v)),
                ),
              ],
            ),
          ),

          const _SectionHeader('Network'),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.wifi),
              title: const Text('Wi-Fi only'),
              subtitle: const Text('Avoid backing up over mobile data'),
              value: s.wifiOnly,
              onChanged: (v) => ctrl.update(s.copyWith(wifiOnly: v)),
            ),
          ),

          const SizedBox(height: 16),
          _RunSection(state: run, settings: s),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _RunSection extends ConsumerWidget {
  const _RunSection({required this.state, required this.settings});

  final BackupRunState state;
  final BackupSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canRun = settings.hasDestination && settings.hasSource;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.running) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(
            state.current == null
                ? 'Backing up… ${state.uploaded} uploaded, '
                    '${state.skipped} skipped'
                : 'Uploading ${state.current}  ·  ${state.uploaded} done',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
        ] else if (state.done) ...[
          _ResultBanner(state: state),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          onPressed: (!canRun || state.running)
              ? null
              : () => ref.read(backupRunnerProvider.notifier).runNow(),
          icon: state.running
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_upload_outlined),
          label: Text(state.running ? 'Backing up…' : 'Back up now'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        if (!canRun)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Select a destination and at least one source to enable backup.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

class _ResultBanner extends StatelessWidget {
  const _ResultBanner({required this.state});
  final BackupRunState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = state.error == null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ok ? scheme.secondaryContainer : scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              color: ok
                  ? scheme.onSecondaryContainer
                  : scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              ok
                  ? 'Done — ${state.uploaded} uploaded, ${state.skipped} '
                      'already backed up'
                      '${state.failed > 0 ? ', ${state.failed} failed' : ''}'
                  : (state.error ?? 'Backup failed'),
              style: TextStyle(
                  color: ok
                      ? scheme.onSecondaryContainer
                      : scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.cloud_sync_outlined, size: 36, color: scheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Auto-backup',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Copies new photos, videos and contacts to LocalDrive. '
                    'Already-uploaded items are skipped automatically.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 0.8,
            ),
      ),
    );
  }
}
