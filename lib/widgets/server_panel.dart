import 'dart:async';

import 'package:flutter/material.dart';

import '../services/local_server_service.dart';

class ServerPanel extends StatefulWidget {
  final LocalServerService serverService;

  const ServerPanel({super.key, required this.serverService});

  @override
  State<ServerPanel> createState() => _ServerPanelState();
}

class _ServerPanelState extends State<ServerPanel> {
  final _portController = TextEditingController(text: '8765');

  final List<String> _logs = <String>[];
  List<PairedDevice> _pairedDevices = <PairedDevice>[];
  StreamSubscription<String>? _logSub;
  StreamSubscription<List<PairedDevice>>? _pairedSub;
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    _logSub = widget.serverService.logStream.listen((entry) {
      if (!mounted) {
        return;
      }
      setState(() {
        _logs.insert(0, entry);
        if (_logs.length > 50) {
          _logs.removeLast();
        }
      });
    });

    _pairedSub = widget.serverService.pairedDevicesStream.listen((paired) {
      if (!mounted) {
        return;
      }
      setState(() => _pairedDevices = paired);
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _pairedSub?.cancel();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _startServer() async {
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _showMessage('Please enter a valid server port (1-65535)', isError: true);
      return;
    }

    setState(() => _isBusy = true);
    final started = await widget.serverService.start(port: port);
    if (mounted) {
      setState(() => _isBusy = false);
    }

    _showMessage(
      started ? 'Server started' : 'Failed to start server',
      isError: !started,
    );
  }

  Future<void> _stopServer() async {
    setState(() => _isBusy = true);
    await widget.serverService.stop();
    if (mounted) {
      setState(() => _isBusy = false);
    }
    _showMessage('Server stopped');
  }

  void _showMessage(String text, {bool isError = false}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  Future<void> _setPermission(
    PairedDevice device,
    String plugin,
    bool enabled,
  ) async {
    var next = device.permissions;
    switch (plugin) {
      case 'clipboard':
        next = next.copyWith(clipboard: enabled);
        break;
      case 'media':
        next = next.copyWith(media: enabled);
        break;
      case 'browser':
        next = next.copyWith(browser: enabled);
        break;
      case 'window':
        next = next.copyWith(window: enabled);
        break;
      case 'remote_input':
        next = next.copyWith(remoteInput: enabled);
        break;
      case 'text_input':
        next = next.copyWith(textInput: enabled);
        break;
    }

    await widget.serverService.updatePermissions(device.clientId, next);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status card — shown first for quick overview
          StreamBuilder<bool>(
            stream: widget.serverService.runningStream,
            initialData: widget.serverService.isRunning,
            builder: (context, snapshot) {
              final running = snapshot.data ?? false;
              return Card(
                color: running
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.red.withValues(alpha: 0.08),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            running ? Icons.circle : Icons.circle_outlined,
                            size: 12,
                            color: running ? Colors.green : Colors.red,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            running ? 'Running' : 'Stopped',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: running ? Colors.green : Colors.red,
                              fontSize: 14,
                            ),
                          ),
                          const Spacer(),
                          StreamBuilder<int>(
                            stream: widget.serverService.clientCountStream,
                            initialData: 0,
                            builder: (context, snap) {
                              final count = snap.data ?? 0;
                              return Chip(
                                avatar: const Icon(Icons.devices, size: 14),
                                label: Text('$count connected'),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                labelPadding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                              );
                            },
                          ),
                        ],
                      ),
                      if (running) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                          widget.serverService.wsUrl,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontFamily: 'monospace'),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          // Server Settings card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Server Settings',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _portController,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      hintText: '8765',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.settings_ethernet),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  StreamBuilder<bool>(
                    stream: widget.serverService.runningStream,
                    initialData: widget.serverService.isRunning,
                    builder: (context, snapshot) {
                      final running = snapshot.data ?? false;
                      return Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed:
                                  (_isBusy || running) ? null : _startServer,
                              icon: const Icon(Icons.play_arrow, size: 18),
                              label: Text(
                                _isBusy && !running ? 'Starting…' : 'Start',
                              ),
                              style: FilledButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed:
                                  (_isBusy || !running) ? null : _stopServer,
                              icon: const Icon(Icons.stop_circle, size: 18),
                              label: Text(
                                _isBusy && running ? 'Stopping…' : 'Stop',
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Paired Devices
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Paired Devices',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  if (_pairedDevices.isEmpty)
                    Text(
                      'No paired devices yet',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else
                    ..._pairedDevices.map(
                      (device) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.verified_user, size: 16),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      device.deviceName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => widget.serverService
                                        .unpairDevice(device.clientId),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.red,
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8),
                                    ),
                                    child: const Text('Unpair',
                                        style: TextStyle(fontSize: 12)),
                                  ),
                                ],
                              ),
                              Text(
                                '${device.deviceType} · port ${device.clientPort}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  _permChip(device, 'clipboard', 'Clipboard',
                                      device.permissions.clipboard),
                                  _permChip(device, 'media', 'Media',
                                      device.permissions.media),
                                  _permChip(device, 'browser', 'Browser',
                                      device.permissions.browser),
                                  _permChip(device, 'window', 'Window',
                                      device.permissions.window),
                                  _permChip(device, 'remote_input', 'Remote',
                                      device.permissions.remoteInput),
                                  _permChip(device, 'text_input', 'Text',
                                      device.permissions.textInput),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Server Logs
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Logs',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  if (_logs.isEmpty)
                    Text(
                      'No logs yet',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else
                    ..._logs.take(15).map(
                          (entry) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              entry,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(fontFamily: 'monospace'),
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _permChip(
    PairedDevice device,
    String plugin,
    String label,
    bool selected,
  ) {
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: selected,
      onSelected: (v) => _setPermission(device, plugin, v),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}
