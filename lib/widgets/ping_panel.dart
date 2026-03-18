import 'dart:async';

import 'package:flutter/material.dart';

import '../services/websocket_service.dart';

class PingPanel extends StatefulWidget {
  final WebSocketService wsService;

  const PingPanel({super.key, required this.wsService});

  @override
  State<PingPanel> createState() => _PingPanelState();
}

class _PingPanelState extends State<PingPanel> {
  bool _isPinging = false;
  String? _pingResult;
  DateTime? _pingTime;
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;

  @override
  void initState() {
    super.initState();
    _messageSubscription = widget.wsService.messageStream.listen((message) {
      final type = message['type']?.toString() ?? '';
      if (type != 'pong' || !mounted || !_isPinging) {
        return;
      }

      final startedAt = _pingTime;
      final elapsed =
          startedAt == null ? null : DateTime.now().difference(startedAt);
      setState(() {
        _isPinging = false;
        _pingResult = elapsed == null
            ? 'Pong received'
            : 'Pong received in ${elapsed.inMilliseconds} ms';
        _pingTime = null;
      });
    });
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    super.dispose();
  }

  void _sendPing() {
    if (_isPinging || !widget.wsService.isConnected) {
      return;
    }

    setState(() {
      _isPinging = true;
      _pingTime = DateTime.now();
    });

    widget.wsService.sendCommand({'type': 'ping'});

    // Set a timeout for ping response
    Future<void>.delayed(const Duration(seconds: 5), () {
      if (mounted && _isPinging) {
        setState(() {
          _isPinging = false;
          _pingResult = 'No response (timeout)';
          _pingTime = null;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = widget.wsService.isConnected;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          Text(
            'Connectivity',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.send,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Ping Server',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_pingResult != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _pingResult!.contains('timeout')
                            ? Colors.red[50]
                            : Colors.green[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _pingResult!.contains('timeout')
                              ? Colors.red[300]!
                              : Colors.green[300]!,
                        ),
                      ),
                      child: Text(
                        _pingResult!,
                        style: TextStyle(
                          color: _pingResult!.contains('timeout')
                              ? Colors.red[800]
                              : Colors.green[800],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  FilledButton.icon(
                    onPressed: isConnected && !_isPinging ? _sendPing : null,
                    icon: _isPinging
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Theme.of(context).colorScheme.onPrimary,
                              ),
                            ),
                          )
                        : const Icon(Icons.send),
                    label: Text(_isPinging ? 'Pinging...' : 'Send Ping'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.cloud_queue,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Connection Status',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isConnected ? Colors.green : Colors.red,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isConnected ? 'Connected' : 'Disconnected',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color:
                              isConnected ? Colors.green[700] : Colors.red[700],
                        ),
                      ),
                    ],
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
