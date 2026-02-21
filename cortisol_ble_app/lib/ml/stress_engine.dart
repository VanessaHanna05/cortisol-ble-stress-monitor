import 'dart:collection';
import 'dart:math';

enum StressLevel { low, medium, high }

class StressInferenceResult {
  final double stressProbability;
  final double cortisolProxy;
  final double confidence;
  final StressLevel level;
  final bool calibrationReady;

  const StressInferenceResult({
    required this.stressProbability,
    required this.cortisolProxy,
    required this.confidence,
    required this.level,
    required this.calibrationReady,
  });

  String get levelText {
    switch (level) {
      case StressLevel.low:
        return 'Low';
      case StressLevel.medium:
        return 'Medium';
      case StressLevel.high:
        return 'High';
    }
  }
}

class StressEngine {
  final int windowSize;
  final int stepSize;
  final int baselineWindows;

  final Queue<_SensorPoint> _points = Queue<_SensorPoint>();
  int _samplesSinceInference = 0;
  int _syntheticTs = 0;

  final _FeatureCalibrator _calibrator;
  double? _smoothedProb;

  StressEngine({
    this.windowSize = 8,
    this.stepSize = 1,
    this.baselineWindows = 8,
  }) : _calibrator = _FeatureCalibrator(maxWindows: baselineWindows);

  void reset() {
    _points.clear();
    _samplesSinceInference = 0;
    _syntheticTs = 0;
    _smoothedProb = null;
    _calibrator.reset();
  }

  bool get calibrationReady => _calibrator.ready;
  int get baselineCollected => _calibrator.collected;
  int get baselineTarget => baselineWindows;
  int get currentWindowSamples => _points.length;
  int get windowTarget => windowSize;

  StressInferenceResult? addSample({
    int? ts,
    double? bpm,
    double? gsr,
    double? temp,
  }) {
    if (bpm == null || gsr == null) return null;

    final effectiveTs = ts ?? (++_syntheticTs);
    _points.add(_SensorPoint(ts: effectiveTs.toDouble(), bpm: bpm, gsr: gsr, temp: temp));

    while (_points.length > windowSize) {
      _points.removeFirst();
    }

    _samplesSinceInference++;
    if (_points.length < windowSize || _samplesSinceInference < stepSize) {
      return null;
    }
    _samplesSinceInference = 0;

    final features = _extractFeatures(_points.toList(growable: false));
    _calibrator.ingest(features);
    final normalized = _calibrator.normalize(features);

    final prob = _predictStressProbability(normalized);
    final smooth = _smoothedProb == null ? prob : (_smoothedProb! * 0.7 + prob * 0.3);
    _smoothedProb = smooth;

    final proxy = (smooth * 100.0).clamp(0.0, 100.0);
    final confidence = ((smooth - 0.5).abs() * 2.0).clamp(0.0, 1.0);

    StressLevel level;
    if (smooth < 0.40) {
      level = StressLevel.low;
    } else if (smooth < 0.70) {
      level = StressLevel.medium;
    } else {
      level = StressLevel.high;
    }

    return StressInferenceResult(
      stressProbability: smooth,
      cortisolProxy: proxy,
      confidence: confidence,
      level: level,
      calibrationReady: _calibrator.ready,
    );
  }

