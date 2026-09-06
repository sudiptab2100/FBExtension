import '../../core/utils/json.dart';
import 'user.dart';

/// A per-folder permission grant, mirroring the server's `Acl`.
class Acl {
  const Acl({
    required this.id,
    required this.userId,
    required this.driveUuid,
    required this.pathPrefix,
    required this.permission,
  });

  final int id;
  final int userId;
  final String driveUuid;

  /// Path prefix within the drive this rule applies to ("" = whole drive).
  final String pathPrefix;

  /// 'read' | 'write' | 'admin'.
  final String permission;

  factory Acl.fromJson(Map<String, dynamic> json) => Acl(
        id: asInt(json['id']),
        userId: asInt(json['userId']),
        driveUuid: asString(json['driveUuid']),
        pathPrefix: asString(json['pathPrefix']),
        permission: asString(json['permission'], 'read'),
      );
}

/// A user together with their ACL grants, as returned by `GET /api/users`.
class AdminUser {
  const AdminUser({required this.user, required this.acls});
  final AppUser user;
  final List<Acl> acls;

  factory AdminUser.fromJson(Map<String, dynamic> json) => AdminUser(
        user: AppUser.fromJson(json),
        acls: (json['acls'] as List? ?? const [])
            .map((e) => Acl.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
