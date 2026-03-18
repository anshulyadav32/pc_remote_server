import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/background_work_service.dart';
import '../services/local_server_service.dart';
import '../services/websocket_service.dart';
import '../widgets/browser_control_panel.dart';
import '../widgets/clipboard_panel.dart';
import '../widgets/connection_panel.dart';
import '../widgets/media_control_panel.dart';
import '../widgets/mouse_control_panel.dart';
import '../widgets/keyboard_panel.dart';
import '../widgets/server_panel.dart';
import '../widgets/text_input_panel.dart';
import '../widgets/window_control_panel.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _MenuSection { client, pair, settings, about }

class _HomeScreenState extends State<HomeScreen> {
  final LocalServerService _serverService = LocalServerService();
  final WebSocketService _wsService = WebSocketService();
  _MenuSection _selectedSection = _MenuSection.client;
  StreamSubscription<List<PairedDevice>>? _serverPairedDevicesSubscription;
  StreamSubscription<List<PairedDevice>>? _remotePairedDevicesSubscription;
  List<PairedDevice> _serverPairedDevices = <PairedDevice>[];
  List<PairedDevice> _remotePairedDevices = <PairedDevice>[];
  String _clientSectionLabel = 'No connected device';

  Widget _buildBrandLogo() {
    return const Icon(
      Icons.phone_android_rounded,
      color: Color(0xFFBCC2CD),
      size: 56,
    );
  }

