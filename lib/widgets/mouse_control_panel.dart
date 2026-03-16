import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/websocket_service.dart';

class MouseControlPanel extends StatefulWidget {
  final WebSocketService wsService;

  const MouseControlPanel({super.key, required this.wsService});

  @override
  State<MouseControlPanel> createState() => _MouseControlPanelState();
}

class _MouseControlPanelState extends State<MouseControlPanel> {
  Offset? _lastPanPosition;
  double _sensitivity = 1.5;

  void _sendCommand(Map<String, dynamic> command) {
    widget.wsService.sendCommand(command);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 700;
        final horizontalPadding = isNarrow ? 16.0 : 24.0;
        final trackpadHeight =
            (constraints.maxHeight * 0.48).clamp(260.0, 520.0);

        return SingleChildScrollView(
          padding: EdgeInsets.all(horizontalPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Trackpad Mouse Control',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sensitivity: ${_sensitivity.toStringAsFixed(1)}x',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Slider(
                        value: _sensitivity,
                        min: 0.5,
                        max: 5.0,
                        divisions: 18,
                        label: _sensitivity.toStringAsFixed(1),
                        onChanged: (value) {
                          setState(() => _sensitivity = value);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 4,
                child: Container(
                  height: trackpadHeight,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                        Theme.of(context).colorScheme.surface,
                      ],
                    ),
                  ),
                  child: GestureDetector(
                    onPanStart: (details) =>
                        _lastPanPosition = details.localPosition,
                    onPanUpdate: (details) {
                      if (_lastPanPosition == null) {
                        return;
                      }
                      final dx =
                          (details.localPosition.dx - _lastPanPosition!.dx) *
                              _sensitivity;
                      final dy =
                          (details.localPosition.dy - _lastPanPosition!.dy) *
                              _sensitivity;
                      _sendCommand(
                          {'type': 'move', 'dx': dx.round(), 'dy': dy.round()});
                      _lastPanPosition = details.localPosition;
                    },
                    onPanEnd: (_) => _lastPanPosition = null,
                    child: Listener(
                      onPointerSignal: (pointerSignal) {
                        if (pointerSignal is PointerScrollEvent) {
                          _sendCommand({
                            'type': 'wheel',
                            'delta': pointerSignal.scrollDelta.dy.round(),
                          });
                        }
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outline,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.touch_app,
                                size: isNarrow ? 48 : 64,
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Drag to move mouse',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Double tap: left click',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: isNarrow
                        ? double.infinity
                        : (constraints.maxWidth -
                                (horizontalPadding * 2) -
                                16) /
                            3,
                    child: FilledButton.icon(
                      onPressed: () =>
                          _sendCommand({'type': 'click', 'button': 'left'}),
                      icon: const Icon(Icons.mouse),
                      label: const Text('Left Click'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: isNarrow
                        ? double.infinity
                        : (constraints.maxWidth -
                                (horizontalPadding * 2) -
                                16) /
                            3,
                    child: FilledButton.icon(
                      onPressed: () =>
                          _sendCommand({'type': 'click', 'button': 'right'}),
                      icon: const Icon(Icons.mouse_outlined),
                      label: const Text('Right Click'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        backgroundColor: Colors.orange,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: isNarrow
                        ? double.infinity
                        : (constraints.maxWidth -
                                (horizontalPadding * 2) -
                                16) /
                            3,
                    child: FilledButton.icon(
                      onPressed: () => _sendCommand({
                        'type': 'click',
                        'button': 'left',
                        'kind': 'double',
                      }),
                      icon: const Icon(Icons.double_arrow),
                      label: const Text('Double'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        backgroundColor: Colors.purple,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
