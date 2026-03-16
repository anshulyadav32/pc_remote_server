import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class TrustedPermissions {
  final bool clipboard;
  final bool media;
  final bool browser;
  final bool window;
  final bool remoteInput;
  final bool textInput;

  const TrustedPermissions({
    this.clipboard = true,
    this.media = true,
    this.browser = true,
    this.window = true,
    this.remoteInput = true,
    this.textInput = true,
  });

  Map<String, dynamic> toJson() {
    return {
      'clipboard': clipboard,
      'media': media,
      'browser': browser,
      'window': window,
      'remoteInput': remoteInput,
      'textInput': textInput,
    };
  }

  factory TrustedPermissions.fromJson(Map<String, dynamic> json) {
    return TrustedPermissions(
      clipboard: json['clipboard'] != false,
      media: json['media'] != false,
      browser: json['browser'] != false,
      window: json['window'] != false,
      remoteInput: json['remoteInput'] != false,
      textInput: json['textInput'] != false,
    );
  }
}

class TrustedDeviceRecord {
  final String deviceId;
  final String pairCode;
  final String deviceName;
  final String deviceType;
  final int protocolVersion;
  final List<String> capabilities;
  final TrustedPermissions permissions;
  final int updatedAtEpochSeconds;

  const TrustedDeviceRecord({
    required this.deviceId,
    this.pairCode = '',
    required this.deviceName,
    required this.deviceType,
    required this.protocolVersion,
    required this.capabilities,
    required this.permissions,
    required this.updatedAtEpochSeconds,
  });

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'pairCode': pairCode,
      'deviceName': deviceName,
      'deviceType': deviceType,
      'protocolVersion': protocolVersion,
      'capabilities': capabilities,
      'permissions': permissions.toJson(),
      'updatedAtEpochSeconds': updatedAtEpochSeconds,
    };
  }

  factory TrustedDeviceRecord.fromJson(Map<String, dynamic> json) {
    final rawCapabilities = json['capabilities'];
    final capabilities = rawCapabilities is List
        ? rawCapabilities.map((item) => item.toString()).toList()
        : <String>[];

    final rawPermissions = json['permissions'];

    return TrustedDeviceRecord(
      deviceId: (json['deviceId'] ?? '').toString(),
      pairCode: (json['pairCode'] ?? '').toString(),
      deviceName: (json['deviceName'] ?? 'Unknown Device').toString(),
      deviceType: (json['deviceType'] ?? 'unknown').toString(),
      protocolVersion: int.tryParse('${json['protocolVersion']}') ?? 1,
      capabilities: capabilities,
      permissions: rawPermissions is Map<String, dynamic>
          ? TrustedPermissions.fromJson(rawPermissions)
          : const TrustedPermissions(),
      updatedAtEpochSeconds:
          int.tryParse('${json['updatedAtEpochSeconds']}') ?? 0,
    );
  }
}

class TrustStoreService {
  static const String _fileName = '.pcremote_trust_store.json';

  static Future<Map<String, TrustedDeviceRecord>> load() async {
    final file = await _storeFile();
    if (!await file.exists()) {
      return <String, TrustedDeviceRecord>{};
    }

    try {
      final parsed = jsonDecode(await file.readAsString());
      if (parsed is! Map<String, dynamic>) {
        return <String, TrustedDeviceRecord>{};
      }

      final rawDevices = parsed['trustedDevices'];
      if (rawDevices is! List) {
        return <String, TrustedDeviceRecord>{};
      }

      final devices = <String, TrustedDeviceRecord>{};
      for (final item in rawDevices) {
        if (item is! Map<String, dynamic>) {
          continue;
        }
        final record = TrustedDeviceRecord.fromJson(item);
        if (record.deviceId.isNotEmpty) {
          devices[record.deviceId] = record;
        }
      }

      return devices;
    } catch (_) {
      return <String, TrustedDeviceRecord>{};
    }
  }

  static Future<void> save(Map<String, TrustedDeviceRecord> devices) async {
    final file = await _storeFile();
    final payload = {
      'schemaVersion': 1,
      'trustedDevices': devices.values.map((item) => item.toJson()).toList(),
    };

    await file.writeAsString(jsonEncode(payload));
  }

  static Future<File> _storeFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}${Platform.pathSeparator}$_fileName');
    } catch (_) {
      final home = Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      return File('$home${Platform.pathSeparator}$_fileName');
    }
  }
}
