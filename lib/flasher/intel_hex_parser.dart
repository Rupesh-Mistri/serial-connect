import 'dart:convert';
import 'dart:typed_data';

class IntelHexParser {
  /// Parses an Intel HEX (.hex) byte array or raw binary (.bin) into contiguous flash binary buffer.
  static Uint8List parseHexOrRaw(Uint8List inputData) {
    if (inputData.isEmpty) {
      return Uint8List(0);
    }

    // Check if data starts with ':' (Intel HEX signature)
    final checkLen = inputData.length < 64 ? inputData.length : 64;
    final sample = latin1.decode(inputData.sublist(0, checkLen)).trim();
    if (!sample.startsWith(':')) {
      // It's already a raw binary (.bin) array
      return inputData;
    }

    final memory = Uint8List(65536); // 64KB max flash size for ATmega328P
    memory.fillRange(0, memory.length, 0xFF);
    int maxAddress = 0;

    try {
      final content = latin1.decode(inputData);
      final lines = const LineSplitter().convert(content);
      int segmentAddress = 0;

      for (var rawLine in lines) {
        final line = rawLine.trim();
        if (!line.startsWith(':') || line.length < 11) {
          continue;
        }

        final byteCount = int.parse(line.substring(1, 3), radix: 16);
        final address = int.parse(line.substring(3, 7), radix: 16);
        final recordType = int.parse(line.substring(7, 9), radix: 16);

        if (recordType == 0) {
          // Data Record
          final absoluteAddress = segmentAddress + address;
          for (int i = 0; i < byteCount; i++) {
            final dataByte = int.parse(line.substring(9 + i * 2, 11 + i * 2), radix: 16);
            if (absoluteAddress + i < memory.length) {
              memory[absoluteAddress + i] = dataByte;
              if (absoluteAddress + i > maxAddress) {
                maxAddress = absoluteAddress + i;
              }
            }
          }
        } else if (recordType == 1) {
          // End of File Record
          break;
        } else if (recordType == 2) {
          // Extended Segment Address Record
          segmentAddress = int.parse(line.substring(9, 13), radix: 16) << 4;
        } else if (recordType == 4) {
          // Extended Linear Address Record
          segmentAddress = int.parse(line.substring(9, 13), radix: 16) << 16;
        }
      }
    } catch (_) {}

    if (maxAddress == 0) {
      return inputData;
    }

    int totalLength = maxAddress + 1;
    // Align to 128-byte page boundary
    if (totalLength % 128 != 0) {
      totalLength = ((totalLength ~/ 128) + 1) * 128;
    }

    return Uint8List.fromList(memory.sublist(0, totalLength));
  }
}
