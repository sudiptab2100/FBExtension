/// Persisted auto-backup configuration.
///
/// Stored as a JSON blob under `StoreKeys.backupSettings`. Destination is a
/// granted drive plus a scope-relative base folder; sources are toggled
/// independently. Photos/videos land in `Photos`/`Videos` sub-folders and
/// contacts in `Contacts` beneath [folder].
class BackupSettings {
  const BackupSettings({
    this.enabled = false,
    this.photos = true,
    this.videos = true,
    this.contacts = false,
    this.wifiOnly = true,
    this.driveUuid,
    this.driveLabel,
    this.folder = 'Backup',
  });

  final bool enabled;
  final bool photos;
  final bool videos;
  final bool contacts;
  final bool wifiOnly;
  final String? driveUuid;
  final String? driveLabel;
  final String folder;

  bool get hasDestination => (driveUuid ?? '').isNotEmpty;
  bool get hasSource => photos || videos || contacts;

  /// Whether background auto-backup can actually run.
  bool get runnable => enabled && hasDestination && hasSource;

  BackupSettings copyWith({
    bool? enabled,
    bool? photos,
    bool? videos,
    bool? contacts,
    bool? wifiOnly,
    String? driveUuid,
    String? driveLabel,
    String? folder,
  }) =>
      BackupSettings(
        enabled: enabled ?? this.enabled,
        photos: photos ?? this.photos,
        videos: videos ?? this.videos,
        contacts: contacts ?? this.contacts,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        driveUuid: driveUuid ?? this.driveUuid,
        driveLabel: driveLabel ?? this.driveLabel,
        folder: folder ?? this.folder,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'photos': photos,
        'videos': videos,
        'contacts': contacts,
        'wifiOnly': wifiOnly,
        'driveUuid': driveUuid,
        'driveLabel': driveLabel,
        'folder': folder,
      };

  factory BackupSettings.fromJson(Map<String, dynamic> j) => BackupSettings(
        enabled: j['enabled'] as bool? ?? false,
        photos: j['photos'] as bool? ?? true,
        videos: j['videos'] as bool? ?? true,
        contacts: j['contacts'] as bool? ?? false,
        wifiOnly: j['wifiOnly'] as bool? ?? true,
        driveUuid: j['driveUuid'] as String?,
        driveLabel: j['driveLabel'] as String?,
        folder: j['folder'] as String? ?? 'Backup',
      );
}
