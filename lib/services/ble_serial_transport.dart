import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/serial_transport_type.dart';
import 'serial_transport.dart';

class BleSerialTransport implements SerialTransport {
  // Nordic UART Service (NUS)
  static final Guid nusServiceUuid = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid nusRxCharUuid = Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E'); // Write
  static final Guid nusTxCharUuid = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E'); // Notify

  // HM-10 / CC2541 Service
  static final Guid hm10ServiceUuid = Guid('0000FFE0-0000-1000-8000-00805F9B34FB');
  static final Guid hm10CharUuid = Guid('0000FFE1-0000-1000-8000-00805F9B34FB');

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

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  StreamSubscription? _notifySub;
  StreamSubscription? _stateSub;

  bool _isConnected = false;
  int _currentBaudRate = 115200;
  String _driverName = 'BLE Serial (NUS)';
  final StringBuffer _lineBuffer = StringBuffer();
  Timer? _flushTimer;

  @override
  SerialTransportType get type => SerialTransportType.ble;

  @override
  bool get isConnected => _isConnected;

  @override
  int get currentBaudRate => _currentBaudRate;

  @override
  String get driverName => _driverName;

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

  /// Scans for BLE UART devices
  static Stream<List<ScanResult>> scanForDevices({Duration timeout = const Duration(seconds: 4)}) {
    FlutterBluePlus.startScan(timeout: timeout);
    return FlutterBluePlus.scanResults;
  }

