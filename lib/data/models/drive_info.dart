import '../../core/utils/json.dart';

/// The caller's access state for a drive under the opt-in access model.
enum DriveAccess { granted, pending, denied, none }

DriveAccess driveAccessFromString(String? v) {
  switch (v) {
    case 'granted':
      return DriveAccess.granted;
    case 'pending':
      return DriveAccess.pending;
    case 'denied':
      return DriveAccess.denied;
    default:
      return DriveAccess.none;
  }
}

/// A registered/detected drive, mirroring the server's `DriveInfo`.
class DriveInfo {
  const DriveInfo({
    required this.uuid,
    required this.label,
    required this.online,
    required this.registered,
    required this.external,
    this.mountPath,
    this.filesystem,
    this.totalBytes,
    this.freeBytes,
    this.access,
    this.custom = false,
    this.writable,
    this.shareable,
    this.unshareableReason,
  });

  final String uuid;
  final String label;
  final String? mountPath;
  final String? filesystem;
  final int? totalBytes;
  final int? freeBytes;
  final bool online;
  final bool registered;
  final DriveAccess? access;
  final bool external;
  final bool custom;
  final bool? writable;
  final bool? shareable;
  final String? unshareableReason;

  int? get usedBytes => (totalBytes != null && freeBytes != null)
      ? (totalBytes! - freeBytes!)
      : null;

  double? get usedFraction => (totalBytes != null && totalBytes! > 0)
      ? (usedBytes! / totalBytes!).clamp(0.0, 1.0)
      : null;

  bool get isGranted => access == DriveAccess.granted;

  factory DriveInfo.fromJson(Map<String, dynamic> json) => DriveInfo(
        uuid: asString(json['uuid']),
        label: asString(json['label']),
        mountPath: asStringOrNull(json['mountPath']),
        filesystem: asStringOrNull(json['filesystem']),
        totalBytes: asIntOrNull(json['totalBytes']),
        freeBytes: asIntOrNull(json['freeBytes']),
        online: asBool(json['online']),
        registered: asBool(json['registered']),
        access: json['access'] == null
            ? null
            : driveAccessFromString(asStringOrNull(json['access'])),
        external: asBool(json['external']),
        custom: asBool(json['custom']),
        writable: json['writable'] == null ? null : asBool(json['writable']),
        shareable: json['shareable'] == null ? null : asBool(json['shareable']),
        unshareableReason: asStringOrNull(json['unshareableReason']),
      );
}
