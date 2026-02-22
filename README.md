# Cortisol BLE Stress Monitor

Flutter Android app for BLE-based physiological monitoring with on-device stress inference and a cortisol proxy trend.

## What This App Does
The app connects to an ESP32 peripheral, receives streamed sensor statistics over BLE, parses fragmented JSON packets, and shows:
- live BPM, GSR, temperature
- stress probability and stress level
- cortisol proxy trend (derived from stress probability)
- history table and CSV export

## Current Approach
This project uses a two-stage ML strategy:
1. Baseline model from WESAD (public dataset)
2. Fine tuning/retraining with local app session data to reduce domain shift

Inference runs fully on device using exported logistic-regression parameters (`model_flutter.json`).

## Important Scientific Note
`cortisol_proxy` is **not** biochemical cortisol concentration. It is a stress-derived trend score:
- `cortisol_proxy = stress_probability * 100`

## BLE Input Format
Expected payloads contain:
- `ts`
- `BPM` map: `avg`, `min`, `max`, `std`
- `GSR` map: `avg`, `min`, `max`, `std`
- `Temp` map: `avg`, `min`, `max`, `std`

Example:
```json
{
  "ts": 317521,
  "BPM": {"avg": 74.2, "min": 57.0, "max": 83.0, "std": 7.83},
  "GSR": {"avg": 2239.5, "min": 2224.0, "max": 2251.0, "std": 8.79},
  "Temp": {"avg": 220.84, "min": 220.83, "max": 220.86, "std": 0.01}
}
```

## App Features
- BLE scan/connect/disconnect/reconnect
- fragmented stream parser for BLE JSON chunks
- tabbed UI: `Connection`, `Dashboard`, `Raw`, `About`
- expandable metric cards and trends
- dedicated history page with table view
- session labeling (`Rest`, `Stress`, `Recovery`, `Unlabeled`)
- CSV logging of valid inference rows
- copy-to-clipboard CSV export

## Stress Inference Rules
Stress is computed only when all three are valid:
- valid BPM
- valid GSR
- valid temperature

If one is missing/invalid, stress inference is skipped and the reason is shown.

## Model Files Used In App
Located in:
`/Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app/assets/models`

- `model_flutter.json` model/scaler parameters used by Flutter inference
- `metrics.json` latest training metrics
- `model_info.json` model/dataset metadata shown in About tab

## Run The App
```bash
cd /Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app
flutter pub get
flutter run -d SM_G960F
```
Then use hot restart (`R`) after model updates.

## Training Workflow
Training assets are in:
`/Users/naderalmasri/Desktop/Project_IoT/training`

### One-command retrain (WESAD + local sessions)
```bash
cd /Users/naderalmasri/Desktop/Project_IoT/training
make retrain-combined
```

This command:
1. merges WESAD features + local session CSVs
2. trains combined logistic model
3. exports artifacts to `training/artifacts_combined`
4. syncs model and metrics into app assets

### Other useful commands
```bash
make help
make prepare-wesad
make train-wesad
make train-combined
```

## Local Session Data
Local session CSV files are expected in:
`/Users/naderalmasri/Desktop/Project_IoT/training/local_sessions`

Schema:
`time_iso,ts,bpm_avg,gsr_avg,temp_avg,stress_prob,cortisol_proxy,stress_level,label,ml_loaded`

## Dataset Reference
Primary baseline dataset:
- WESAD (Wearable Stress and Affect Detection)
- UCI Repository, DOI: `10.24432/C57K5T`

## Known Limitations
- live BLE refresh stability still requires ongoing tuning depending on device conditions
- model output quality depends heavily on real local labeled sessions
- Local data is only for pipeline testing, not final model validation

## Next Steps
1. collect more real labeled sessions
2. retrain with higher real-data ratio
3. calibrate thresholds and confidence display
4. improve stream stability to remove periodic reconnect fallback
