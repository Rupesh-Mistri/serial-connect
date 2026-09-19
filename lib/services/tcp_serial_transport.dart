import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../models/serial_transport_type.dart';
import 'serial_transport.dart';

class TcpSerialTransport implements SerialTransport {
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

  Socket? _socket;
  StreamSubscription? _socketSub;

  bool _isConnected = false;
  int _currentBaudRate = 115200;
  String _host = '192.168.4.1';
  int _port = 8080;
  static const String _driverName = 'TCP Socket';

  final StringBuffer _lineBuffer = StringBuffer();
  Timer? _flushTimer;

  @override
  SerialTransportType get type => SerialTransportType.tcp;

  @override
  bool get isConnected => _isConnected;

  @override
  int get currentBaudRate => _currentBaudRate;

  @override
  String get driverName => '$_driverName ($_host:$_port)';

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
    _host = config?['host'] as String? ?? _host;
    _port = config?['port'] as int? ?? _port;

    try {
      _logController.add('SYS: Connecting to TCP Serial bridge at $_host:$_port...');
      final socket = await Socket.connect(_host, _port, timeout: const Duration(seconds: 5));
      _socket = socket;
      _isConnected = true;
      _connectionController.add(true);
      _logController.add('SYS: TCP Serial Connected to $_host:$_port');

      _socketSub = socket.listen(
        _processIncomingBytes,
        onError: (e) {
          _errorController.add('TCP Socket error: $e');
          _logController.add('ERR: TCP Socket error: $e');
          disconnect();
        },
        onDone: () {
          disconnect();
        },
      );
      return true;
    } catch (e) {
      _errorController.add('Failed to connect to $_host:$_port ($e)');
      _logController.add('ERR: TCP Connection failed: $e');
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

  @override
  Future<bool> disconnect() async {
    _flushLineBuffer();
    _socketSub?.cancel();
    _socketSub = null;
    try {
      await _socket?.close();
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
    _isConnected = false;
    _connectionController.add(false);
    _logController.add('SYS: TCP Serial Disconnected');
    return true;
  }

  @override
  Future<bool> send(String data) async {
    return sendRaw(Uint8List.fromList(utf8.encode(data)));
  }

  @override
  Future<bool> sendRaw(Uint8List bytes) async {
    if (!_isConnected || _socket == null) {
      _errorController.add('TCP Serial is not connected');
      return false;
    }
    try {
      _socket!.add(bytes);
      await _socket!.flush();
      return true;
    } catch (e) {
      _errorController.add('TCP send error: $e');
      return false;
    }
  }

  @override
  Future<bool> setBaudRate(int baudRate) async {
    _currentBaudRate = baudRate;
    _logController.add('SYS: TCP Baud rate updated to $baudRate');
    return true;
  }

  @override
  Future<bool> setDtr(bool high) async => true;

  @override
  Future<bool> setRts(bool high) async => true;

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
