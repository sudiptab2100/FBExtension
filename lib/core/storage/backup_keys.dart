import 'dart:convert';

String backupProfileKey(String instanceId, int userId) =>
    jsonEncode([instanceId, userId]);
