import 'package:flutter/material.dart';

import '../services/websocket_service.dart';

class MediaControlPanel extends StatelessWidget {
  final WebSocketService wsService;

  const MediaControlPanel({super.key, required this.wsService});

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
            'Media Controls',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 20),
          _buildSection(
            context,
            'Playback',
            Icons.play_circle_outline,
            [
              _buildButton(context, 'Previous', Icons.skip_previous,
                  () => _sendCommand({'type': 'media_previous'})),
              _buildButton(context, 'Play/Pause', Icons.play_arrow,
                  () => _sendCommand({'type': 'media_play_pause'})),
              _buildButton(context, 'Next', Icons.skip_next,
                  () => _sendCommand({'type': 'media_next'})),
            ],
          ),
          const SizedBox(height: 16),
          _buildSection(
            context,
            'Seek',
            Icons.fast_forward,
            [
              _buildButton(context, 'Backward', Icons.fast_rewind,
                  () => _sendCommand({'type': 'seek_backward'})),
              _buildButton(context, 'Space', Icons.space_bar,
                  () => _sendCommand({'type': 'space'})),
              _buildButton(context, 'Forward', Icons.fast_forward,
                  () => _sendCommand({'type': 'seek_forward'})),
            ],
          ),
          const SizedBox(height: 16),
          _buildSection(
            context,
            'Volume',
            Icons.volume_up,
            [
              _buildButton(context, 'Down', Icons.volume_down,
                  () => _sendCommand({'type': 'volume_down'})),
              _buildButton(context, 'Mute', Icons.volume_mute,
                  () => _sendCommand({'type': 'volume_mute'})),
              _buildButton(context, 'Up', Icons.volume_up,
                  () => _sendCommand({'type': 'volume_up'})),
            ],
          ),
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
