# Cortisol BLE Stress Monitor

End to end IoT and mobile pipeline for BLE physiological sensing and on device stress inference.

This repository has two active parts:
- `/Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app`: Flutter app that connects to ESP32 and runs inference locally.
- `/Users/naderalmasri/Desktop/Project_IoT/training`: Python training and export pipeline for model artifacts used by the app.

## Current System State

The app is working and running on Android with live BLE ingestion.

Current deployed model path is nurse dataset driven Random Forest multiclass inference:
- classes: `0 = low`, `1 = medium`, `2 = high`
- app output: stress score, confidence, stress level, and a cortisol proxy trend

Important: `cortisol_proxy` is not biochemical cortisol concentration. It is a scaled stress proxy for trend visualization.

## BLE Data Flow

1. ESP32 notifies bytes over BLE characteristic `abcd1234-5678-1234-5678-abcdef123456`.
2. Flutter decodes UTF8 chunks with `allowMalformed: true`.
3. A brace matching stream assembler rebuilds complete JSON objects from fragmented and concatenated packets.
4. Parsed objects update live metrics when keys exist (`ts`, `BPM`, `GSR`, `Temp`).
5. Valid windows are passed to ML inference.

Service Changed (`00002a05-0000-1000-8000-00805f9b34fb`) is explicitly avoided for data path selection.

## Calibration and Personalization

Calibration is now user specific and profile based:
- calibration prompt appears only after BLE connection
- user chooses a `userId`
- baseline is stored per user in app documents as `user_calibration_<userId>.json`
- calibration mode collects rest windows and persists baseline statistics
- completion triggers a visible "Calibration complete" notification

Inference is blocked if required signals are invalid.

## Confidence vs Probability

UI now emphasizes confidence instead of raw probability wording.

Confidence is computed from baseline relative sensor deltas and model certainty:
- z bands are computed per sensor (HR, EDA, Temp) against personal baseline
- sensor confidence bands are weighted `0.4 HR + 0.4 EDA + 0.2 Temp`
- final confidence blends sensor and model confidence

This makes confidence more physiologically interpretable for user specific behavior.

## App Tabs

Current top level tabs:
- `Connection`
- `Dashboard`
- `About`

Raw BLE stream moved into Developer Tools inside `About`.

## Model Artifacts Used By App

Location:
- `/Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app/assets/models`

Current files:
- `nurse_rf_model.json`
- `metrics.json`
- `model_info.json`
- `model_flutter.json` (legacy logistic artifact retained for compatibility)

## Training and Evaluation Summary

Primary nurse run metadata currently in assets:
- rows: `12445`
- features: `42`
- best random grid params: `n_estimators=500`, `max_depth=20`, `min_samples_leaf=3`, `max_features=sqrt`
- random split accuracy: `0.9675`
- blocked split accuracy: `0.6389`
- selected exported model mode: blocked

Why both metrics exist:
- random split is benchmark style and optimistic for lagged sequential windows
- blocked split simulates realistic temporal generalization and is stricter

## Quick Start

### App
```bash
cd /Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app
flutter pub get
flutter run -d SM_G960F
```

### Training
```bash
cd /Users/naderalmasri/Desktop/Project_IoT/training
make help
```

## Dataset References

Nurse dataset paper used in current model documentation:
- [Scientific Data paper (PMCID: PMC9159985)](https://pmc.ncbi.nlm.nih.gov/articles/PMC9159985/)

WESAD is still kept in the repo for baseline and experiments, but current app direction is nurse centered modeling and per user calibration.

## Known Engineering Gaps

- BLE live update path still needs additional hardening to remove reconnect like behavior in edge cases.
- Model quality is sensitive to distribution drift across users and sessions.
- Cortisol output remains a stress proxy, not a clinical cortisol assay.
