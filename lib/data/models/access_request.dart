import '../../core/utils/json.dart';

/// A user's pending request for access to a drive, mirroring `AccessRequest`.
class AccessRequest {
  const AccessRequest({
    required this.id,
    required this.userId,
    required this.username,
    required this.driveUuid,
    required this.driveLabel,
    required this.requestedAt,
    this.existingSpace,
  });

  final int id;
  final int userId;
  final String username;
  final String driveUuid;
  final String driveLabel;
  final String requestedAt;

  /// True when the user's folder already exists on the drive (best-effort).
  final bool? existingSpace;

  factory AccessRequest.fromJson(Map<String, dynamic> json) => AccessRequest(
        id: asInt(json['id']),
        userId: asInt(json['userId']),
        username: asString(json['username']),
        driveUuid: asString(json['driveUuid']),
        driveLabel: asString(json['driveLabel']),
        requestedAt: asString(json['requestedAt']),
        existingSpace: json['existingSpace'] == null
            ? null
            : asBool(json['existingSpace']),
      );
}
