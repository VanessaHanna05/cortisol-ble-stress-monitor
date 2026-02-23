# Cortisol BLE App

Flutter Android application for BLE physiological monitoring with on device stress inference and per user calibration.

## Runtime Architecture

### BLE stack
- plugin: `flutter_blue_plus` `2.1.1`
- connect path requests MTU, discovers services, finds notify characteristic by UUID, and subscribes to `lastValueStream`
- explicit ignore path for Service Changed characteristic `00002a05-0000-1000-8000-00805f9b34fb`

### Stream parser
Incoming BLE payloads can split JSON arbitrarily. The app uses continuous buffering plus brace depth extraction:
- append every decoded chunk to a rolling buffer
- increment depth on `{`, decrement on `}`
- when depth returns to `0`, decode object candidate
- parse all complete objects in chunk, keep remainder in buffer
- cap raw buffer size for bounded memory

This handles both fragmentation and back to back JSON objects without delimiters.

### Expected payload shape
```json
{
  "ts": 317521,
  "BPM": {"avg": 74.2, "min": 57.0, "max": 83.0, "std": 7.83},
  "GSR": {"avg": 2239.5, "min": 2224.0, "max": 2251.0, "std": 8.79},
  "Temp": {"avg": 220.84, "min": 220.83, "max": 220.86, "std": 0.01}
}
```

## Inference Engine

Core engine file:
- `/Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app/lib/ml/stress_engine.dart`

Current loaded model artifact:
- `/Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app/assets/models/nurse_rf_model.json`

### Validity gating
Inference requires valid values for all three channels:
- BPM > 0
- GSR > 0
- Temp > 0

If any signal is invalid, inference is skipped and reason is surfaced.

### Windowing
- model works on rolling windows assembled from live metric snapshots
- inference output includes stress score, stress class, and confidence

### Confidence computation
Confidence is not a direct model probability display anymore.
It is derived from:
- baseline relative sensor deltas (per user z score bands)
- model certainty signal
- weighted fusion in engine

UI maps confidence to qualitative levels:
- High
- Medium
- Low

### Cortisol proxy
`cortisol_proxy` is a non medical scaled proxy linked to stress output. It is intended for trend tracking only.

## Personal Calibration

Calibration behavior after latest update:
- prompt appears only after successful BLE connection
- user can enter a `userId` before calibration start
- app stores profile baseline at `user_calibration_<userId>.json`
- completion shows toast notification

Baseline is used to normalize interpretation per individual and improve confidence semantics.

## UI Structure

Bottom navigation tabs:
- `Connection`
- `Dashboard`
- `About`

Developer features are inside `About`:
- raw BLE stream view
- copy raw button
- labeling controls and data collection helpers
- history access

## History and Logging

App writes CSV logs for valid inference windows with fields such as:
- timestamp
- bpm avg
- gsr avg
- temp avg
- stress score
- cortisol proxy
- stress level
- label

History table is opened on a dedicated page from app controls.

## Model Metadata in About

About page reads and displays:
- `/Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app/assets/models/model_info.json`
- `/Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app/assets/models/metrics.json`

This includes dataset source, model version, training date, and evaluation metrics.

## Run

```bash
cd /Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app
flutter pub get
flutter run -d SM_G960F
```

## Development Notes

- If model assets are updated, restart app to reload bundled JSON artifacts.
- Keep BLE characteristic UUID constants aligned with ESP32 firmware.
- Any model swap must preserve expected input feature schema used by runtime engine.
