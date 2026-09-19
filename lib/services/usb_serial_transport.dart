import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import '../models/serial_transport_type.dart';
import 'serial_transport.dart';

class UsbSerialTransport implements SerialTransport {
  static const MethodChannel _methodChannel =
      MethodChannel('com.mcu.serialconnect/usb_serial');
  static const EventChannel _eventChannel =
      EventChannel('com.mcu.serialconnect/usb_serial_events');

  final StreamController<String> _dataController =
      StreamController<String>.broadcast();
  final StreamController<Uint8List> _rawDataController =
      StreamController<Uint8List>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  StreamSubscription? _eventSubscription;

  bool _isConnected = false;
  int _currentBaudRate = 115200;
  String _driverName = '';

  UsbSerialTransport() {
    _initEventChannel();
  }

  void _initEventChannel() {
    if (!Platform.isAndroid) return;

    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          final type = event['event'] as String?;
          switch (type) {
            case 'connected':
              _isConnected = true;
              _driverName = (event['driver'] as String?) ?? 'UsbSerialDevice';
              _connectionController.add(true);
              _logController.add('SYS: USB Connected ($_driverName @ $_currentBaudRate baud)');
              break;
            case 'disconnected':
              _isConnected = false;
              _driverName = '';
              _connectionController.add(false);
              _logController.add('SYS: USB Disconnected');
              break;
            case 'data':
              final data = event['data'] as String? ?? '';
              _dataController.add(data);
              _logController.add('RX: $data');
              break;
            case 'rawData':
              final raw = event['bytes'];
              if (raw is Uint8List) {
                _rawDataController.add(raw);
              } else if (raw is List) {
                _rawDataController.add(Uint8List.fromList(raw.cast<int>()));
              }
              break;
            case 'error':
              final error = event['error'] as String? ?? 'USB Serial Error';
              _errorController.add(error);
              _logController.add('ERR: $error');
              break;
            case 'log':
              final msg = event['message'] as String? ?? '';
              _logController.add(msg);
              break;
          }
        }
      },
      onError: (dynamic error) {
        final errStr = error.toString();
        _errorController.add(errStr);
        _logController.add('ERR: $errStr');
      },
    );
  }

  @override
  SerialTransportType get type => SerialTransportType.usbOtg;

  @override
  bool get isConnected => _isConnected;

  @override
  int get currentBaudRate => _currentBaudRate;

  @override
  String get driverName => _driverName.isEmpty ? 'USB OTG' : _driverName;

  @override
  Stream<String> get onData => _dataController.stream;

  @override
  Stream<Uint8List> get onRawData => _rawDataController.stream;

  @override
  Stream<bool> get onConnectionChanged => _connectionController.stream;

  @override
  Stream<String> get onError => _errorController.stream;

  @override
  Stream<String> get onLog => _logController.stream;

  @override
  Future<bool> connect({int baudRate = 115200, Map<String, dynamic>? config}) async {
    _currentBaudRate = baudRate;
    if (!Platform.isAndroid) {
      final msg = 'Direct USB OTG is only supported on Android. On iOS/Desktop, use BLE UART or WiFi/TCP.';
      _errorController.add(msg);
      _logController.add('ERR: $msg');
      return false;
    }

    try {
      final result = await _methodChannel.invokeMethod<bool>('connect', {
        'baudRate': baudRate,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _errorController.add(e.message ?? 'Failed to connect USB');
      _logController.add('ERR: ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> disconnect() async {
    if (!Platform.isAndroid) {
      _isConnected = false;
      _connectionController.add(false);
      return true;
    }

    try {
      final result = await _methodChannel.invokeMethod<bool>('disconnect');
      _isConnected = false;
      _driverName = '';
      _connectionController.add(false);
      return result ?? true;
    } on PlatformException catch (e) {
      _errorController.add(e.message ?? 'Failed to disconnect USB');
      return false;
    }
  }

  @override
  Future<bool> send(String data) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _methodChannel.invokeMethod<bool>('send', {
        'data': data,
      });
      _logController.add('TX: $data');
      return result ?? false;
    } on PlatformException catch (e) {
      _errorController.add(e.message ?? 'Failed to send data');
      return false;
    }
  }

  @override
  Future<bool> sendRaw(Uint8List bytes) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _methodChannel.invokeMethod<bool>('sendRaw', {
        'bytes': bytes,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _errorController.add(e.message ?? 'Failed to send raw data');
      return false;
    }
  }

  @override
  Future<bool> setBaudRate(int baudRate) async {
    _currentBaudRate = baudRate;
    if (!Platform.isAndroid) return true;
    try {
      final result = await _methodChannel.invokeMethod<bool>('setBaudRate', {
        'baudRate': baudRate,
      });
      _logController.add('SYS: Baud rate set to $baudRate');
      return result ?? false;
    } on PlatformException catch (e) {
      _errorController.add(e.message ?? 'Failed to set baud rate');
      return false;
    }
  }

  @override
  Future<bool> setDtr(bool high) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _methodChannel.invokeMethod<bool>('setDtr', {
        'high': high,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> setRts(bool high) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _methodChannel.invokeMethod<bool>('setRts', {
        'high': high,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> listDevices() async {
    if (!Platform.isAndroid) return [];
    try {
      final list = await _methodChannel.invokeListMethod<dynamic>('listDevices');
      if (list == null) return [];
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _dataController.close();
    _rawDataController.close();
    _connectionController.close();
    _errorController.close();
    _logController.close();
  }
}
