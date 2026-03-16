import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

class HostControllerService {
  static const int _inputMouse = 0;
  static const int _inputKeyboard = 1;

  static const int _mouseMove = 0x0001;
  static const int _mouseLeftDown = 0x0002;
  static const int _mouseLeftUp = 0x0004;
  static const int _mouseRightDown = 0x0008;
  static const int _mouseRightUp = 0x0010;
  static const int _mouseWheel = 0x0800;

  static const int _keyUp = 0x0002;
  static const int _keyUnicode = 0x0004;

  static const int _vkShift = 0x10;
  static const int _vkControl = 0x11;
  static const int _vkAlt = 0x12;
  static const int _vkTab = 0x09;
  static const int _vkEnter = 0x0D;
  static const int _vkSpace = 0x20;
  static const int _vkLeft = 0x25;
  static const int _vkRight = 0x27;
  static const int _vkHome = 0x24;
  static const int _vkT = 0x54;
  static const int _vkW = 0x57;
  static const int _vkF4 = 0x73;
  static const int _vkF5 = 0x74;
  static const int _vkF11 = 0x7A;
  static const int _vkMediaNext = 0xB0;
  static const int _vkMediaPrevious = 0xB1;
  static const int _vkMediaPlayPause = 0xB3;
  static const int _vkVolumeMute = 0xAD;
  static const int _vkVolumeDown = 0xAE;
  static const int _vkVolumeUp = 0xAF;

  static const int _swMaximize = 3;
  static const int _swMinimize = 6;

  Future<String> readClipboardText() async {
    final data = await Clipboard.getData('text/plain');
    return data?.text ?? '';
  }

  Future<void> writeClipboardText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  bool handleCommand(Map<String, dynamic> message) {
    final type = message['type']?.toString() ?? '';

    if (type == 'send_text') {
      return _sendText(message['text']?.toString() ?? '');
    }

    if (!Platform.isWindows) {
      return false;
    }

    switch (type) {
      case 'mouse':
        return _handleMouse(message);
      case 'browser_back':
        _sendKeyCombo(const <int>[_vkAlt], _vkLeft);
        return true;
      case 'browser_forward':
        _sendKeyCombo(const <int>[_vkAlt], _vkRight);
        return true;
      case 'browser_refresh':
        _sendKeyPress(_vkF5);
        return true;
      case 'browser_home':
        _sendKeyCombo(const <int>[_vkAlt], _vkHome);
        return true;
      case 'previous_tab':
        _sendKeyCombo(const <int>[_vkControl, _vkShift], _vkTab);
        return true;
      case 'next_tab':
        _sendKeyCombo(const <int>[_vkControl], _vkTab);
        return true;
      case 'new_tab':
        _sendKeyCombo(const <int>[_vkControl], _vkT);
        return true;
      case 'close_tab':
        _sendKeyCombo(const <int>[_vkControl], _vkW);
        return true;
      case 'media_previous':
        _sendKeyPress(_vkMediaPrevious);
        return true;
      case 'media_play_pause':
        _sendKeyPress(_vkMediaPlayPause);
        return true;
      case 'media_next':
        _sendKeyPress(_vkMediaNext);
        return true;
      case 'seek_backward':
        _sendKeyPress(_vkLeft);
        return true;
      case 'seek_forward':
        _sendKeyPress(_vkRight);
        return true;
      case 'space':
        _sendKeyPress(_vkSpace);
        return true;
      case 'volume_down':
        _sendKeyPress(_vkVolumeDown);
        return true;
      case 'volume_mute':
        _sendKeyPress(_vkVolumeMute);
        return true;
      case 'volume_up':
        _sendKeyPress(_vkVolumeUp);
        return true;
      case 'alt_tab':
        _sendKeyCombo(const <int>[_vkAlt], _vkTab);
        return true;
      case 'minimize_window':
        return _showForegroundWindow(_swMinimize);
      case 'maximize_window':
        return _showForegroundWindow(_swMaximize);
      case 'toggle_fullscreen':
        _sendKeyPress(_vkF11);
        return true;
      case 'close_window':
        _sendKeyCombo(const <int>[_vkAlt], _vkF4);
        return true;
      case 'key_press':
        final vk = _toInt(message['vk']);
        if (vk > 0) _sendKeyPress(vk);
        return true;
      case 'key_combo':
        final rawMods = message['modifiers'];
        final mods =
            rawMods is List ? rawMods.map<int>(_toInt).toList() : <int>[];
        final vkCombo = _toInt(message['vk']);
        if (vkCombo > 0) _sendKeyCombo(mods, vkCombo);
        return true;
      default:
        return false;
    }
  }

