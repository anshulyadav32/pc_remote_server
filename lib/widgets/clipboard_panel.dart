import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/websocket_service.dart';

class ClipboardPanel extends StatefulWidget {
  final WebSocketService wsService;

  const ClipboardPanel({super.key, required this.wsService});

  @override
  State<ClipboardPanel> createState() => _ClipboardPanelState();
}

class _ClipboardPanelState extends State<ClipboardPanel> {
  final _clipboardController = TextEditingController();
  final _remoteClipboardController = TextEditingController();
  bool _autoClipboardEnabled = false;
  StreamSubscription<Map<String, dynamic>>? _messageSub;

  @override
  void initState() {
    super.initState();
    _messageSub = widget.wsService.messageStream.listen((message) {
      if (message['type'] == 'clipboard_content' ||
          message['type'] == 'clipboard.update') {
        setState(() {
          _remoteClipboardController.text =
              (message['content'] ?? message['text'] ?? '').toString();
        });
      }
    });
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _clipboardController.dispose();
    _remoteClipboardController.dispose();
    super.dispose();
  }

  void _setRemoteClipboard() {
    if (_clipboardController.text.trim().isEmpty) {
      return;
    }

    widget.wsService.sendCommand({
      'type': 'set_clipboard',
      'text': _clipboardController.text,
    });
    _showMessage('Remote clipboard updated');
  }

  void _getRemoteClipboard() {
    widget.wsService.sendCommand({'type': 'get_clipboard'});
    _showMessage('Requested remote clipboard');
  }

  void _copyToLocal() {
    if (_remoteClipboardController.text.isEmpty) {
      return;
    }

    Clipboard.setData(ClipboardData(text: _remoteClipboardController.text));
    _showMessage('Copied to local clipboard');
  }

  void _toggleAutoClipboard() {
    setState(() => _autoClipboardEnabled = !_autoClipboardEnabled);

    widget.wsService.sendCommand({
      'type': _autoClipboardEnabled
          ? 'enable_auto_clipboard'
          : 'disable_auto_clipboard',
    });

    _showMessage(_autoClipboardEnabled
        ? 'Auto clipboard enabled'
        : 'Auto clipboard disabled');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            color: _autoClipboardEnabled ? Colors.green[50] : null,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        _autoClipboardEnabled
                            ? Icons.sync
                            : Icons.sync_disabled,
                        color: _autoClipboardEnabled ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Auto Clipboard Sync',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _toggleAutoClipboard,
                    icon: Icon(
                        _autoClipboardEnabled ? Icons.sync_disabled : Icons.sync),
                    label: Text(_autoClipboardEnabled
                        ? 'Disable Auto Sync'
                        : 'Enable Auto Sync'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Remote Clipboard',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _remoteClipboardController,
                    maxLines: 5,
                    readOnly: true,
                    decoration: const InputDecoration(
                      hintText: 'Remote clipboard content',
                      border: OutlineInputBorder(),
                      filled: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _getRemoteClipboard,
                          icon: const Icon(Icons.download),
                          label: const Text('Get'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _copyToLocal,
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy Local'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Set Remote Clipboard',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _clipboardController,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: 'Type text to send to remote clipboard',
                      border: OutlineInputBorder(),
                      filled: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _setRemoteClipboard,
                    icon: const Icon(Icons.upload),
                    label: const Text('Set Clipboard'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
