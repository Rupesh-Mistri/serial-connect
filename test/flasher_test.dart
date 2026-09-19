import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial_connect/flasher/intel_hex_parser.dart';
import 'package:serial_connect/flasher/firmware_generator.dart';
import 'package:serial_connect/models/serial_transport_type.dart';
import 'package:serial_connect/services/mock_serial_transport.dart';
import 'package:serial_connect/services/serial_manager.dart';

void main() {
  group('IntelHexParser Tests', () {
    test('passes raw binary through when not Intel HEX', () {
      final raw = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
      final parsed = IntelHexParser.parseHexOrRaw(raw);
      expect(parsed, equals(raw));
    });

    test('parses Intel HEX data records and aligns to 128 bytes', () {
      // Intel HEX line:
      // :100000000C9434000C9449000C9449000C944900A0
      // byte count 0x10 (16), address 0x0000, type 00 (data)
      const hex = ':100000000C9434000C9449000C9449000C944900A0\n:00000001FF\n';
      final parsed = IntelHexParser.parseHexOrRaw(Uint8List.fromList(ascii.encode(hex)));
      expect(parsed.length, equals(128)); // Aligned to 128-byte page
      expect(parsed[0], equals(0x0C));
      expect(parsed[1], equals(0x94));
      expect(parsed[2], equals(0x34));
      expect(parsed[3], equals(0x00));
    });
  });

  group('FirmwareGenerator Tests', () {
    test('customizes MASTER_ID marker correctly', () {
      final base = Uint8List.fromList(ascii.encode('ABC_DDE000VW0003_XYZ'));
      final patched = FirmwareGenerator.customizeMasterId(base, 'MY_CUSTOM_01');
      final patchedStr = ascii.decode(patched);
      expect(patchedStr, equals('ABC_MY_CUSTOM_01_XYZ'));
    });

    test('pads shorter MASTER_ID with zeroes', () {
      final base = Uint8List.fromList(ascii.encode('ABC_DDE000VW0003_XYZ'));
      final patched = FirmwareGenerator.customizeMasterId(base, 'SHORT_ID');
      expect(patched.sublist(4, 12), equals(ascii.encode('SHORT_ID')));
      expect(patched[12], equals(0)); // Padded null
    });
  });

  group('SerialManager & Mock Transport Tests', () {
    test('MockSerialTransport connects, sends and replies', () async {
      final mock = MockSerialTransport();
      expect(mock.isConnected, isFalse);

      final connected = await mock.connect(baudRate: 115200);
      expect(connected, isTrue);
      expect(mock.isConnected, isTrue);
      expect(mock.currentBaudRate, equals(115200));

      final dataReceived = <String>[];
      final sub = mock.onData.listen(dataReceived.add);

      await mock.send('PING');
      await Future.delayed(const Duration(milliseconds: 250));

      expect(dataReceived.any((d) => d.contains('PONG')), isTrue);

      await sub.cancel();
      await mock.disconnect();
      expect(mock.isConnected, isFalse);
    });

    test('SerialManager switches transport correctly', () async {
      final manager = SerialManager();
      await manager.switchTransport(SerialTransportType.simulator);
      expect(manager.selectedType, equals(SerialTransportType.simulator));

      final ok = await manager.connect(baudRate: 9600);
      expect(ok, isTrue);
      expect(manager.isConnected, isTrue);

      await manager.disconnect();
      expect(manager.isConnected, isFalse);
    });
  });
}
