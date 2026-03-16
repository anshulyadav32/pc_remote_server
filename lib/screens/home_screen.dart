import 'dart:io';

import 'package:flutter/material.dart';

import '../services/local_server_service.dart';
import '../services/websocket_service.dart';
import '../widgets/browser_control_panel.dart';
import '../widgets/clipboard_panel.dart';
import '../widgets/connection_panel.dart';
import '../widgets/media_control_panel.dart';
import '../widgets/mouse_control_panel.dart';
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

  Widget _buildBrandLogo() {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          colors: [Color(0xFF3E7BFA), Color(0xFF25C2A0)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x5525C2A0),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: const Icon(Icons.settings_remote_rounded,
          color: Colors.white, size: 36),
    );
  }

  @override
  void initState() {
    super.initState();

    // Auto-start server on launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _serverService.start(port: 8765);
    });
  }

  @override
  void dispose() {
    _serverService.dispose();
    _wsService.dispose();
    super.dispose();
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: Material(
        color: selected ? const Color(0xFF2A2F3C) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            setState(() => _selectedSection = section);
            if (compact) {
              Navigator.of(context).pop();
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(icon, color: Colors.white70, size: 32),
                const SizedBox(width: 18),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 20,
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
          colors: [Color(0xFF161B24), Color(0xFF141923)],
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildBrandLogo(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'PCRemote',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 42,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          _deviceTitle(),
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Devices',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildMenuItem(
              icon: Icons.dialpad,
              label: 'Client area',
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
              child: Divider(color: Colors.white30),
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
          length: 6,
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
                    Tab(icon: Icon(Icons.keyboard), text: 'Text'),
                    Tab(icon: Icon(Icons.content_paste), text: 'Clipboard'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    MouseControlPanel(wsService: _wsService),
                    MediaControlPanel(wsService: _wsService),
                    BrowserControlPanel(wsService: _wsService),
                    WindowControlPanel(wsService: _wsService),
                    TextInputPanel(wsService: _wsService),
                    ClipboardPanel(wsService: _wsService),
                  ],
                ),
              ),
            ],
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
                      'PCRemote lets you discover devices on LAN, send pairing requests, and control permissions with a KDE Connect-like workflow.',
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
    final compact = MediaQuery.of(context).size.width < 1000;

    return Scaffold(
      drawer: compact ? Drawer(child: _buildMenu(compact: true)) : null,
      appBar: AppBar(
        title: Text(
          _selectedSection == _MenuSection.client
              ? 'Client Area'
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
                        color:
                            isRunning ? Colors.greenAccent : Colors.redAccent,
                        boxShadow: isRunning
                            ? [
                                BoxShadow(
                                  color:
                                      Colors.greenAccent.withValues(alpha: 0.6),
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
                        color:
                            isRunning ? Colors.greenAccent : Colors.redAccent,
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
      body: Row(
        children: [
          if (!compact) _buildMenu(compact: false),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }
}
