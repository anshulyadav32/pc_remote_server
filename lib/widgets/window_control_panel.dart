import 'package:flutter/material.dart';

import '../services/websocket_service.dart';

class WindowControlPanel extends StatelessWidget {
  final WebSocketService wsService;

  const WindowControlPanel({super.key, required this.wsService});

  void _sendCommand(Map<String, dynamic> command) {
    wsService.sendCommand(command);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Window Management',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _buildButton(context, 'Alt+Tab', Icons.alt_route,
                      () => _sendCommand({'type': 'alt_tab'})),
                  _buildButton(context, 'Minimize', Icons.minimize,
                      () => _sendCommand({'type': 'minimize_window'})),
                  _buildButton(context, 'Maximize', Icons.crop_square,
                      () => _sendCommand({'type': 'maximize_window'})),
                  _buildButton(context, 'Fullscreen', Icons.fullscreen,
                      () => _sendCommand({'type': 'toggle_fullscreen'})),
                  _buildButton(
                    context,
                    'Close',
                    Icons.close,
                    () => _sendCommand({'type': 'close_window'}),
                    Colors.red,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildButton(
      BuildContext context, String label, IconData icon, VoidCallback onPressed,
      [Color? backgroundColor]) {
    return SizedBox(
      width: 150,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: backgroundColor,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        ),
      ),
    );
  }
}