  Map<String, double> _extractFeatures(List<_SensorPoint> points) {
    final bpmVals = points.map((p) => p.bpm).toList(growable: false);
    final gsrVals = points.map((p) => p.gsr).toList(growable: false);
    final tempVals = points.where((p) => p.temp != null).map((p) => p.temp!).toList(growable: false);

    final bpmMean = _mean(bpmVals);
    final gsrMean = _mean(gsrVals);
    final tempMean = tempVals.isEmpty ? 0.0 : _mean(tempVals);

    final bpmStd = _std(bpmVals, bpmMean);
    final gsrStd = _std(gsrVals, gsrMean);

    final bpmSlope = _slope(points.map((p) => p.ts).toList(growable: false), bpmVals);
    final gsrSlope = _slope(points.map((p) => p.ts).toList(growable: false), gsrVals);

    final firstTemp = tempVals.isEmpty ? tempMean : tempVals.first;
    final lastTemp = tempVals.isEmpty ? tempMean : tempVals.last;
    final tempDelta = lastTemp - firstTemp;

    final tempSlope = tempVals.length < 2
        ? 0.0
        : _slope(
            List<double>.generate(tempVals.length, (i) => i.toDouble()),
            tempVals,
          );

    return {
      'bpm_mean': bpmMean,
      'bpm_std': bpmStd,
      'bpm_slope': bpmSlope,
      'gsr_mean': gsrMean,
      'gsr_std': gsrStd,
      'gsr_slope': gsrSlope,
      'temp_mean': tempMean,
      'temp_delta': tempDelta,
      'temp_slope': tempSlope,
    };
  }

  double _predictStressProbability(Map<String, double> f) {
    const weights = <String, double>{
      'bpm_mean': 0.20,
      'bpm_std': 0.15,
      'bpm_slope': 0.15,
      'gsr_mean': 0.24,
      'gsr_std': 0.16,
      'gsr_slope': 0.10,
      'temp_mean': -0.05,
      'temp_delta': -0.08,
      'temp_slope': -0.05,
    };

    double logit = -0.10;
    weights.forEach((k, w) {
      logit += w * (f[k] ?? 0.0);
    });

    final bounded = logit.clamp(-8.0, 8.0);
    return 1.0 / (1.0 + exp(-bounded));
  }

  double _mean(List<double> values) {
    if (values.isEmpty) return 0.0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  double _std(List<double> values, double mean) {
    if (values.length < 2) return 0.0;
    double sum = 0.0;
    for (final v in values) {
      final d = v - mean;
      sum += d * d;
    }
    return sqrt(sum / (values.length - 1));
  }

  double _slope(List<double> xs, List<double> ys) {
    if (xs.length != ys.length || xs.length < 2) return 0.0;

    final xMean = _mean(xs);
    final yMean = _mean(ys);

    double num = 0.0;
    double den = 0.0;
    for (int i = 0; i < xs.length; i++) {
      final xd = xs[i] - xMean;
      num += xd * (ys[i] - yMean);
      den += xd * xd;
    }
    if (den.abs() < 1e-9) return 0.0;
    return num / den;
  }
}

class _SensorPoint {
  final double ts;
  final double bpm;
  final double gsr;
  final double? temp;

  const _SensorPoint({
    required this.ts,
    required this.bpm,
    required this.gsr,
    required this.temp,
  });
}

class _FeatureCalibrator {
  final int maxWindows;
  final Map<String, _RunningStats> _stats = {};
  int collected = 0;

  _FeatureCalibrator({required this.maxWindows});

  bool get ready => collected >= maxWindows;

  void reset() {
    _stats.clear();
    collected = 0;
  }

  void ingest(Map<String, double> features) {
    if (ready) return;
    features.forEach((key, value) {
      final stat = _stats.putIfAbsent(key, _RunningStats.new);
      stat.add(value);
    });
    collected++;
  }

  Map<String, double> normalize(Map<String, double> features) {
    final out = <String, double>{};
    features.forEach((key, value) {
      final stat = _stats[key];
      if (!ready || stat == null || stat.std < 1e-6) {
        out[key] = value;
      } else {
        out[key] = (value - stat.mean) / stat.std;
      }
    });
    return out;
  }
}

class _RunningStats {
  int n = 0;
  double _mean = 0.0;
  double _m2 = 0.0;

  void add(double x) {
    n++;
    final delta = x - _mean;
    _mean += delta / n;
    final delta2 = x - _mean;
    _m2 += delta * delta2;
  }

  double get mean => _mean;
  double get variance => n > 1 ? (_m2 / (n - 1)) : 0.0;
  double get std => sqrt(variance);
}
