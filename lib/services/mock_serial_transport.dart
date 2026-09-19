import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import '../models/serial_transport_type.dart';
import 'serial_transport.dart';

class MockSerialTransport implements SerialTransport {
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

  bool _isConnected = false;
  int _currentBaudRate = 115200;
  Timer? _telemetryTimer;
  final Random _random = Random();

  @override
  SerialTransportType get type => SerialTransportType.simulator;

  @override
  bool get isConnected => _isConnected;

  @override
  int get currentBaudRate => _currentBaudRate;

  @override
  String get driverName => 'Virtual MCU Simulator (ESP32-S3)';

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
    _isConnected = true;
    _connectionController.add(true);
    _logController.add('SYS: Connected to $driverName @ $baudRate baud');

    // Send boot banner
    Future.delayed(const Duration(milliseconds: 300), () {
      _emitResponse('--- ESP32-S3 Microcontroller Ready (Firmware v1.0.4) ---');
      _emitResponse('Type "HELP", "STATUS", "PING", or "AT" for commands');
    });

    // Start occasional periodic telemetry
    _telemetryTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (!_isConnected) return;
      final temp = (22.0 + _random.nextDouble() * 5.0).toStringAsFixed(1);
      final hum = (45.0 + _random.nextDouble() * 15.0).toStringAsFixed(1);
      final lat = (37.7749 + (_random.nextDouble() - 0.5) * 0.001).toStringAsFixed(5);
      final lon = (-122.4194 + (_random.nextDouble() - 0.5) * 0.001).toStringAsFixed(5);

      final telemetryChoice = _random.nextInt(3);
      if (telemetryChoice == 0) {
        _emitResponse('\$GPGGA,123519,$lat,N,$lon,W,1,08,0.9,545.4,M,46.9,M,,*47');
      } else if (telemetryChoice == 1) {
        _emitResponse('SENSOR: temp=${temp}C, hum=$hum%');
      } else {
        _emitResponse('SYS: Heap free: 198420 bytes, CPU load: 12%');
      }
    });

    return true;
  }

  void _emitResponse(String line) {
    if (!_isConnected) return;
    final bytes = Uint8List.fromList(utf8.encode('$line\n'));
    _rawDataController.add(bytes);
    _dataController.add(line);
    _logController.add('RX: $line');
  }

  @override
  Future<bool> disconnect() async {
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    _isConnected = false;
    _connectionController.add(false);
    _logController.add('SYS: Simulator Disconnected');
    return true;
  }

  @override
  Future<bool> send(String data) async {
    return sendRaw(Uint8List.fromList(utf8.encode(data)));
  }

  @override
  Future<bool> sendRaw(Uint8List bytes) async {
    if (!_isConnected) {
      _errorController.add('Simulator is not connected');
      return false;
    }

    final text = utf8.decode(bytes, allowMalformed: true).trim();
    _logController.add('TX: $text');

    // Simulate processing delay
    Future.delayed(const Duration(milliseconds: 120), () {
      _handleCommand(text);
    });

    return true;
  }

  void _handleCommand(String cmd) {
    final upper = cmd.toUpperCase();
    if (upper == 'AT') {
      _emitResponse('OK');
    } else if (upper == 'PING') {
      _emitResponse('PONG');
    } else if (upper.startsWith('ECHO_') || upper.startsWith('ECHO')) {
      _emitResponse('ACK: $cmd');
    } else if (upper == 'STATUS') {
      _emitResponse('{"device":"ESP32-S3","state":"ACTIVE","uptime":84210,"battery":98}');
    } else if (upper == 'HELLO') {
      _emitResponse('Hello from MCU! Hardware ID: DDE000VW0003');
    } else if (upper == 'LED ON' || upper == '1') {
      _emitResponse('LED: HIGH (ON)');
    } else if (upper == 'LED OFF' || upper == '0') {
      _emitResponse('LED: LOW (OFF)');
    } else if (upper == 'HELP') {
      _emitResponse('Available commands: AT, PING, STATUS, HELLO, LED ON, LED OFF, ECHO <text>');
    } else {
      _emitResponse('OK: $cmd');
    }
  }

  @override
  Future<bool> setBaudRate(int baudRate) async {
    _currentBaudRate = baudRate;
    _logController.add('SYS: Simulator Baud rate set to $baudRate');
    return true;
  }

  @override
  Future<bool> setDtr(bool high) async => true;

  @override
  Future<bool> setRts(bool high) async => true;

  @override
  void dispose() {
    disconnect();
    _dataController.close();
    _rawDataController.close();
    _connectionController.close();
    _errorController.close();
    _logController.close();
  }
}