  @override
  void initState() {
    super.initState();

    _serverPairedDevices = _serverService.currentPairedDevices;
    _remotePairedDevices = _wsService.currentPairedDevices;
    _clientSectionLabel = _buildClientSectionLabel(_allPairedDevices());

    _serverPairedDevicesSubscription =
        _serverService.pairedDevicesStream.listen(
      (devices) {
        if (!mounted) {
          return;
        }
        setState(() {
          _serverPairedDevices = devices;
          _clientSectionLabel = _buildClientSectionLabel(_allPairedDevices());
        });
      },
    );

    _remotePairedDevicesSubscription = _wsService.pairedDevicesStream.listen(
      (devices) {
        if (!mounted) {
          return;
        }
        setState(() {
          _remotePairedDevices = devices;
          _clientSectionLabel = _buildClientSectionLabel(_allPairedDevices());
        });
      },
    );

    // Auto-start server on launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _serverService.start(port: 8765);
    });
  }

  @override
  void dispose() {
    _serverPairedDevicesSubscription?.cancel();
    _remotePairedDevicesSubscription?.cancel();
    _serverService.dispose();
    _wsService.dispose();
    
    // Shutdown background work services
    BackgroundWorkService().shutdown();
    super.dispose();
  }

  List<PairedDevice> _allPairedDevices() {
    final merged = <String, PairedDevice>{};

    for (final device in _serverPairedDevices) {
      final key = device.deviceId.isEmpty ? device.clientId : device.deviceId;
      merged[key] = device;
    }

    for (final device in _remotePairedDevices) {
      final key = device.deviceId.isEmpty ? device.clientId : device.deviceId;
      merged[key] = device;
    }

    return merged.values.toList();
  }

  String _buildClientSectionLabel(List<PairedDevice> pairedDevices) {
    if (pairedDevices.isEmpty) {
      return 'No connected device';
    }

    final firstName = pairedDevices.first.deviceName.trim();
    if (pairedDevices.length == 1) {
      return firstName.isEmpty ? 'Connected device' : firstName;
    }

    final head = firstName.isEmpty ? 'Connected device' : firstName;
    return '$head +${pairedDevices.length - 1}';
  }

  String _activeDeviceTitle() {
    if (_clientSectionLabel == 'No connected device') {
      return _deviceTitle();
    }
    return _clientSectionLabel;
  }

  String _deviceTitle() {
    if (Platform.isAndroid) return 'Android Device';
    if (Platform.isWindows) return 'Windows Device';
    if (Platform.isLinux) return 'Linux Device';
    if (Platform.isMacOS) return 'macOS Device';
    return 'Flutter Device';
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required _MenuSection section,
    required bool compact,
  }) {
    final selected = _selectedSection == section;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      child: Material(
        color: selected ? const Color(0xFF475268) : Colors.transparent,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: () {
            setState(() => _selectedSection = section);
            if (compact) {
              Navigator.of(context).pop();
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: selected
                      ? const Color(0xFFE6EAF2)
                      : const Color(0xFFB9BFCA),
                  size: 22,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: selected
                          ? const Color(0xFFF1F4FA)
                          : const Color(0xFFC2C8D2),
                      fontSize: 21,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenu({required bool compact}) {
    return Container(
      width: compact ? null : 340,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A202B), Color(0xFF171D28)],
        ),
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(34),
          bottomRight: Radius.circular(34),
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildBrandLogo(),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _activeDeviceTitle(),
                          style: const TextStyle(
                            color: Color(0xFFE9EDF4),
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _deviceTitle(),
                          style: const TextStyle(
                            color: Color(0xFF9FA7B3),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(
                      Icons.more_vert,
                      color: Color(0xFF8D96A4),
                      size: 26,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 26),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Devices',
                style: TextStyle(
                  color: Color(0xFFBEC4CF),
                  fontSize: 40,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
            _buildMenuItem(
              icon: Icons.phone_android_rounded,
              label: _clientSectionLabel,
              section: _MenuSection.client,
              compact: compact,
            ),
            _buildMenuItem(
              icon: Icons.add_circle_outline,
              label: 'Pair new device',
              section: _MenuSection.pair,
              compact: compact,
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Divider(color: Color(0xFF6C7481), thickness: 1.2),
            ),
            _buildMenuItem(
              icon: Icons.settings,
              label: 'Settings',
              section: _MenuSection.settings,
              compact: compact,
            ),
            _buildMenuItem(
              icon: Icons.info,
              label: 'About',
              section: _MenuSection.about,
              compact: compact,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_selectedSection) {
      case _MenuSection.client:
        return DefaultTabController(
          length: 7,
          child: SafeArea(
            child: Column(
              children: [
                Material(
                  elevation: 1,
                  child: TabBar(
                    isScrollable: true,
                    tabs: const [
                      Tab(icon: Icon(Icons.mouse), text: 'Trackpad'),
                      Tab(icon: Icon(Icons.music_note), text: 'Media'),
                      Tab(icon: Icon(Icons.web), text: 'Browser'),
                      Tab(icon: Icon(Icons.window), text: 'Window'),
                      Tab(icon: Icon(Icons.keyboard), text: 'Keyboard'),
                      Tab(icon: Icon(Icons.text_fields), text: 'Text'),
                      Tab(icon: Icon(Icons.content_paste), text: 'Clipboard'),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      MouseControlPanel(wsService: _wsService),
                      MediaControlPanel(wsService: _wsService),
                      BrowserControlPanel(wsService: _wsService),
                      WindowControlPanel(wsService: _wsService),
                      KeyboardPanel(wsService: _wsService),
                      TextInputPanel(wsService: _wsService),
                      ClipboardPanel(wsService: _wsService),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      case _MenuSection.pair:
        return ConnectionPanel(
          serverService: _serverService,
          wsService: _wsService,
        );
      case _MenuSection.settings:
        return ServerPanel(serverService: _serverService);
      case _MenuSection.about:
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'About PCRemote',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'PCRemote lets you discover devices on WLAN, send pairing requests, and control permissions with a KDE Connect-like workflow.',
                      style: TextStyle(fontSize: 15),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: Drawer(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topRight: Radius.circular(34),
            bottomRight: Radius.circular(34),
          ),
        ),
        child: _buildMenu(compact: true),
      ),
      appBar: AppBar(
        title: Text(
          _selectedSection == _MenuSection.client
              ? _clientSectionLabel
              : _selectedSection == _MenuSection.pair
                  ? 'Pair New Device'
                  : _selectedSection == _MenuSection.settings
                      ? 'Settings'
                      : 'About',
        ),
        elevation: 2,
        actions: [
          StreamBuilder<bool>(
            stream: _serverService.runningStream,
            initialData: _serverService.isRunning,
            builder: (context, snapshot) {
              final isRunning = snapshot.data ?? false;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isRunning
                            ? const Color(0xFF145A32)
                            : const Color(0xFF8B1E1E),
                        boxShadow: isRunning
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF145A32)
                                      .withValues(alpha: 0.45),
                                  blurRadius: 6,
                                  spreadRadius: 2,
                                )
                              ]
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isRunning ? 'Server On' : 'Server Off',
                      style: TextStyle(
                        color: isRunning
                            ? const Color(0xFF145A32)
                            : const Color(0xFF8B1E1E),
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildContent(),
    );
  }
}
