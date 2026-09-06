import '../../core/utils/json.dart';

/// Admin-facing server configuration (the `toConfigView` shape). Secrets like
/// the JWT signing key and the raw registered-drive list are never exposed.
class AppConfig {
  const AppConfig({
    required this.port,
    required this.host,
    required this.httpsEnabled,
    required this.httpsPort,
    required this.autoStart,
    required this.registrationEnabled,
    required this.autoApproveRegistrations,
    required this.autoApproveAccessRequests,
    required this.shareRootName,
  });

  final int port;
  final String host;
  final bool httpsEnabled;
  final int httpsPort;
  final bool autoStart;
  final bool registrationEnabled;
  final bool autoApproveRegistrations;
  final bool autoApproveAccessRequests;
  final String shareRootName;

  AppConfig copyWith({
    int? port,
    String? host,
    bool? httpsEnabled,
    int? httpsPort,
    bool? autoStart,
    bool? registrationEnabled,
    bool? autoApproveRegistrations,
    bool? autoApproveAccessRequests,
    String? shareRootName,
  }) =>
      AppConfig(
        port: port ?? this.port,
        host: host ?? this.host,
        httpsEnabled: httpsEnabled ?? this.httpsEnabled,
        httpsPort: httpsPort ?? this.httpsPort,
        autoStart: autoStart ?? this.autoStart,
        registrationEnabled: registrationEnabled ?? this.registrationEnabled,
        autoApproveRegistrations:
            autoApproveRegistrations ?? this.autoApproveRegistrations,
        autoApproveAccessRequests:
            autoApproveAccessRequests ?? this.autoApproveAccessRequests,
        shareRootName: shareRootName ?? this.shareRootName,
      );

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        port: asInt(json['port'], 4820),
        host: asString(json['host'], '0.0.0.0'),
        httpsEnabled: asBool(json['httpsEnabled']),
        httpsPort: asInt(json['httpsPort'], 4843),
        autoStart: asBool(json['autoStart']),
        registrationEnabled: asBool(json['registrationEnabled']),
        autoApproveRegistrations: asBool(json['autoApproveRegistrations']),
        autoApproveAccessRequests: asBool(json['autoApproveAccessRequests']),
        shareRootName: asString(json['shareRootName'], 'LocalDrive'),
      );
}
