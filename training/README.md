# Training Pipeline (WESAD and Nurse)

This folder contains:
- baseline binary stress training on WESAD
- combined binary retraining with local app sessions
- hybrid multiclass harmonization and training using WESAD plus nurse dataset

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

## 3) Train hybrid 3-class model (WESAD + nurse)
Use this when you want labels `0=low`, `1=medium`, `2=high`.

Required nurse CSV columns:
- lag EDA columns: `30..1` (optional but recommended)
- `EDAR_Mean`, `EDAR_Min`, `EDAR_Max`, `EDAR_Std`
- `HRR_Mean`, `HRR_Min`, `HRR_Max`, `HRR_Std`
- `TEMPR_Mean`, `TEMPR_Min`, `TEMPR_Max`, `TEMPR_Std`
- `Stress` in `{0,1,2}`

Run:
```bash
python harmonize_and_train_multiclass.py \
  --wesad-features data/wesad_features.csv \
  --nurse-csv /absolute/path/to/combined_lagEDA.csv \
  --out-merged-csv data/hybrid_features.csv \
  --out-dir artifacts_hybrid \
  --optimize-for accuracy
```

What this script does:
- maps nurse columns to canonical app feature names
- computes missing slopes and HRV proxies
- aligns nurse scales to WESAD like physiological ranges using quantile mapping
- trains multinomial logistic regression with grouped split
- benchmarks multiple model families and selects best by `accuracy` or `f1_macro`
- exports:
  - `artifacts_hybrid/model_joblib.pkl`
  - `artifacts_hybrid/model_flutter_multiclass.json` (logistic fallback for Flutter runtime)
  - `artifacts_hybrid/metrics.json`
  - `artifacts_hybrid/sanity_checks.json` (before/after scale alignment stats)

## 4) Train nurse-only Random Forest (random plus blocked)
Use this to train a nurse-only RF with grid search and report both benchmark and realistic metrics.

Run:
```bash
python train_nurse_rf.py \
  --nurse-csv /absolute/path/to/combined_lagEDA.csv \
  --out-dir artifacts_nurse_rf \
  --test-size 0.20 \
  --group-size 120 \
  --cv-folds 5 \
  --select-model blocked \
  --n-jobs 1
```

This script outputs:
- `artifacts_nurse_rf/model_joblib.pkl`
- `artifacts_nurse_rf/metrics.json`
- `artifacts_nurse_rf/feature_importance.csv`
- `artifacts_nurse_rf/feature_cols.joblib`

`metrics.json` includes:
- best params from random-split grid search
- `random_split_metrics` benchmark numbers
- `blocked_split_metrics` realistic generalization numbers
- exported model selectable by `--select-model random|blocked`
- for quick debug runs, add `--quick-grid`

## Notes
- This is a global baseline model from public data.
- You should still calibrate per user using your own app-collected sessions.
- Current app heuristic can be replaced with exported Flutter model inference after app side multiclass integration.
