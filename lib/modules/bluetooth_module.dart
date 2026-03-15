import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:win_ble/win_ble.dart';
import 'package:win_ble/win_file.dart';

class BluetoothScanDevice {
  BluetoothScanDevice({
    required this.id,
    required this.name,
    this.nativeDevice,
  });

  final String id;
  final String name;
  final Object? nativeDevice;
}

class BluetoothModule {
  static bool _isWindowsBackendInitialized = false;
  static final Map<String, BluetoothScanDevice> _windowsScanDevices =
      <String, BluetoothScanDevice>{};

  static bool get isSupportedPlatform {
    return !kIsWeb &&
        (Platform.isAndroid ||
            Platform.isIOS ||
            Platform.isMacOS ||
            Platform.isLinux ||
            Platform.isWindows);
  }

  static bool get isBluetoothUiEnabled {
    return isSupportedPlatform;
  }

  static Future<void> _ensureWindowsInitialized() async {
    if (!Platform.isWindows || _isWindowsBackendInitialized) {
      return;
    }

    await WinBle.initialize(serverPath: await WinServer.path());
    _isWindowsBackendInitialized = true;
  }

  static BluetoothAdapterState _mapWinBleState(BleState state) {
    switch (state) {
      case BleState.On:
        return BluetoothAdapterState.on;
      case BleState.Off:
        return BluetoothAdapterState.off;
      case BleState.Disabled:
      case BleState.Unsupported:
        return BluetoothAdapterState.unavailable;
      case BleState.Unknown:
        return BluetoothAdapterState.unknown;
    }
  }

  static Stream<BluetoothAdapterState> get adapterStateStream {
    if (Platform.isWindows) {
      return WinBle.bleState.map(_mapWinBleState);
    }

    return FlutterBluePlus.adapterState;
  }

  static Stream<List<BluetoothScanDevice>> get scanResultsStream {
    if (Platform.isWindows) {
      return WinBle.scanStream.map((event) {
        final address = event.address;
        final resolvedName =
            event.name.trim().isEmpty ? 'Unknown Device' : event.name;
        _windowsScanDevices[address] = BluetoothScanDevice(
          id: address,
          name: resolvedName,
          nativeDevice: event,
        );
        return _windowsScanDevices.values.toList(growable: false);
      });
    }

    return FlutterBluePlus.scanResults.map((results) {
      return results.map((result) {
        final name = resolveDeviceName(result);
        return BluetoothScanDevice(
          id: result.device.remoteId.toString(),
          name: name,
          nativeDevice: result.device,
        );
      }).toList(growable: false);
    });
  }

  static Future<bool> get isSupported async {
    try {
      if (Platform.isWindows) {
        await _ensureWindowsInitialized();
        final state = await WinBle.getBluetoothState();
        return state == BleState.On || state == BleState.Off;
      }

      return await FlutterBluePlus.isSupported;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestPermissions() async {
    try {
      if (Platform.isWindows) {
        await _ensureWindowsInitialized();
        return true;
      }

      if (Platform.isAndroid) {
        final statuses = await <Permission>[
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
          Permission.locationWhenInUse,
        ].request();

        return statuses.values.every((status) =>
            status.isGranted || status.isLimited || status.isRestricted);
      }

      if (Platform.isIOS) {
        final statuses = await <Permission>[
          Permission.bluetooth,
          Permission.locationWhenInUse,
        ].request();

        return statuses.values.every((status) =>
            status.isGranted || status.isLimited || status.isRestricted);
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> startScan(
      {Duration timeout = const Duration(seconds: 15)}) async {
    if (Platform.isWindows) {
      await _ensureWindowsInitialized();
      _windowsScanDevices.clear();
      WinBle.startScanning();
      if (timeout > Duration.zero) {
        Future.delayed(timeout, () {
          try {
            WinBle.stopScanning();
          } catch (_) {}
        });
      }
      return;
    }

    return FlutterBluePlus.startScan(timeout: timeout);
  }

  static Future<void> stopScan() async {
    if (Platform.isWindows) {
      await _ensureWindowsInitialized();
      WinBle.stopScanning();
      return;
    }

    return FlutterBluePlus.stopScan();
  }

  static Future<void> connectDevice(BluetoothScanDevice device) async {
    if (Platform.isWindows) {
      await _ensureWindowsInitialized();
      await WinBle.connect(device.id);
      return;
    }

    final native = device.nativeDevice;
    if (native is BluetoothDevice) {
      await native.connect();
    } else {
      throw StateError('Invalid Bluetooth device object');
    }
  }

  static Future<void> dispose() async {
    if (Platform.isWindows && _isWindowsBackendInitialized) {
      WinBle.dispose();
      _isWindowsBackendInitialized = false;
    }
  }

  static String resolveDeviceName(ScanResult result) {
    if (result.device.platformName.isNotEmpty) {
      return result.device.platformName;
    }

    if (result.advertisementData.advName.isNotEmpty) {
      return result.advertisementData.advName;
    }

    return 'Unknown Device';
  }
}
