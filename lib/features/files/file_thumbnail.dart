import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/models/file_entry.dart';
import '../../state/api_providers.dart';

/// A type-aware thumbnail for a file entry: a cached image preview for images,
/// otherwise a tinted icon. Authenticated via the session's headers so the
/// thumbnail endpoint accepts the request.
class FileThumbnail extends ConsumerWidget {
  const FileThumbnail({
    super.key,
    required this.drive,
    required this.entry,
    this.size = 40,
    this.fill = false,
  });

  final String drive;
  final FileEntry entry;
  final double size;
  final bool fill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    if (entry.isImage) {
      final repo = ref.watch(filesRepositoryProvider);
      final headers = ref.watch(authHeadersProvider);
      final url = repo
          .thumbUrl(drive, entry.path, size: fill ? 256 : 128)
          .toString();
      final image = CachedNetworkImage(
        imageUrl: url,
        httpHeaders: headers,
        fit: BoxFit.cover,
        width: fill ? double.infinity : size,
        height: fill ? double.infinity : size,
        placeholder: (_, _) => _iconBox(scheme),
        errorWidget: (_, _, _) => _iconBox(scheme),
      );
      if (fill) return image;
      return ClipRRect(borderRadius: BorderRadius.circular(8), child: image);
    }

    return _iconBox(scheme);
  }

  Widget _iconBox(ColorScheme scheme) {
    final icon = _iconFor(entry);
    if (fill) {
      return Container(
        color: scheme.surfaceContainerHighest,
        child: Center(child: Icon(icon.$1, color: icon.$2, size: 44)),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: icon.$2.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon.$1, color: icon.$2, size: size * 0.55),
    );
  }

  (IconData, Color) _iconFor(FileEntry e) {
    if (e.isDir) return (Icons.folder, const Color(0xFFf59e0b));
    if (e.isImage) return (Icons.image, const Color(0xFF10b981));
    if (e.isVideo) return (Icons.movie, const Color(0xFFef4444));
    if (e.isAudio) return (Icons.audiotrack, const Color(0xFF8b5cf6));
    switch (p.extension(e.name).toLowerCase()) {
      case '.pdf':
        return (Icons.picture_as_pdf, const Color(0xFFef4444));
      case '.zip':
      case '.tar':
      case '.gz':
      case '.rar':
      case '.7z':
        return (Icons.folder_zip, const Color(0xFFf59e0b));
      case '.doc':
      case '.docx':
      case '.txt':
      case '.md':
      case '.rtf':
        return (Icons.description, const Color(0xFF3b82f6));
      case '.xls':
      case '.xlsx':
      case '.csv':
        return (Icons.table_chart, const Color(0xFF10b981));
      case '.ppt':
      case '.pptx':
        return (Icons.slideshow, const Color(0xFFf97316));
      default:
        return (Icons.insert_drive_file, const Color(0xFF64748b));
    }
  }
}
