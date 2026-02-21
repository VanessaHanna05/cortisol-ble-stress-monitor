# Cortisol BLE Stress Monitor

Flutter Android app that connects to an ESP32 over BLE, receives physiological data, and displays live health metrics with a stress/cortisol-proxy dashboard.

## Overview
This project reads BLE notifications from an ESP32 peripheral and parses streamed JSON packets containing:
- `ts`
- `BPM` stats (`avg`, `min`, `max`, `std`)
- `GSR` stats (`avg`, `min`, `max`, `std`)
- `Temp` stats (`avg`, `min`, `max`, `std`)

The app includes:
- BLE scan/connect/disconnect flow
- Fragmented JSON stream reassembly and parsing
- Tabbed UI (`Connection`, `Dashboard`, `Raw`)
- Expandable metric cards for BPM, GSR, Temperature, Stress
- Live trend lines and raw stream debug view

## Current Status
The app is working and usable on Android.

What works now:
- Device scanning and connection over BLE
- Characteristic selection and notification enablement
- Fragmented JSON parsing and metric display
- Stress and cortisol-proxy display in dashboard
- Raw debug tab for packet inspection

Current known issue:
- Live dashboard updates are not fully stable in all runs.
- Sometimes values stop refreshing until reconnect is pressed.

## Important Note About Inference
The current stress/cortisol logic is **not a trained ML model yet**.

Right now it uses:
- Simple on-device feature analysis
- Heuristic stress scoring and smoothing
- Calibration-like baseline logic

Planned next step:
- Replace heuristic scoring with a trained model (starting from WESAD-style feature pipeline + lightweight mobile model).

## Tech Stack
- Flutter (Material 3)
- `flutter_blue_plus` `2.1.1`
- Android target (tested on Samsung S9 SM-G960F)

## BLE Data Format (expected)
```json
{
  "ts": 317521,
  "BPM": {"avg": 74.2, "min": 57.0, "max": 83.0, "std": 7.83},
  "GSR": {"avg": 2239.5, "min": 2224.0, "max": 2251.0, "std": 8.79},
  "Temp": {"avg": 220.84, "min": 220.83, "max": 220.86, "std": 0.01}
}
```

## Run Locally
```bash
cd /Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app
flutter pub get
flutter run -d SM_G960F
```

## Project Structure
- `lib/main.dart` main app, BLE handling, parser, UI
- `lib/ml/stress_engine.dart` current heuristic stress engine scaffold

## Roadmap
1. Fix continuous live refresh without manual reconnect
2. Add notification watchdog + auto-resubscribe fallback
3. Add labeled data logger for training
4. Train lightweight stress model and deploy on device
5. Improve personalization and per-user calibration

## Repository Name Suggestion
`cortisol-ble-stress-monitor`
