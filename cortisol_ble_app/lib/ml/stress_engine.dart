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

  double? _smoothedProb;
  _LogisticModel? _trainedModel;

  StressEngine({
    this.windowSize = 8,
    this.stepSize = 1,
    this.baselineWindows = 8,
  });

  void reset() {
    _points.clear();
    _samplesSinceInference = 0;
    _syntheticTs = 0;
    _smoothedProb = null;
  }

  bool get hasTrainedModel => _trainedModel != null;
  bool get calibrationReady => hasTrainedModel;
  int get baselineCollected => hasTrainedModel ? baselineWindows : 0;
  int get baselineTarget => baselineWindows;
  int get currentWindowSamples => _points.length;
  int get windowTarget => windowSize;

  void loadFlutterModel(Map<String, dynamic> json) {
    _trainedModel = _LogisticModel.fromJson(json);
  }

  StressInferenceResult? addSample({
    int? ts,
    double? bpmAvg,
    double? bpmMin,
    double? bpmMax,
    double? bpmStd,
    double? gsrAvg,
    double? gsrMin,
    double? gsrMax,
    double? gsrStd,
    double? tempAvg,
    double? tempMin,
    double? tempMax,
    double? tempStd,
  }) {
    if (bpmAvg == null || gsrAvg == null) return null;

    final effectiveTs = ts ?? (++_syntheticTs);
    _points.add(
      _SensorPoint(
        ts: effectiveTs.toDouble(),
        bpmAvg: bpmAvg,
        bpmMin: bpmMin ?? bpmAvg,
        bpmMax: bpmMax ?? bpmAvg,
        bpmStd: bpmStd ?? 0.0,
        gsrAvg: gsrAvg,
        gsrMin: gsrMin ?? gsrAvg,
        gsrMax: gsrMax ?? gsrAvg,
        gsrStd: gsrStd ?? 0.0,
        tempAvg: tempAvg,
        tempMin: tempMin ?? tempAvg,
        tempMax: tempMax ?? tempAvg,
        tempStd: tempStd ?? 0.0,
      ),
    );

    while (_points.length > windowSize) {
      _points.removeFirst();
    }

    _samplesSinceInference++;
    if (_points.length < windowSize || _samplesSinceInference < stepSize) {
      return null;
    }
    _samplesSinceInference = 0;

    final features = _extractFeatures(_points.toList(growable: false));
    final prob = _predictStressProbability(features);
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
      calibrationReady: calibrationReady,
    );
  }

  Map<String, double> _extractFeatures(List<_SensorPoint> points) {
    final ts = points.map((p) => p.ts).toList(growable: false);
    final bpmAvg = points.map((p) => p.bpmAvg).toList(growable: false);
    final bpmMin = points.map((p) => p.bpmMin).toList(growable: false);
    final bpmMax = points.map((p) => p.bpmMax).toList(growable: false);
    final bpmStd = points.map((p) => p.bpmStd).toList(growable: false);

    final gsrAvg = points.map((p) => p.gsrAvg).toList(growable: false);
    final gsrMin = points.map((p) => p.gsrMin).toList(growable: false);
    final gsrMax = points.map((p) => p.gsrMax).toList(growable: false);
    final gsrStd = points.map((p) => p.gsrStd).toList(growable: false);

    final tempAvg = points.where((p) => p.tempAvg != null).map((p) => p.tempAvg!).toList(growable: false);
    final tempMin = points.where((p) => p.tempMin != null).map((p) => p.tempMin!).toList(growable: false);
    final tempMax = points.where((p) => p.tempMax != null).map((p) => p.tempMax!).toList(growable: false);
    final tempStd = points.where((p) => p.tempStd != null).map((p) => p.tempStd!).toList(growable: false);

    return {
      'bpm_avg': _mean(bpmAvg),
      'bpm_min': _mean(bpmMin),
      'bpm_max': _mean(bpmMax),
      'bpm_std': _mean(bpmStd),
      'hrv_rmssd': _rmssdFromBpm(bpmAvg),
      'hrv_sdnn': _std(bpmAvg, _mean(bpmAvg)),
      'gsr_avg': _mean(gsrAvg),
      'gsr_min': _mean(gsrMin),
      'gsr_max': _mean(gsrMax),
      'gsr_std': _mean(gsrStd),
      'gsr_slope': _slope(ts, gsrAvg),
      'temp_avg': tempAvg.isEmpty ? 0.0 : _mean(tempAvg),
      'temp_min': tempMin.isEmpty ? 0.0 : _mean(tempMin),
      'temp_max': tempMax.isEmpty ? 0.0 : _mean(tempMax),
      'temp_std': tempStd.isEmpty ? 0.0 : _mean(tempStd),
      'temp_slope': tempAvg.length < 2 ? 0.0 : _slope(ts.take(tempAvg.length).toList(), tempAvg),
    };
  }

  double _predictStressProbability(Map<String, double> features) {
    final adapted = _adaptFeatureUnits(features);

    if (_trainedModel != null) {
      return _trainedModel!.predictProbability(adapted);
    }

    const weights = <String, double>{
      'bpm_avg': 0.15,
      'bpm_std': 0.10,
      'gsr_avg': 0.24,
      'gsr_std': 0.18,
      'gsr_slope': 0.14,
      'temp_avg': -0.07,
      'temp_slope': -0.05,
    };
    double logit = -0.15;
    weights.forEach((k, w) => logit += w * (adapted[k] ?? 0.0));
    final bounded = logit.clamp(-8.0, 8.0);
    return 1.0 / (1.0 + exp(-bounded));
  }

  Map<String, double> _adaptFeatureUnits(Map<String, double> f) {
    final out = Map<String, double>.from(f);

    // App-side GSR can come as large ADC-like values (e.g., 2200+), while WESAD
    // EDA features are around single-digit values. Scale down when detected.
    if ((out['gsr_avg'] ?? 0.0) > 50.0) {
      out['gsr_avg'] = (out['gsr_avg'] ?? 0.0) / 1000.0;
      out['gsr_min'] = (out['gsr_min'] ?? 0.0) / 1000.0;
      out['gsr_max'] = (out['gsr_max'] ?? 0.0) / 1000.0;
      out['gsr_std'] = (out['gsr_std'] ?? 0.0) / 1000.0;
      out['gsr_slope'] = (out['gsr_slope'] ?? 0.0) / 1000.0;
    }

    // Temperature can be streamed as deci/centi units by some firmware.
    if ((out['temp_avg'] ?? 0.0) > 80.0) {
      out['temp_avg'] = (out['temp_avg'] ?? 0.0) / 10.0;
      out['temp_min'] = (out['temp_min'] ?? 0.0) / 10.0;
      out['temp_max'] = (out['temp_max'] ?? 0.0) / 10.0;
      out['temp_std'] = (out['temp_std'] ?? 0.0) / 10.0;
    }
    if ((out['temp_avg'] ?? 0.0) > 80.0) {
      out['temp_avg'] = (out['temp_avg'] ?? 0.0) / 10.0;
      out['temp_min'] = (out['temp_min'] ?? 0.0) / 10.0;
      out['temp_max'] = (out['temp_max'] ?? 0.0) / 10.0;
      out['temp_std'] = (out['temp_std'] ?? 0.0) / 10.0;
    }

    return out;
  }

  double _rmssdFromBpm(List<double> bpmVals) {
    if (bpmVals.length < 3) return 0.0;
    final rrMs = bpmVals.where((v) => v > 1e-6).map((v) => 60000.0 / v).toList(growable: false);
    if (rrMs.length < 3) return 0.0;

    double sum = 0.0;
    int count = 0;
    for (int i = 1; i < rrMs.length; i++) {
      final d = rrMs[i] - rrMs[i - 1];
      sum += d * d;
      count++;
    }
    if (count == 0) return 0.0;
    return sqrt(sum / count);
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
  final double bpmAvg;
  final double bpmMin;
  final double bpmMax;
  final double bpmStd;
  final double gsrAvg;
  final double gsrMin;
  final double gsrMax;
  final double gsrStd;
  final double? tempAvg;
  final double? tempMin;
  final double? tempMax;
  final double? tempStd;

  const _SensorPoint({
    required this.ts,
    required this.bpmAvg,
    required this.bpmMin,
    required this.bpmMax,
    required this.bpmStd,
    required this.gsrAvg,
    required this.gsrMin,
    required this.gsrMax,
    required this.gsrStd,
    required this.tempAvg,
    required this.tempMin,
    required this.tempMax,
    required this.tempStd,
  });
}

