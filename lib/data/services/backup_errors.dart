import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/network/api_exception.dart';

String backupFailureMessage(Object error) {
  if (error is ApiException) return error.message;
  if (error is MissingPluginException) {
    return 'Background support is unavailable. Reopen the updated LocalDrive app.';
  }
  if (error is PlatformException) {
    return error.message ??
        'Background access is unavailable. Unlock the phone and reopen the app.';
  }
  if (error is FileSystemException) {
    return 'Backup could not access local storage. Check available space and retry.';
  }
  if (error is FormatException || error is TypeError) {
    return 'Backup data could not be read. Check the destination and server version.';
  }
  if (error is StateError) return error.message;
  if (error is UnsupportedError) {
    return error.message ??
        'Background backup is not supported on this platform.';
  }
  return 'Backup failed (${error.runtimeType}). Open the app and retry.';
}
