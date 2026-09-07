class BackupSnapshot {
  const BackupSnapshot({
    this.completed = 0,
    this.queued = 0,
    this.uploading = 0,
    this.paused = 0,
    this.failed = 0,
    this.skipped = 0,
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.error,
    this.waitingReason,
    this.current,
    this.progress,
    this.needsScan = false,
    this.nextRetryAt,
  });

  final int completed;
  final int queued;
  final int uploading;
  final int paused;
  final int failed;
  final int skipped;
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;
  final String? error;
  final String? waitingReason;
  final String? current;
  final double? progress;
  final bool needsScan;
  final DateTime? nextRetryAt;

  int get pending => queued + uploading + paused;
}