  static Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  @override
  Future<bool> connect({int baudRate = 115200, Map<String, dynamic>? config}) async {
    _currentBaudRate = baudRate;
    final BluetoothDevice? targetDevice = config?['device'] as BluetoothDevice?;

    if (targetDevice == null) {
      _logController.add('SYS: Scanning for BLE UART / ESP32 devices...');
      try {
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 3),
          withServices: [nusServiceUuid, hm10ServiceUuid],
        );
        final results = await FlutterBluePlus.scanResults.first;
        await FlutterBluePlus.stopScan();

        if (results.isEmpty) {
          _errorController.add('No BLE Serial devices found. Ensure Bluetooth is ON.');
          _logController.add('ERR: No BLE Serial devices found');
          return false;
        }

        return await connectToDevice(results.first.device);
      } catch (e) {
        _errorController.add('BLE scan failed: $e');
        _logController.add('ERR: BLE scan failed: $e');
        return false;
      }
    } else {
      return await connectToDevice(targetDevice);
    }
  }

  Future<bool> connectToDevice(BluetoothDevice device) async {
    try {
      _logController.add('SYS: Connecting to BLE device: ${device.platformName} (${device.remoteId})...');
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 10),
        autoConnect: false,
      );
      _connectedDevice = device;

      _stateSub?.cancel();
      _stateSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnected();
        }
      });

      // Request higher MTU for faster data transfer
      try {
        await device.requestMtu(247);
      } catch (_) {}

      // Discover services
      final services = await device.discoverServices();
      BluetoothCharacteristic? writeCh;
      BluetoothCharacteristic? notifyCh;

      for (final service in services) {
        if (service.uuid == nusServiceUuid) {
          for (final c in service.characteristics) {
            if (c.uuid == nusRxCharUuid) writeCh = c;
            if (c.uuid == nusTxCharUuid) notifyCh = c;
          }
        } else if (service.uuid == hm10ServiceUuid) {
          for (final c in service.characteristics) {
            if (c.uuid == hm10CharUuid) {
              writeCh = c;
              notifyCh = c;
            }
          }
        } else {
          // Fallback discovery: Look for characteristics with notify and write properties
          for (final c in service.characteristics) {
            if (c.properties.notify && notifyCh == null) notifyCh = c;
            if ((c.properties.write || c.properties.writeWithoutResponse) && writeCh == null) {
              writeCh = c;
            }
          }
        }
      }

      if (notifyCh == null && writeCh == null) {
        throw Exception('No UART / Serial characteristics found on BLE device');
      }

      _writeChar = writeCh;
      _notifyChar = notifyCh;

      if (_notifyChar != null) {
        await _notifyChar!.setNotifyValue(true);
        _notifySub?.cancel();
        _notifySub = _notifyChar!.onValueReceived.listen(_processIncomingBytes);
      }

      _isConnected = true;
      final devName = device.platformName.isNotEmpty ? device.platformName : 'BLE UART';
      _driverName = 'BLE ($devName)';
      _connectionController.add(true);
      _logController.add('SYS: BLE Connected ($devName)');
      return true;
    } catch (e) {
      _errorController.add('BLE connection failed: $e');
      _logController.add('ERR: BLE connection failed: $e');
      _handleDisconnected();
      return false;
    }
  }

  void _processIncomingBytes(List<int> bytes) {
    if (bytes.isEmpty) return;
    final uint8 = Uint8List.fromList(bytes);
    _rawDataController.add(uint8);

    final clean = StringBuffer();
    for (final b in bytes) {
      if (b == 10 || b == 13 || b == 9 || (b >= 32 && b <= 126) || b >= 160) {
        clean.writeCharCode(b);
      }
    }

    final cleanStr = clean.toString();
    if (cleanStr.isEmpty) return;

    _lineBuffer.write(cleanStr);
    String current = _lineBuffer.toString();
    int newlineIndex;
    while ((newlineIndex = current.indexOf('\n')) >= 0) {
      String line = current.substring(0, newlineIndex);
      current = current.substring(newlineIndex + 1);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      line = line.trim();
      if (line.isNotEmpty) {
        _dataController.add(line);
        _logController.add('RX: $line');
      }
    }

    _lineBuffer.clear();
    _lineBuffer.write(current);

    _flushTimer?.cancel();
    if (_lineBuffer.isNotEmpty) {
      _flushTimer = Timer(const Duration(milliseconds: 100), _flushLineBuffer);
    }
  }

  void _flushLineBuffer() {
    if (_lineBuffer.isNotEmpty) {
      var remaining = _lineBuffer.toString();
      _lineBuffer.clear();
      if (remaining.endsWith('\r')) {
        remaining = remaining.substring(0, remaining.length - 1);
      }
      remaining = remaining.trim();
      if (remaining.isNotEmpty) {
        _dataController.add(remaining);
        _logController.add('RX: $remaining');
      }
    }
  }

  void _handleDisconnected() {
    _flushLineBuffer();
    _notifySub?.cancel();
    _notifySub = null;
    _stateSub?.cancel();
    _stateSub = null;
    _connectedDevice = null;
    _writeChar = null;
    _notifyChar = null;
    _isConnected = false;
    _connectionController.add(false);
    _logController.add('SYS: BLE Disconnected');
  }

  @override
  Future<bool> disconnect() async {
    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
      } catch (_) {}
    }
    _handleDisconnected();
    return true;
  }

  @override
  Future<bool> send(String data) async {
    return sendRaw(Uint8List.fromList(utf8.encode(data)));
  }

  @override
  Future<bool> sendRaw(Uint8List bytes) async {
    if (!_isConnected || _writeChar == null) {
      _errorController.add('BLE is not connected');
      return false;
    }

    try {
      // Chunk writes according to BLE MTU (usually 20-240 bytes)
      const chunkSize = 240;
      for (int i = 0; i < bytes.length; i += chunkSize) {
        final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
        final chunk = bytes.sublist(i, end);
        await _writeChar!.write(chunk, withoutResponse: _writeChar!.properties.writeWithoutResponse);
      }
      return true;
    } catch (e) {
      _errorController.add('BLE write error: $e');
      _logController.add('ERR: BLE write error: $e');
      return false;
    }
  }

  @override
  Future<bool> setBaudRate(int baudRate) async {
    _currentBaudRate = baudRate;
    _logController.add('SYS: BLE Baud rate configured to $baudRate (Virtual)');
    return true;
  }

  @override
  Future<bool> setDtr(bool high) async {
    // BLE Nordic UART doesn't have physical pin control; virtual acknowledgment
    return true;
  }

  @override
  Future<bool> setRts(bool high) async {
    return true;
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    disconnect();
    _dataController.close();
    _rawDataController.close();
    _connectionController.close();
    _errorController.close();
    _logController.close();
  }
}
