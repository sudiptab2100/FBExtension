import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/services/media_service.dart';
import '../../routing/router.dart';
import '../files/upload_progress_dialog.dart';
import 'destination_picker.dart';

/// Device tab — on-device media, files and contacts to upload into LocalDrive.
class DeviceScreen extends ConsumerWidget {
  const DeviceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Device')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _Header(),
          const SizedBox(height: 12),
          _SourceTile(
            icon: Icons.photo_library_outlined,
            title: 'Photos & videos',
            subtitle: 'Pick from albums and upload to a drive',
            onTap: () => context.push(Routes.devicePhotos),
          ),
          _SourceTile(
            icon: Icons.insert_drive_file_outlined,
            title: 'Files',
            subtitle: 'Pick documents and other files to upload',
            onTap: () => _pickAndUploadFiles(context, ref),
          ),
          _SourceTile(
            icon: Icons.contacts_outlined,
            title: 'Contacts',
            subtitle: 'Export all contacts as a vCard and upload',
            onTap: () => _exportAndUploadContacts(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndUploadFiles(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles();
    final files = picked
        .where((f) => f.path != null)
        .map((f) => XFile(f.path!, name: f.name))
        .toList();
    if (files.isEmpty || !context.mounted) return;

    final dest = await showDestinationPicker(context);
    if (dest == null || !context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UploadProgressDialog(
        files: files,
        drive: dest.drive,
        destPath: dest.path,
      ),
    );
  }

  Future<void> _exportAndUploadContacts(
      BuildContext context, WidgetRef ref) async {
    final media = ref.read(mediaServiceProvider);
    final granted = await media.requestContactsAccess();
    if (!context.mounted) return;
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contacts permission denied.')),
      );
      return;
    }

    final count = await media.contactsCount();
    if (!context.mounted) return;
    if (count == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No contacts to export.')),
      );
      return;
    }

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export contacts'),
        content: Text(
            'Export $count contacts into a single .vcf file and upload it to '
            'a drive?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Export')),
        ],
      ),
    );
    if (proceed != true || !context.mounted) return;

    final dest = await showDestinationPicker(context);
    if (dest == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Preparing contacts…')),
    );
    final XFile vcf;
    try {
      vcf = await media.exportContactsVcf();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not export contacts.')),
      );
      return;
    }
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UploadProgressDialog(
        files: [vcf],
        drive: dest.drive,
        destPath: dest.path,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.smartphone, size: 36, color: scheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your device',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Share on-device content to LocalDrive. Each source asks '
                    'for permission the first time.',
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

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
