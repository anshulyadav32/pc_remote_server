import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'screens/home_screen.dart';
import 'services/background_work_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize background work services
  final backgroundWorkService = BackgroundWorkService();
  await backgroundWorkService.initialize();
  
  runApp(const PCRemoteApp());
}

class PCRemoteApp extends StatelessWidget {
  const PCRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PCRemote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const _PermissionBootstrap(),
    );
  }
}

class _PermissionBootstrap extends StatefulWidget {
  const _PermissionBootstrap();

  @override
  State<_PermissionBootstrap> createState() => _PermissionBootstrapState();
}

class _PermissionBootstrapState extends State<_PermissionBootstrap> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestAndroidPermissions();
    });
  }

  Future<void> _requestAndroidPermissions() async {
    if (!Platform.isAndroid) {
      return;
    }

    final permissions = <Permission>[
      Permission.notification,
      Permission.locationWhenInUse,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.nearbyWifiDevices,
    ];

    for (final permission in permissions) {
      await permission.request();
    }

    // Request battery optimization exemption and notification runtime permission
    await Permission.ignoreBatteryOptimizations.request();
    await Permission.notification.request();
  }

  @override
  Widget build(BuildContext context) {
    return const HomeScreen();
  }
}
