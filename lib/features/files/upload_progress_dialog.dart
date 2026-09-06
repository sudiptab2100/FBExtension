import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/services/upload_service.dart';

/// Uploads a batch of files sequentially, showing per-file progress. The dialog
/// is non-dismissable while running and reports any per-file failures.
class UploadProgressDialog extends ConsumerStatefulWidget {
  const UploadProgressDialog({
    super.key,
    required this.files,
    required this.drive,
    required this.destPath,
  });

  final List<XFile> files;
  final String drive;
  final String destPath;

  @override
  ConsumerState<UploadProgressDialog> createState() =>
      _UploadProgressDialogState();
}

class _UploadProgressDialogState extends ConsumerState<UploadProgressDialog> {
  late final List<double> _progress =
      List<double>.filled(widget.files.length, 0);
  final Map<int, String> _errors = {};
  int _current = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_run);
  }

  Future<void> _run() async {
    final service = ref.read(uploadServiceProvider);
    for (var i = 0; i < widget.files.length; i++) {
      if (!mounted) return;
      setState(() => _current = i);
      try {
        await service.upload(
          file: widget.files[i],
          drive: widget.drive,
          destPath: widget.destPath,
          onProgress: (pct) {
            if (mounted) {
              setState(() => _progress[i] = (pct / 100).clamp(0.0, 1.0));
            }
          },
        );
        if (mounted) setState(() => _progress[i] = 1);
      } on ApiException catch (e) {
        if (mounted) setState(() => _errors[i] = e.message);
      } catch (e) {
        if (mounted) setState(() => _errors[i] = 'Upload failed');
      }
    }
    if (mounted) setState(() => _done = true);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.files.length;
    final failed = _errors.length;
    return AlertDialog(
      title: Text(_done
          ? (failed == 0
              ? 'Upload complete'
              : 'Uploaded ${total - failed}/$total')
          : 'Uploading ${_current + 1}/$total'),
      content: SizedBox(
        width: double.maxFinite,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: total,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, i) {
              final err = _errors[i];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(widget.files[i].name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      if (err == null && _progress[i] >= 1)
                        const Icon(Icons.check_circle,
                            color: Colors.green, size: 18),
                      if (err != null)
                        Icon(Icons.error,
                            color: Theme.of(context).colorScheme.error,
                            size: 18),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (err != null)
                    Text(err,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12))
                  else
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                          value: _progress[i], minHeight: 5),
                    ),
                ],
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _done ? () => Navigator.pop(context) : null,
          child: const Text('Done'),
        ),
      ],
    );
  }
}
