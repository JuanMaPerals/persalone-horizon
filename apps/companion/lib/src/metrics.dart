/// One measured interval series on the Companion's monotonic clock.
///
/// Percentiles appear only with enough samples (p50: 5+, p95: 20+, same rule
/// as the Engineering Console); otherwise they are reported as null with the
/// sample count, never as an invented number.
final class MetricSeries {
  MetricSeries(this.name, {required this.stage, required this.method});

  static const int minP50 = 5;
  static const int minP95 = 20;

  final String name;
  final String stage;
  final String method;
  final List<double> _ms = <double>[];

  void add(Duration d) => _ms.add(d.inMicroseconds / 1000);

  int get samples => _ms.length;

  static double? percentile(List<double> values, int p, int minimum) {
    if (values.length < minimum) return null;
    final List<double> sorted = <double>[...values]..sort();
    final int rank = ((p / 100) * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'unit': 'ms',
        'stage': stage,
        'method': method,
        'clockDomain': 'companion-monotonic',
        'samples': _ms.length,
        'latest': _ms.isEmpty ? null : _round(_ms.last),
        'p50': _round(percentile(_ms, 50, minP50)),
        'p95': _round(percentile(_ms, 95, minP95)),
        'availability': _ms.isEmpty ? 'NOT_AVAILABLE' : 'MEASURED',
      };

  static double? _round(double? v) =>
      v == null ? null : (v * 1000).roundToDouble() / 1000;
}
