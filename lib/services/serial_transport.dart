import 'dart:async';
import 'dart:typed_data';
import '../models/serial_transport_type.dart';

abstract class SerialTransport {
  SerialTransportType get type;
  bool get isConnected;
  int get currentBaudRate;
  String get driverName;

  Stream<String> get onData;
  Stream<Uint8List> get onRawData;
  Stream<bool> get onConnectionChanged;
  Stream<String> get onError;
  Stream<String> get onLog;

  Future<bool> connect({int baudRate = 115200, Map<String, dynamic>? config});
  Future<bool> disconnect();
  Future<bool> send(String data);
  Future<bool> sendRaw(Uint8List bytes);
  Future<bool> setBaudRate(int baudRate);
  Future<bool> setDtr(bool high);
  Future<bool> setRts(bool high);

  void dispose();
}
