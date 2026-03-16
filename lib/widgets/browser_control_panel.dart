import 'package:flutter/material.dart';

import '../services/websocket_service.dart';

class BrowserControlPanel extends StatelessWidget {
  final WebSocketService wsService;

  const BrowserControlPanel({super.key, required this.wsService});

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
            'Browser Controls',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 20),
          _buildSection(context, 'Navigation', Icons.public, [
            _buildButton(context, 'Back', Icons.arrow_back,
                () => _sendCommand({'type': 'browser_back'})),
            _buildButton(context, 'Forward', Icons.arrow_forward,
                () => _sendCommand({'type': 'browser_forward'})),
            _buildButton(context, 'Refresh', Icons.refresh,
                () => _sendCommand({'type': 'browser_refresh'})),
            _buildButton(context, 'Home', Icons.home,
                () => _sendCommand({'type': 'browser_home'})),
          ]),
          const SizedBox(height: 16),
          _buildSection(context, 'Tabs', Icons.tab, [
            _buildButton(context, 'Previous', Icons.keyboard_arrow_left,
                () => _sendCommand({'type': 'previous_tab'})),
            _buildButton(context, 'New', Icons.add,
                () => _sendCommand({'type': 'new_tab'})),
            _buildButton(context, 'Next', Icons.keyboard_arrow_right,
                () => _sendCommand({'type': 'next_tab'})),
            _buildButton(context, 'Close', Icons.close,
                () => _sendCommand({'type': 'close_tab'})),
          ]),
        ],
      ),
    );
  }

  Widget _buildSection(BuildContext context, String title, IconData icon,
      List<Widget> buttons) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(spacing: 12, runSpacing: 12, children: buttons),
          ],
        ),
      ),
    );
  }

  Widget _buildButton(BuildContext context, String label, IconData icon,
      VoidCallback onPressed) {
    return SizedBox(
      width: 140,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        ),
      ),
    );
  }
}
