import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models/backup_settings.dart';
import '../../state/backup_controller.dart';
import '../../state/connection_controller.dart';
import '../../state/core_providers.dart';
import '../../state/session_controller.dart';
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
    final prefs = ref.watch(prefsProvider);
    final session = ref.watch(sessionControllerProvider);
    final instance = ref.watch(activeInstanceProvider);
    final availability = ref
        .watch(backgroundAvailabilityProvider)
        .asData
        ?.value;
    final ios = Theme.of(context).platform == TargetPlatform.iOS;
    Future<void> save(BackupSettings next) async {
      await ctrl.update(
        next,
        expectedInstanceId: instance?.id,
        expectedUserId: session.user?.id,
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Header(enabled: s.enabled),
          const SizedBox(height: 8),
          Text(
            '${instance?.name ?? 'LocalDrive'} / '
            '${session.user?.username ?? 'No account selected'}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          const _InfoCard(
            icon: Icons.person_outline,
            text:
                'Only the selected account backs up. Switching accounts pauses '
                'its transfers; destinations and history stay separate.',
          ),
          if (prefs.hasUnclaimedLegacyBackup)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Confirm your previous backup settings'),
                    const SizedBox(height: 8),
                    const Text(
                      'The previous version did not record which account owned '
                      'backup settings. Import them for this account, review '
                      'the destination, then enable automatic backup.',
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: ctrl.saving
                          ? null
                          : () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text(
                                    'Import previous settings?',
                                  ),
                                  content: Text(
                                    'Use the previous destination for '
                                    '${session.user?.username ?? 'this account'}? '
                                    'Automatic backup will stay off until you enable it.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Import'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) {
                                await ctrl.adoptLegacySettings(
                                  expectedInstanceId: instance?.id,
                                  expectedUserId: session.user?.id,
                                );
                              }
                            },
                      child: const Text('Import for this account'),
                    ),
                  ],
                ),
              ),
            ),
          if (ctrl.configurationError != null)
            _InfoCard(
              icon: Icons.error_outline,
              text: ctrl.configurationError!,
              error: true,
            ),
          if (prefs.backgroundError != null)
            _InfoCard(icon: Icons.info_outline, text: prefs.backgroundError!),
          if (availability?['backgroundRefresh'] == 'denied' ||
              availability?['backgroundRefresh'] == 'restricted')
            const _InfoCard(
              icon: Icons.settings_outlined,
              text:
                  'iOS background access is restricted. Check Settings > '
                  'General > Background App Refresh. Opening LocalDrive can '
                  'still catch up when your backup conditions are met.',
            ),
          if (availability?['lowPowerMode'] == true)
            const _InfoCard(
              icon: Icons.battery_saver_outlined,
              text: 'Low Power Mode can delay background backup.',
            ),

          // Master auto-backup switch.
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.backup_outlined),
              title: const Text('Automatic backup'),
              subtitle: Text(
                s.runnable
                    ? 'Runs for this account when backup conditions allow'
                    : 'Needs a destination and at least one source',
              ),
              value: s.enabled,
              onChanged: ctrl.saving
                  ? null
                  : (on) => save(s.copyWith(enabled: on)),
            ),
          ),

          const _SectionHeader('Destination'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: Text(
                s.hasDestination
                    ? (s.driveLabel ?? 'Selected drive')
                    : 'Choose destination',
              ),
              subtitle: Text(
                s.hasDestination
                    ? (s.folder.isEmpty ? 'Drive root' : s.folder)
                    : 'Pick a drive and folder to back up into',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: ctrl.saving
                  ? null
                  : () async {
                      final dest = await showDestinationPicker(
                        context,
                        userSpace: true,
                      );
                      if (dest == null) return;
                      await save(
                        s.copyWith(
                          driveUuid: dest.drive,
                          driveLabel: dest.driveLabel,
                          folder: dest.path,
                        ),
                      );
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
                  onChanged: ctrl.saving
                      ? null
                      : (v) => save(s.copyWith(photos: v)),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.videocam_outlined),
                  title: const Text('Videos'),
                  value: s.videos,
                  onChanged: ctrl.saving
                      ? null
                      : (v) => save(s.copyWith(videos: v)),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.contacts_outlined),
                  title: const Text('Contacts (daily vCard)'),
                  value: s.contacts,
                  onChanged: ctrl.saving
                      ? null
                      : (v) => save(s.copyWith(contacts: v)),
                ),
              ],
            ),
          ),

          const _SectionHeader('Conditions'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.wifi),
                  title: const Text('Wi-Fi only'),
                  subtitle: const Text('Avoid backing up over mobile data'),
                  value: s.wifiOnly,
                  onChanged: ctrl.saving
                      ? null
                      : (v) => save(s.copyWith(wifiOnly: v)),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.battery_charging_full),
                  title: const Text('Start only while charging'),
                  subtitle: const Text(
                    'Applies to automatic backup, including when opening the '
                    'app. Queued transfers may finish after unplugging.',
                  ),
                  value: s.chargingOnly,
                  onChanged: ctrl.saving
                      ? null
                      : (v) => save(s.copyWith(chargingOnly: v)),
                ),
              ],
            ),
          ),
          if (ios)
            const _InfoCard(
              icon: Icons.info_outline,
              text:
                  'iOS chooses when to scan for new items in the background. '
                  'Prepared transfers can continue while the phone is locked. '
                  'Do not swipe LocalDrive away: force-quitting cancels transfers '
                  'until you reopen it. The Mac must be awake and reachable.',
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
    final saving = ref.read(backupSettingsProvider.notifier).saving;
    String format(DateTime? value) => value == null
        ? 'Never'
        : DateFormat.yMMMd().add_jm().format(value.toLocal());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Last successful backup: ${format(state.lastSuccessAt)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (state.lastAttemptAt != null)
          Text(
            'Last attempt: ${format(state.lastAttemptAt)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 8),
        Text(
          '${state.uploaded} backed up / ${state.queued} queued / '
          '${state.paused} paused / ${state.failed} failed',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (state.waitingReason != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(state.waitingReason!),
          ),
        const SizedBox(height: 12),
        if (state.running) ...[
          LinearProgressIndicator(
            value: state.progress?.clamp(0.0, 1.0).toDouble(),
          ),
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
        ] else if (state.done || state.error != null || state.failed > 0) ...[
          _ResultBanner(state: state),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          onPressed: (!canRun || state.running || saving)
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
        if (canRun)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Back up now can run on battery. Your Wi-Fi setting still applies.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
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
    final ok = state.error == null && state.failed == 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ok ? scheme.secondaryContainer : scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            color: ok ? scheme.onSecondaryContainer : scheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              ok
                  ? 'Backup is up to date. ${state.uploaded} item(s) backed up.'
                  : (state.error ??
                        '${state.failed} item(s) could not be backed up. Retry '
                            'after checking permissions and the destination.'),
              style: TextStyle(
                color: ok
                    ? scheme.onSecondaryContainer
                    : scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.text, this.error = false});

  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: error ? Theme.of(context).colorScheme.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
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
                  Text(
                    'Auto-backup',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
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