class _LogisticModel {
  final List<String> features;
  final List<double> scalerMean;
  final List<double> scalerScale;
  final List<double> coef;
  final double intercept;
  final double threshold;

  _LogisticModel({
    required this.features,
    required this.scalerMean,
    required this.scalerScale,
    required this.coef,
    required this.intercept,
    required this.threshold,
  });

  factory _LogisticModel.fromJson(Map<String, dynamic> json) {
    return _LogisticModel(
      features: (json['features'] as List).map((e) => e.toString()).toList(growable: false),
      scalerMean: (json['scaler_mean'] as List).map((e) => (e as num).toDouble()).toList(growable: false),
      scalerScale: (json['scaler_scale'] as List).map((e) => (e as num).toDouble()).toList(growable: false),
      coef: (json['coef'] as List).map((e) => (e as num).toDouble()).toList(growable: false),
      intercept: (json['intercept'] as num).toDouble(),
      threshold: json['threshold'] == null ? 0.5 : (json['threshold'] as num).toDouble(),
    );
  }

  double predictProbability(Map<String, double> inputFeatures) {
    double logit = intercept;
    for (int i = 0; i < features.length; i++) {
      final key = features[i];
      double raw = inputFeatures[key] ?? 0.0;
      final scale = (i < scalerScale.length && scalerScale[i].abs() > 1e-12) ? scalerScale[i] : 1.0;
      final mean = i < scalerMean.length ? scalerMean[i] : 0.0;

      // HRV derived from sparse app summaries is not directly comparable to
      // training-time beat-to-beat HRV. Keep it neutral to avoid saturation.
      if (key == 'hrv_rmssd' || key == 'hrv_sdnn') {
        raw = mean;
      }

      // Prevent out-of-distribution feature spikes from collapsing probability.
      final z = ((raw - mean) / scale).clamp(-3.0, 3.0);
      final w = i < coef.length ? coef[i] : 0.0;
      logit += w * z;
    }

    final bounded = logit.clamp(-8.0, 8.0);
    return 1.0 / (1.0 + exp(-bounded));
  }
}
