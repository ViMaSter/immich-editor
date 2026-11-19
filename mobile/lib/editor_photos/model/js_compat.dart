// Helpers that reproduce JavaScript number semantics, so recipes normalised here are
// byte-identical to the ones the web editor (recipe.js) produces.

/// Marker for "key not present" (JavaScript `undefined`), as opposed to an explicit null.
const Object undefined = _Undefined();

class _Undefined {
  const _Undefined();
}

/// `obj?.[key]`: undefined when [obj] is not a map or has no such key.
Object? prop(Object? obj, String key) {
  if (obj is Map && obj.containsKey(key)) {
    return obj[key];
  }
  return undefined;
}

/// `value?.[index]`: arrays by position, objects by the index's string key ({"0": …}),
/// strings by UTF-16 code unit ("57"[0] is "5")
Object? item(Object? obj, int index) {
  if (obj is List && index >= 0 && index < obj.length) {
    return obj[index];
  }
  if (obj is Map) {
    return prop(obj, '$index');
  }
  if (obj is String && index >= 0 && index < obj.length) {
    return obj[index];
  }
  return undefined;
}

bool isObject(Object? value) => value is Map || value is List;

/// `Number(value)` (NaN for anything that does not convert)
double jsNumber(Object? value) {
  if (identical(value, undefined)) {
    return double.nan;
  }
  if (value == null) {
    return 0;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is bool) {
    return value ? 1 : 0;
  }
  if (value is String) {
    return _stringToNumber(value);
  }
  if (value is List) {
    if (value.isEmpty) {
      return 0;
    }
    if (value.length == 1) {
      final only = value.first;
      return jsNumber(only is List ? only : (only == null ? '' : only.toString()));
    }
    return double.nan;
  }
  return double.nan;
}

// StringToNumber: JS whitespace (not Dart's trim, which also strips U+0085), unsigned
// 0x/0o/0b literals of any length, and the StrDecimalLiteral grammar (no "NaN", no "_").
final _radixLiteral = RegExp(r'^0([xXoObB])([0-9a-zA-Z]+)$');
final _decimalLiteral = RegExp(r'^[+-]?(Infinity|(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)$');
const _radixDigits = {'x': r'^[0-9a-fA-F]+$', 'o': r'^[0-7]+$', 'b': r'^[01]+$'};

bool _isJsSpace(int c) =>
    c == 0x20 ||
    (c >= 0x09 && c <= 0x0D) ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000 ||
    c == 0xFEFF;

double _stringToNumber(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && _isJsSpace(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isJsSpace(value.codeUnitAt(end - 1))) {
    end--;
  }
  final s = value.substring(start, end);
  if (s.isEmpty) {
    return 0;
  }
  final radix = _radixLiteral.firstMatch(s);
  if (radix != null) {
    final kind = radix.group(1)!.toLowerCase();
    final digits = radix.group(2)!;
    if (!RegExp(_radixDigits[kind]!).hasMatch(digits)) {
      return double.nan;
    }
    return BigInt.parse(digits, radix: kind == 'x' ? 16 : (kind == 'o' ? 8 : 2)).toDouble();
  }
  if (!_decimalLiteral.hasMatch(s)) {
    return double.nan;
  }
  if (s.endsWith('Infinity')) {
    return s.startsWith('-') ? double.negativeInfinity : double.infinity;
  }
  return double.parse(s);
}

/// `Number.isFinite(Number(value)) ? Number(value) : fallback`
double numOr(Object? value, [double fallback = 0]) {
  final n = jsNumber(value);
  return n.isFinite ? n : fallback;
}

/// `value ?? fallback` (null and undefined both fall back)
Object? coalesce(Object? value, Object? fallback) => (value == null || identical(value, undefined)) ? fallback : value;

/// `Math.round`: halves round towards +infinity
double jsRound(double value) {
  if (!value.isFinite) {
    return value;
  }
  final floor = value.floorToDouble();
  return value - floor >= 0.5 ? floor + 1 : floor;
}

/// `Math.round(value * 10 ** digits) / 10 ** digits`
double roundTo(double value, int digits) {
  final factor = _pow10[digits];
  return jsRound(value * factor) / factor;
}

const _pow10 = <double>[1, 10, 100, 1000, 10000, 100000, 1000000];

double clampD(double value, double min, double max) => value < min ? min : (value > max ? max : value);

/// A number as JSON.stringify would print it: integral values without a fraction, -0 as 0
num jsonNum(double value) {
  if (value.isFinite && value == value.truncateToDouble() && value.abs() < 9007199254740992) {
    return value.toInt();
  }
  return value;
}

/// Converts a decoded JSON number (int or double) to double
double toD(Object? value, [double fallback = 0]) => value is num ? value.toDouble() : fallback;
