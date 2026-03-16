import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/local_server_service.dart';
import '../services/websocket_service.dart';

class ConnectionPanel extends StatefulWidget {
  final LocalServerService serverService;
  final WebSocketService wsService;

  const ConnectionPanel({
    super.key,
    required this.serverService,
    required this.wsService,
  });

  @override
  State<ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends State<ConnectionPanel> {
  final Map<String, _DiscoveredDevice> _discoveredDevices =
      <String, _DiscoveredDevice>{};

  List<ConnectionRequest> _pendingRequests = <ConnectionRequest>[];
  List<PairedDevice> _pairedDevices = <PairedDevice>[];
  bool _isConnecting = false;
  bool _isDiscovering = false;
  StreamSubscription<List<ConnectionRequest>>? _pendingSub;
  StreamSubscription<List<PairedDevice>>? _pairedSub;

  @override
  void initState() {
    super.initState();
    _pendingRequests = widget.serverService.currentPendingRequests;
    _pairedDevices = widget.serverService.currentPairedDevices;
    _pendingSub = widget.serverService.pendingRequestsStream.listen((pending) {
      if (!mounted) {
        return;
      }
      setState(() => _pendingRequests = pending);
    });
    _pairedSub = widget.serverService.pairedDevicesStream.listen((paired) {
      if (!mounted) {
        return;
      }
      setState(() => _pairedDevices = paired);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _discoverDevices();
    });
  }

  @override
  void dispose() {
    _pendingSub?.cancel();
    _pairedSub?.cancel();
    super.dispose();
  }

  String _defaultDeviceName() {
    if (Platform.isAndroid) {
      return 'Android Phone';
    }
    if (Platform.isWindows) {
      return 'Windows Device';
    }
    return 'Flutter Device';
  }

  Future<void> _pairWithDiscoveredDevice(_DiscoveredDevice device) async {
    setState(() => _isConnecting = true);
    final success = await widget.wsService.connect(
      device.host,
      serverPort: device.serverPort,
      clientPort: 8766,
      deviceName: _defaultDeviceName(),
    );

    if (!mounted) {
      return;
    }

    setState(() => _isConnecting = false);
    _showMessage(
      success
          ? 'Request sent to ${device.name}'
          : 'Failed to send request to ${device.name}',
      isError: !success,
    );
  }

  Future<void> _discoverDevices() async {
    if (_isDiscovering) {
      return;
    }

    setState(() {
      _isDiscovering = true;
      _discoveredDevices.clear();
    });

    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;

    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;

      sub = socket.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }

        final datagram = socket?.receive();
        if (datagram == null) {
          return;
        }

        _handleDiscoveryResponse(datagram);
      });

      final payload = utf8.encode(jsonEncode({'type': 'discover'}));
      final targets = await _discoveryTargets();
      for (final target in targets) {
        socket.send(payload, target, 8766);
      }

      await Future<void>.delayed(const Duration(seconds: 3));
    } catch (_) {
      _showMessage('Unable to scan devices on this network', isError: true);
    } finally {
      await sub?.cancel();
      socket?.close();
      if (mounted) {
        setState(() => _isDiscovering = false);
      }
    }
  }

  Future<List<InternetAddress>> _discoveryTargets() async {
    final targets = <InternetAddress>{
      InternetAddress('255.255.255.255'),
    };

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final host = address.address;
          final parts = host.split('.');
          if (parts.length != 4) {
            continue;
          }

          final last = int.tryParse(parts[3]);
          if (last == null) {
            continue;
          }

          // Best-effort /24 broadcast target for common home LANs.
          targets
              .add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
        }
      }
    } catch (_) {}

    return targets.toList();
  }

  void _handleDiscoveryResponse(Datagram datagram) {
    try {
      final parsed = jsonDecode(utf8.decode(datagram.data));
      if (parsed is! Map<String, dynamic>) {
        return;
      }

      if (parsed['type']?.toString() != 'discover-ack') {
        return;
      }

      final name = parsed['name']?.toString() ?? 'Remote Device';
      final deviceId = parsed['deviceId']?.toString() ?? '';

      String host = datagram.address.address;
      int serverPort = 8765;

      final ws = parsed['ws']?.toString() ?? '';
      if (ws.isNotEmpty) {
        final wsUri = Uri.tryParse(ws);
        if (wsUri != null) {
          if (wsUri.host.isNotEmpty) {
            host = wsUri.host;
          }
          if (wsUri.hasPort) {
            serverPort = wsUri.port;
          }
        }
      } else {
        final tcpValue = parsed['tcp']?.toString();
        final tcpPort = int.tryParse(tcpValue ?? '');
        if (tcpPort != null) {
          serverPort = tcpPort;
        }
      }

      if (_isOwnServer(
        deviceId: deviceId,
        host: host,
        serverPort: serverPort,
      )) {
        return;
      }

      final key = '$host:$serverPort';
      if (!mounted) {
        return;
      }

      setState(() {
        _discoveredDevices[key] = _DiscoveredDevice(
          name: name,
          host: host,
          serverPort: serverPort,
        );
      });
    } catch (_) {}
  }

  bool _isOwnServer({
    required String deviceId,
    required String host,
    required int serverPort,
  }) {
    if (deviceId.isNotEmpty && deviceId == widget.serverService.deviceId) {
      return true;
    }

    final localIp = widget.serverService.localIp;
    return serverPort == widget.serverService.port &&
        (host == localIp || host == '127.0.0.1' || host == 'localhost');
  }

  String _deviceAddressLabel(_DiscoveredDevice device) {
    final isMobileName =
        device.name.toLowerCase().contains('android') ||
            device.name.toLowerCase().contains('phone') ||
            device.name.toLowerCase().contains('mobile');

    if (Platform.isWindows && isMobileName) {
      return 'localhost:${device.serverPort}';
    }

    return '${device.host}:${device.serverPort}';
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: _isDiscovering ? null : _discoverDevices,
                    icon: _isDiscovering
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_find),
                    label: Text(
                      _isDiscovering ? 'Scanning LAN...' : 'Scan devices',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Devices',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 10),
                  if (_pendingRequests.isEmpty && _discoveredDevices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No devices found yet. Tap Scan devices.'),
                    ),
                  ..._pendingRequests.map(
                    (request) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: Colors.orange.withValues(alpha: 0.08),
                      child: ListTile(
                        leading: const Icon(Icons.mark_email_unread_outlined),
                        title: Text(request.deviceName),
                        subtitle: Text(
                          'Incoming request',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        trailing: Wrap(
                          spacing: 6,
                          children: [
                            FilledButton(
                              onPressed: () async {
                                await widget.serverService
                                    .acceptRequest(request.clientId);
                                _showMessage(
                                  'Accepted ${request.deviceName}',
                                );
                              },
                              child: const Text('Accept'),
                            ),
                            OutlinedButton(
                              onPressed: () async {
                                await widget.serverService
                                    .rejectRequest(request.clientId);
                                _showMessage(
                                  'Rejected ${request.deviceName}',
                                );
                              },
                              child: const Text('Reject'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ..._discoveredDevices.values.map(
                    (device) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.devices),
                        title: Text(device.name),
                        subtitle: Text(_deviceAddressLabel(device)),
                        trailing: FilledButton(
                          onPressed: _isConnecting
                              ? null
                              : () => _pairWithDiscoveredDevice(device),
                          child: const Text('Send request'),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Paired devices',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  if (_pairedDevices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('No paired devices yet.'),
                    ),
                  ..._pairedDevices.map(
                    (device) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: Colors.green.withValues(alpha: 0.07),
                      child: ListTile(
                        leading: const Icon(Icons.verified_user),
                        title: Text(device.deviceName),
                        subtitle: Text(
                          device.pairCode.isEmpty
                              ? 'Paired'
                              : 'Pair code: ${device.pairCode}',
                        ),
                        trailing: OutlinedButton(
                          onPressed: () async {
                            await widget.serverService
                                .unpairDevice(device.clientId);
                            _showMessage('Unpaired ${device.deviceName}');
                          },
                          child: const Text('Unpair'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscoveredDevice {
  final String name;
  final String host;
  final int serverPort;

  const _DiscoveredDevice({
    required this.name,
    required this.host,
    required this.serverPort,
  });
}
