# Training Pipeline

Python training and export pipeline for stress inference artifacts consumed by the Flutter app.

Location:
- `/Users/naderalmasri/Desktop/Project_IoT/training`

## Pipeline Modes

This repo currently supports three training paths:
1. WESAD baseline logistic training
2. WESAD plus local combined logistic retraining
3. Nurse dataset Random Forest multiclass training (current app direction)

## Environment Setup

```bash
cd /Users/naderalmasri/Desktop/Project_IoT/training
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Or use:
```bash
make venv
```

## Make Targets

```bash
make help
```

Main targets:
- `make prepare-wesad`
- `make train-wesad`
- `make train-combined`
- `make retrain-combined`
- `make train-hybrid`
- `make retrain-hybrid`
- `make train-nurse-rf`

## Nurse Random Forest Path

Script:
- `/Users/naderalmasri/Desktop/Project_IoT/training/train_nurse_rf.py`

Required input:
- nurse CSV in `combined_lagEDA` format with required columns:
  - lag: `30..1`
  - `EDAR_Mean`, `EDAR_Min`, `EDAR_Max`, `EDAR_Std`
  - `HRR_Mean`, `HRR_Min`, `HRR_Max`, `HRR_Std`
  - `TEMPR_Mean`, `TEMPR_Min`, `TEMPR_Max`, `TEMPR_Std`
  - `Stress` in `{0,1,2}`

Example:
```bash
make train-nurse-rf \
  NURSE_CSV='/absolute/path/to/combined_lagEDA.csv' \
  NURSE_SELECT_MODEL=blocked \
  NURSE_CV_FOLDS=5 \
  NURSE_QUICK_GRID=0
```

### Model selection logic
The script always computes both evaluations:
- random split
- blocked split (grouped contiguous chunks by `group-size`)

Then it exports one chosen model via `--select-model random|blocked`.

`blocked` is default because lag based sequential data can leak temporal patterns under random split.

### Hyperparameter search
Grid search is run on random split training set with weighted F1 objective:
- `n_estimators: [300, 500]`
- `max_depth: [10, 15, 20]`
- `min_samples_leaf: [3, 5, 7]`
- `max_features: [sqrt, log2]`

Quick smoke mode (`--quick-grid`) uses a tiny grid for speed.

### Nurse RF outputs
In output dir (default `artifacts_nurse_rf`):
- `model_joblib.pkl`
- `metrics.json`
- `feature_importance.csv`
- `feature_cols.joblib`

## Random vs Blocked Metrics

`metrics.json` includes both to separate:
- benchmark style performance (`random_split_metrics`)
- realistic temporal generalization (`blocked_split_metrics`)

Interpretation guideline:
- random split is typically higher and optimistic
- blocked split is stricter and closer to deployment behavior on time adjacent windows

## Export to Flutter

Nurse RF JSON export utility:
- `/Users/naderalmasri/Desktop/Project_IoT/training/export_nurse_rf_flutter.py`

Current app artifact loaded at runtime:
- `/Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app/assets/models/nurse_rf_model.json`

Also used by app About page:
- `/Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app/assets/models/model_info.json`
- `/Users/naderalmasri/Desktop/Project_IoT/cortisol_ble_app/assets/models/metrics.json`

## WESAD and Hybrid Paths

### WESAD prepare
```bash
python wesad_prepare.py \
  --wesad-root /absolute/path/to/WESAD \
  --out-csv data/wesad_features.csv \
  --window-seconds 30 \
  --step-seconds 5
```

### WESAD baseline train
```bash
python train_stress_model.py \
  --features-csv data/wesad_features.csv \
  --out-dir artifacts
```

### Combined retrain
```bash
make retrain-combined
```

### Hybrid WESAD plus nurse multiclass
```bash
make train-hybrid \
  NURSE_CSV='/absolute/path/to/combined_lagEDA.csv' \
  OPTIMIZE_FOR=accuracy
```

## Data and Label Notes

- WESAD mapping in binary path: baseline vs stress.
- Nurse path is native multiclass labels `0/1/2`.
- App currently follows nurse multiclass direction plus per user calibration logic on device.

## Scientific References

Nurse dataset paper:
- [A multimodal sensor dataset for continuous stress detection of nurses in a hospital (PMCID: PMC9159985)](https://pmc.ncbi.nlm.nih.gov/articles/PMC9159985/)

Dryad dataset DOI from metadata:
- `10.5061/dryad.5hqbzkh6f`

## Practical Recommendation

For engineering reporting keep both metrics.
For deployment selection prefer blocked split chosen model unless you have subject separated validation that proves otherwise.
