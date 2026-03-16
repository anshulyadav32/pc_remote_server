import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

class DeviceIdentity {
  final String deviceId;
  final String deviceName;
  final String deviceType;
  final int protocolVersion;
  final List<String> capabilities;

  const DeviceIdentity({
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
    required this.protocolVersion,
    required this.capabilities,
  });

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'deviceType': deviceType,
      'protocolVersion': protocolVersion,
      'capabilities': capabilities,
    };
  }

  factory DeviceIdentity.fromJson(Map<String, dynamic> json) {
    final rawCaps = json['capabilities'];
    final caps = rawCaps is List
        ? rawCaps.map((item) => item.toString()).toList()
        : <String>[];

    return DeviceIdentity(
      deviceId: (json['deviceId'] ?? '').toString(),
      deviceName: (json['deviceName'] ?? 'PCRemote Device').toString(),
      deviceType: (json['deviceType'] ?? 'unknown').toString(),
      protocolVersion: int.tryParse('${json['protocolVersion']}') ?? 1,
      capabilities: caps,
    );
  }

  DeviceIdentity copyWith({
    String? deviceName,
    String? deviceType,
    int? protocolVersion,
    List<String>? capabilities,
  }) {
    return DeviceIdentity(
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      deviceType: deviceType ?? this.deviceType,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      capabilities: capabilities ?? this.capabilities,
    );
  }
}

class DeviceIdentityService {
  static const int protocolVersion = 1;
  static const String _identityFileName = '.pcremote_identity.json';

  static Future<DeviceIdentity> loadOrCreate({
    required String defaultName,
    required String deviceType,
    required List<String> capabilities,
  }) async {
    final file = await _identityFile();

    if (await file.exists()) {
      try {
        final parsed = jsonDecode(await file.readAsString());
        if (parsed is Map<String, dynamic>) {
          final current = DeviceIdentity.fromJson(parsed);
          if (current.deviceId.isNotEmpty) {
            final updated = current.copyWith(
              deviceName: defaultName,
              deviceType: deviceType,
              protocolVersion: protocolVersion,
              capabilities: capabilities,
            );
            await file.writeAsString(jsonEncode(updated.toJson()));
            return updated;
          }
        }
      } catch (_) {}
    }

    final created = DeviceIdentity(
      deviceId: _generateDeviceId(),
      deviceName: defaultName,
      deviceType: deviceType,
      protocolVersion: protocolVersion,
      capabilities: capabilities,
    );

    await file.writeAsString(jsonEncode(created.toJson()));
    return created;
  }

  static String _generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    final hex =
        bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return 'pcr-$hex';
  }

  static Future<File> _identityFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}${Platform.pathSeparator}$_identityFileName');
    } catch (_) {
      final home = Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      return File('$home${Platform.pathSeparator}$_identityFileName');
    }
  }
}
