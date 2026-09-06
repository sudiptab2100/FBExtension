import 'dart:math' as math;

/// Human-readable byte size, e.g. 1536 -> "1.5 KB".
String formatBytes(int? bytes, {int decimals = 1}) {
  if (bytes == null) return '—';
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  final i = (math.log(bytes) / math.log(1024)).floor().clamp(0, units.length - 1);
  final value = bytes / math.pow(1024, i);
  final digits = i == 0 ? 0 : decimals;
  return '${value.toStringAsFixed(digits)} ${units[i]}';
}

/// Relative time like "2h ago" / "just now"; falls back to a date for old items.
String formatRelative(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final diff = now.difference(time);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

String formatDateTime(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}
