import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';
import '../../core/network/dio_client.dart';
import '../../data/models/drive_info.dart';
import '../../data/models/file_entry.dart';
import '../../data/repositories/drives_repository.dart';
import '../../data/repositories/files_repository.dart';
import '../../state/api_providers.dart';
import '../../state/connection_controller.dart' show activeInstanceProvider;
import '../../state/session_controller.dart';
import '../drives/drives_screen.dart';

/// A chosen upload target: a granted [drive] and a scope-relative folder [path].
class DestinationChoice {
  const DestinationChoice({
    required this.drive,
    required this.driveLabel,
    required this.path,
  });

  final String drive;
  final String driveLabel;
  final String path;

  /// A short human label like `Media › Photos` for confirmations.
  String get pretty => path.isEmpty ? driveLabel : '$driveLabel › $path';
}

/// Presents a bottom sheet to pick a granted drive and a destination folder.
/// Returns `null` if the user dismisses without choosing.
Future<DestinationChoice?> showDestinationPicker(
  BuildContext context, {
  bool userSpace = false,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final instance = container.read(activeInstanceProvider);
  final session = container.read(sessionControllerProvider);
  if (userSpace &&
      (instance == null || !session.isAuthenticated || session.token == null)) {
    return null;
  }
  final scopedDio = userSpace
      ? buildDio(
          baseUrl: instance!.baseUrl,
          token: () => session.token,
          viewMode: () => ViewCookie.user,
          trustSelfSigned: instance.trustSelfSigned,
        )
      : null;
  try {
    return await showModalBottomSheet<DestinationChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => ProviderScope(
        overrides: [
          if (scopedDio != null) ...[
            filesRepositoryProvider.overrideWithValue(
              FilesRepository(scopedDio),
            ),
            drivesListProvider.overrideWith(
              (ref) => DrivesRepository(scopedDio).list(),
            ),
          ],
        ],
        child: FractionallySizedBox(
          heightFactor: 0.85,
          child: _DestinationPickerSheet(userSpace: userSpace),
        ),
      ),
    );
  } finally {
    scopedDio?.close(force: true);
  }
}

class _DestinationPickerSheet extends ConsumerStatefulWidget {
  const _DestinationPickerSheet({this.userSpace = false});

  final bool userSpace;

  @override
  ConsumerState<_DestinationPickerSheet> createState() =>
      _DestinationPickerSheetState();
}

class _DestinationPickerSheetState
    extends ConsumerState<_DestinationPickerSheet> {
  DriveInfo? _drive;
  String _path = '';

  void _openDrive(DriveInfo d) => setState(() {
    _drive = d;
    _path = '';
  });

  void _enter(String folderPath) => setState(() => _path = folderPath);

  void _up() {
    final idx = _path.lastIndexOf('/');
    setState(() => _path = idx <= 0 ? '' : _path.substring(0, idx));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Header(
          title: _drive == null ? 'Choose a drive' : _drive!.label,
          subtitle: _drive == null
              ? (widget.userSpace
                    ? 'Personal backup destination'
                    : 'Upload destination')
              : (_path.isEmpty
                    ? (widget.userSpace ? 'My space' : 'Drive root')
                    : _path),
          onBack: _drive == null
              ? null
              : () {
                  if (_path.isEmpty) {
                    setState(() => _drive = null);
                  } else {
                    _up();
                  }
                },
        ),
        const Divider(height: 1),
        Expanded(child: _drive == null ? _driveList() : _folderList()),
        if (_drive != null)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: const Icon(Icons.check),
                label: Text(
                  _path.isEmpty
                      ? (widget.userSpace
                            ? 'Back up here (my space)'
                            : 'Upload here (drive root)')
                      : 'Upload to “${_path.split('/').last}”',
                ),
                onPressed: () => Navigator.pop(
                  context,
                  DestinationChoice(
                    drive: _drive!.uuid,
                    driveLabel: _drive!.label,
                    path: _path,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _driveList() {
    final drivesAsync = ref.watch(drivesListProvider);
    return drivesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Message(
        icon: Icons.error_outline,
        text: 'Could not load drives.\n$e',
      ),
      data: (drives) {
        final granted = drives.where((d) => d.isGranted && d.online).toList();
        if (granted.isEmpty) {
          return const _Message(
            icon: Icons.lock_outline,
            text:
                'No drives you can upload to yet.\nRequest access from the '
                'Drives tab first.',
          );
        }
        return ListView.builder(
          itemCount: granted.length,
          itemBuilder: (_, i) {
            final d = granted[i];
            return ListTile(
              leading: const Icon(Icons.storage_outlined),
              title: Text(d.label),
              subtitle: d.writable == false
                  ? const Text('Read-only')
                  : Text(d.mountPath ?? ''),
              enabled: d.writable != false,
              trailing: const Icon(Icons.chevron_right),
              onTap: d.writable == false ? null : () => _openDrive(d),
            );
          },
        );
      },
    );
  }

  Widget _folderList() {
    final repo = ref.read(filesRepositoryProvider);
    return FutureBuilder<List<FileEntry>>(
      future: repo.list(_drive!.uuid, _path),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _Message(
            icon: Icons.error_outline,
            text: 'Could not open folder.\n${snap.error}',
          );
        }
        final folders = (snap.data ?? const []).where((e) => e.isDir).toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
        if (folders.isEmpty) {
          return const _Message(
            icon: Icons.folder_open_outlined,
            text:
                'No sub-folders here.\nUpload into this folder using the '
                'button below.',
          );
        }
        return ListView.builder(
          itemCount: folders.length,
          itemBuilder: (_, i) {
            final f = folders[i];
            return ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(f.name),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _enter(f.path),
            );
          },
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle, this.onBack});

  final String title;
  final String subtitle;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 16, 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(onBack == null ? Icons.close : Icons.arrow_back),
            onPressed: onBack ?? () => Navigator.pop(context),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
