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
  final _deviceNameController = TextEditingController();

  final Map<String, _DiscoveredDevice> _discoveredDevices =
      <String, _DiscoveredDevice>{};

  List<ConnectionRequest> _pendingRequests = <ConnectionRequest>[];
  bool _isConnecting = false;
  bool _isDiscovering = false;
  String _requestStatus = 'not_sent';
  StreamSubscription<String>? _requestSub;
  StreamSubscription<List<ConnectionRequest>>? _pendingSub;

  @override
  void initState() {
    super.initState();
    _deviceNameController.text = _defaultDeviceName();
    _pendingRequests = widget.serverService.currentPendingRequests;
    _requestSub = widget.wsService.requestStatusStream.listen((status) {
      if (!mounted) {
        return;
      }
      setState(() => _requestStatus = status);
    });
    _pendingSub = widget.serverService.pendingRequestsStream.listen((pending) {
      if (!mounted) {
        return;
      }
      setState(() => _pendingRequests = pending);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _discoverDevices();
    });
  }

  @override
  void dispose() {
    _requestSub?.cancel();
    _pendingSub?.cancel();
    _deviceNameController.dispose();
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

  Future<void> _connect(_DiscoveredDevice device) async {
    setState(() => _isConnecting = true);
    final success = await widget.wsService.connect(
      device.host,
      serverPort: device.serverPort,
      clientPort: 8766,
      deviceName: _deviceNameController.text.trim(),
    );
    if (mounted) {
      setState(() => _isConnecting = false);
    }

    _showMessage(
      success
          ? 'Request sent. Waiting for server acceptance.'
          : 'Failed to connect. Check server address and port.',
      isError: !success,
    );
  }

  void _sendRequestAgain() {
    widget.wsService.sendConnectionRequest(
      clientPort: 8766,
      deviceName: _deviceNameController.text.trim(),
    );
    _showMessage('Connection request sent');
  }

  Future<void> _pairWithDiscoveredDevice(_DiscoveredDevice device) async {
    await _connect(device);
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
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
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
      socket.send(payload, InternetAddress('255.255.255.255'), 8766);

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

      if (_isOwnServer(deviceId: deviceId, host: host, serverPort: serverPort)) {
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

  void _disconnect() {
    widget.wsService.disconnect();
    _showMessage('Disconnected');
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
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
    return StreamBuilder<bool>(
      stream: widget.wsService.connectionStream,
      initialData: false,
      builder: (context, snapshot) {
        final isConnected = snapshot.data ?? false;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  Icon(
                    isConnected ? Icons.router : Icons.router_outlined,
                    size: 56,
                    color: isConnected ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    isConnected ? 'Socket Connected' : 'Not Connected',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: isConnected ? Colors.green : Colors.grey,
                          fontSize: 20,
                        ),
                  ),
                  const SizedBox(height: 10),
                  Card(
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Scan And Pair',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 10),
                          Card(
                            color: Colors.orange.withValues(alpha: 0.08),
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.pending_actions,
                                        size: 18,
                                        color: Colors.orange,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Incoming Pair Requests (${_pendingRequests.length})',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (_pendingRequests.isEmpty)
                                    Text(
                                      'No incoming requests yet',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    )
                                  else
                                    ..._pendingRequests.map(
                                      (request) => Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 8),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.person_add_alt_1,
                                              size: 18,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    request.deviceName,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      fontSize: 13,
                                                    ),
                                                  ),
                                                  Text(
                                                    request.deviceType,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall,
                                                  ),
                                                ],
                                              ),
                                            ),
                                            FilledButton(
                                              onPressed: () => widget
                                                  .serverService
                                                  .acceptRequest(
                                                      request.clientId),
                                              style:
                                                  FilledButton.styleFrom(
                                                visualDensity:
                                                    VisualDensity.compact,
                                                padding: const EdgeInsets
                                                    .symmetric(
                                                    horizontal: 10),
                                              ),
                                              child: const Text(
                                                'Accept',
                                                style:
                                                    TextStyle(fontSize: 12),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            OutlinedButton(
                                              onPressed: () => widget
                                                  .serverService
                                                  .rejectRequest(
                                                      request.clientId),
                                              style:
                                                  OutlinedButton.styleFrom(
                                                visualDensity:
                                                    VisualDensity.compact,
                                                padding: const EdgeInsets
                                                    .symmetric(
                                                    horizontal: 10),
                                              ),
                                              child: const Text(
                                                'Reject',
                                                style:
                                                    TextStyle(fontSize: 12),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Row(
                                children: [
                                  const Icon(Icons.mark_email_unread_outlined),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Request Status: ${_formatRequestStatus(_requestStatus)}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: isConnected || _isDiscovering
                                ? null
                                : _discoverDevices,
                            icon: _isDiscovering
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.wifi_find),
                            label: Text(
                              _isDiscovering
                                  ? 'Scanning LAN...'
                                  : 'Scan Available Devices',
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (_discoveredDevices.isNotEmpty) ...[
                            Text(
                              'Available Devices',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            ..._discoveredDevices.values.map(
                              (device) => Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: const Icon(Icons.devices),
                                  title: Text(device.name),
                                  subtitle: Text(
                                    '${device.host}:${device.serverPort}',
                                  ),
                                  trailing: FilledButton(
                                    onPressed: isConnected || _isConnecting
                                        ? null
                                        : () =>
                                            _pairWithDiscoveredDevice(device),
                                    child: const Text('Send Request'),
                                  ),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          if (isConnected)
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.icon(
                                    onPressed: _sendRequestAgain,
                                    icon: const Icon(Icons.send),
                                    label: const Text('Send Request'),
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: FilledButton.icon(
                                    onPressed: _disconnect,
                                    icon: const Icon(Icons.close),
                                    label: const Text('Disconnect'),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.red,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          else if (_isConnecting)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Center(
                                child: CircularProgressIndicator(),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

String _formatRequestStatus(String status) {
  switch (status) {
    case 'sending':
      return 'Sending...';
    case 'pending':
      return 'Pending server approval';
    case 'accepted':
      return 'Accepted';
    case 'rejected':
      return 'Rejected';
    case 'disconnected':
      return 'Disconnected';
    default:
      return 'Not sent';
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