  bool _handleMouse(Map<String, dynamic> message) {
    final action = message['action']?.toString() ?? '';

    switch (action) {
      case 'move':
        _moveMouse(
          _toDouble(message['deltaX']),
          _toDouble(message['deltaY']),
        );
        return true;
      case 'click':
        _clickMouse(
          message['button']?.toString() ?? 'left',
          kind: message['kind']?.toString(),
        );
        return true;
      case 'wheel':
        _scrollMouse(_toInt(message['delta']));
        return true;
      default:
        return false;
    }
  }

  bool _sendText(String text) {
    if (text.isEmpty) {
      return false;
    }

    if (!Platform.isWindows) {
      return false;
    }

    final codeUnits = text.replaceAll('\r\n', '\n').codeUnits;
    final inputs = calloc<INPUT>(codeUnits.length * 2);

    try {
      var index = 0;
      for (final codeUnit in codeUnits) {
        if (codeUnit == 10) {
          _fillKeyInput(inputs[index++], _vkEnter);
          _fillKeyInput(inputs[index++], _vkEnter, keyUp: true);
          continue;
        }

        _fillUnicodeInput(inputs[index++], codeUnit);
        _fillUnicodeInput(inputs[index++], codeUnit, keyUp: true);
      }

      SendInput(index, inputs, sizeOf<INPUT>());
      return true;
    } finally {
      calloc.free(inputs);
    }
  }

  bool _showForegroundWindow(int showCommand) {
    final handle = GetForegroundWindow();
    if (handle == 0) {
      return false;
    }

    ShowWindow(handle, showCommand);
    return true;
  }

  void _moveMouse(double deltaX, double deltaY) {
    final inputs = calloc<INPUT>(1);

    try {
      inputs[0].type = _inputMouse;
      inputs[0].mi.dx = (deltaX * 2).round();
      inputs[0].mi.dy = (deltaY * 2).round();
      inputs[0].mi.dwFlags = _mouseMove;
      SendInput(1, inputs, sizeOf<INPUT>());
    } finally {
      calloc.free(inputs);
    }
  }

  void _clickMouse(String button, {String? kind}) {
    final clickCount = kind == 'double' ? 2 : 1;
    final isRight = button == 'right';
    final downFlag = isRight ? _mouseRightDown : _mouseLeftDown;
    final upFlag = isRight ? _mouseRightUp : _mouseLeftUp;

    final inputs = calloc<INPUT>(clickCount * 2);

    try {
      var index = 0;
      for (var i = 0; i < clickCount; i++) {
        inputs[index].type = _inputMouse;
        inputs[index].mi.dwFlags = downFlag;
        index++;

        inputs[index].type = _inputMouse;
        inputs[index].mi.dwFlags = upFlag;
        index++;
      }

      SendInput(index, inputs, sizeOf<INPUT>());
    } finally {
      calloc.free(inputs);
    }
  }

  void _scrollMouse(int rawDelta) {
    if (rawDelta == 0) {
      return;
    }

    final inputs = calloc<INPUT>(1);

    try {
      inputs[0].type = _inputMouse;
      inputs[0].mi.dwFlags = _mouseWheel;
      inputs[0].mi.mouseData = rawDelta > 0 ? 120 : -120;
      SendInput(1, inputs, sizeOf<INPUT>());
    } finally {
      calloc.free(inputs);
    }
  }

  void _sendKeyPress(int key) {
    _sendKeyCombo(const <int>[], key);
  }

  void _sendKeyCombo(List<int> modifiers, int key) {
    final inputs = calloc<INPUT>((modifiers.length * 2) + 2);

    try {
      var index = 0;
      for (final modifier in modifiers) {
        _fillKeyInput(inputs[index++], modifier);
      }

      _fillKeyInput(inputs[index++], key);
      _fillKeyInput(inputs[index++], key, keyUp: true);

      for (final modifier in modifiers.reversed) {
        _fillKeyInput(inputs[index++], modifier, keyUp: true);
      }

      SendInput(index, inputs, sizeOf<INPUT>());
    } finally {
      calloc.free(inputs);
    }
  }

  void _fillKeyInput(INPUT input, int key, {bool keyUp = false}) {
    input.type = _inputKeyboard;
    input.ki.wVk = key;
    input.ki.dwFlags = keyUp ? _keyUp : 0;
  }

  void _fillUnicodeInput(INPUT input, int codeUnit, {bool keyUp = false}) {
    input.type = _inputKeyboard;
    input.ki.wVk = 0;
    input.ki.wScan = codeUnit;
    input.ki.dwFlags = keyUp ? _keyUnicode | _keyUp : _keyUnicode;
  }

  double _toDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  int _toInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
