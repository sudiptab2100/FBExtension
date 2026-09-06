import '../../core/utils/json.dart';

enum UserRole { admin, user }

enum UserStatus { active, pending }

/// A LocalDrive account, mirroring the server's `User` shape.
class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.role,
    required this.createdAt,
    required this.home,
    required this.status,
  });

  final int id;
  final String username;
  final UserRole role;
  final String createdAt;

  /// Filesystem-safe folder name for this user's private home ('' for admins).
  final String home;
  final UserStatus status;

  bool get isAdmin => role == UserRole.admin;
  bool get isPending => status == UserStatus.pending;

  static UserRole roleFromString(String? v) =>
      v == 'admin' ? UserRole.admin : UserRole.user;

  static UserStatus statusFromString(String? v) =>
      v == 'pending' ? UserStatus.pending : UserStatus.active;

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: asInt(json['id']),
        username: asString(json['username']),
        role: roleFromString(asStringOrNull(json['role'])),
        createdAt: asString(json['createdAt']),
        home: asString(json['home']),
        status: statusFromString(asStringOrNull(json['status'])),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'role': role.name,
        'createdAt': createdAt,
        'home': home,
        'status': status.name,
      };
}
