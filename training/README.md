# Training Pipeline (WESAD -> Stress Model)

This folder contains a baseline supervised ML pipeline for stress detection.

## Goal
Train a binary stress classifier (`non_stress` vs `stress`) using WESAD and export a lightweight model artifact that can later be used in Flutter.

## Dataset expected layout
Unzip WESAD so the directory looks like:

```text
/path/to/WESAD/
  S2/
    S2.pkl
  S3/
    S3.pkl
  ...
```

## Labels used
WESAD labels are mapped as:
- `1` baseline -> `0` non_stress
- `2` stress -> `1` stress

By default, other labels are ignored.

## Setup
```bash
cd /Users/naderalmasri/Desktop/Project_IoT/training
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 1) Build windowed features CSV
```bash
python wesad_prepare.py \
  --wesad-root /absolute/path/to/WESAD \
  --out-csv data/wesad_features.csv \
  --window-seconds 30 \
  --step-seconds 5
```

## 2) Train baseline model
```bash
python train_stress_model.py \
  --features-csv data/wesad_features.csv \
  --out-dir artifacts
```

Outputs:
- `artifacts/metrics.json`
- `artifacts/model_joblib.pkl`
- `artifacts/model_flutter.json` (scaler + logistic coefficients for Flutter)

## Notes
- This is a global baseline model from public data.
- You should still calibrate per user using your own app-collected sessions.
- Current app heuristic can be replaced later with `model_flutter.json` inference.
