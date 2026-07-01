class EscapeEmitter {
  const EscapeEmitter();

  String primaryDeviceAttributes() {
    return '\x1b[?1;2c';
  }

  String secondaryDeviceAttributes() {
    const model = 0;
    const version = 0;
    return '\x1b[>$model;$version;0c';
  }

  String tertiaryDeviceAttributes() {
    return '\x1bP!|00000000\x1b\\';
  }

  String operatingStatus() {
    return '\x1b[0n';
  }

  String cursorPosition(int x, int y) {
    return '\x1b[$y;${x}R';
  }

  String bracketedPaste(String text) {
    return '\x1b[200~$text\x1b[201~';
  }

  String size(int rows, int cols) {
    return '\x1b[8;$rows;${cols}t';
  }

  String defaultColor(int osc, int rgb) {
    String component(int shift) {
      final byte = (rgb >> shift) & 0xff;
      final hex = byte.toRadixString(16).padLeft(2, '0');
      return '$hex$hex';
    }

    return '\x1b]$osc;rgb:${component(16)}/${component(8)}/${component(0)}\x1b\\';
  }
}
