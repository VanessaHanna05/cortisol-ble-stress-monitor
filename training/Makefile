SHELL := /bin/bash

VENV ?= .venv
PYTHON := $(VENV)/bin/python
PIP := $(VENV)/bin/pip

WESAD_ROOT ?= /Users/naderalmasri/Desktop/Project_IoT/datasets/WESAD
WESAD_FEATURES ?= data/wesad_features.csv
LOCAL_DIR ?= local_sessions
COMBINED_FEATURES ?= data/combined_features.csv
NURSE_CSV ?= /absolute/path/to/combined_lagEDA.csv
HYBRID_FEATURES ?= data/hybrid_features.csv
OUT_BASE ?= artifacts
OUT_COMBINED ?= artifacts_combined
OUT_HYBRID ?= artifacts_hybrid
OUT_NURSE_RF ?= artifacts_nurse_rf
APP_ASSETS ?= ../cortisol_ble_app/assets/models
LOCAL_WEIGHT ?= 2.0
NURSE_WEIGHT ?= 1.25
OPTIMIZE_FOR ?= accuracy
NURSE_TEST_SIZE ?= 0.20
NURSE_GROUP_SIZE ?= 120
NURSE_CV_FOLDS ?= 5
NURSE_SELECT_MODEL ?= blocked
NURSE_N_JOBS ?= 1
NURSE_QUICK_GRID ?= 0
WINDOW_SECONDS ?= 30
STEP_SECONDS ?= 5

.PHONY: help venv prepare-wesad train-wesad train-combined sync-combined-model retrain-combined train-hybrid sync-hybrid-model retrain-hybrid train-nurse-rf

help:
	@echo "Targets:"
	@echo "  make venv                  # Create/update venv and install deps"
	@echo "  make prepare-wesad         # Build WESAD feature CSV"
	@echo "  make train-wesad           # Train baseline model on WESAD"
	@echo "  make train-combined        # Train combined model (WESAD + local sessions)"
	@echo "  make train-hybrid          # Train hybrid 3-class model (WESAD + nurse)"
	@echo "  make train-nurse-rf        # Train nurse-only Random Forest benchmark"
	@echo "  make sync-combined-model   # Copy combined model artifacts to app assets"
	@echo "  make sync-hybrid-model     # Copy hybrid model artifacts to app assets"
	@echo "  make retrain-combined      # One-command combined retrain + sync"
	@echo "  make retrain-hybrid        # One-command hybrid retrain + sync"
	@echo ""
	@echo "Config vars:"
	@echo "  WESAD_ROOT=$(WESAD_ROOT)"
	@echo "  LOCAL_DIR=$(LOCAL_DIR)"
	@echo "  LOCAL_WEIGHT=$(LOCAL_WEIGHT)"
	@echo "  NURSE_CSV=$(NURSE_CSV)"
	@echo "  NURSE_WEIGHT=$(NURSE_WEIGHT)"
	@echo "  OPTIMIZE_FOR=$(OPTIMIZE_FOR)"
	@echo "  OUT_NURSE_RF=$(OUT_NURSE_RF)"
	@echo "  NURSE_TEST_SIZE=$(NURSE_TEST_SIZE)"
	@echo "  NURSE_GROUP_SIZE=$(NURSE_GROUP_SIZE)"
	@echo "  NURSE_CV_FOLDS=$(NURSE_CV_FOLDS)"
	@echo "  NURSE_SELECT_MODEL=$(NURSE_SELECT_MODEL)"
	@echo "  NURSE_N_JOBS=$(NURSE_N_JOBS)"
	@echo "  NURSE_QUICK_GRID=$(NURSE_QUICK_GRID)"

venv:
	@test -d "$(VENV)" || python3 -m venv "$(VENV)"
	$(PIP) install -r requirements.txt

prepare-wesad: venv
	$(PYTHON) wesad_prepare.py \
		--wesad-root "$(WESAD_ROOT)" \
		--out-csv "$(WESAD_FEATURES)" \
		--window-seconds "$(WINDOW_SECONDS)" \
		--step-seconds "$(STEP_SECONDS)"

train-wesad: venv
	$(PYTHON) train_stress_model.py \
		--features-csv "$(WESAD_FEATURES)" \
		--out-dir "$(OUT_BASE)"

train-combined: venv
	$(PYTHON) merge_local_and_train.py \
		--wesad-features "$(WESAD_FEATURES)" \
		--local-dir "$(LOCAL_DIR)" \
		--out-merged-csv "$(COMBINED_FEATURES)" \
		--out-dir "$(OUT_COMBINED)" \
		--local-weight "$(LOCAL_WEIGHT)"

train-hybrid: venv
	$(PYTHON) harmonize_and_train_multiclass.py \
		--wesad-features "$(WESAD_FEATURES)" \
		--nurse-csv "$(NURSE_CSV)" \
		--out-merged-csv "$(HYBRID_FEATURES)" \
		--out-dir "$(OUT_HYBRID)" \
		--nurse-weight "$(NURSE_WEIGHT)" \
		--optimize-for "$(OPTIMIZE_FOR)"

train-nurse-rf: venv
	$(PYTHON) train_nurse_rf.py \
		--nurse-csv "$(NURSE_CSV)" \
		--out-dir "$(OUT_NURSE_RF)" \
		--test-size "$(NURSE_TEST_SIZE)" \
		--group-size "$(NURSE_GROUP_SIZE)" \
		--cv-folds "$(NURSE_CV_FOLDS)" \
		--select-model "$(NURSE_SELECT_MODEL)" \
		--n-jobs "$(NURSE_N_JOBS)" \
		$(if $(filter 1,$(NURSE_QUICK_GRID)),--quick-grid,)

sync-combined-model:
	mkdir -p "$(APP_ASSETS)"
	cp "$(OUT_COMBINED)/model_flutter.json" "$(APP_ASSETS)/model_flutter.json"
	cp "$(OUT_COMBINED)/metrics.json" "$(APP_ASSETS)/metrics.json"
	@echo "Synced model artifacts to $(APP_ASSETS)"

retrain-combined: train-combined sync-combined-model
	@echo "Done. Restart Flutter app to load updated model asset."

sync-hybrid-model:
	mkdir -p "$(APP_ASSETS)"
	cp "$(OUT_HYBRID)/model_flutter_multiclass.json" "$(APP_ASSETS)/model_flutter_multiclass.json"
	cp "$(OUT_HYBRID)/metrics.json" "$(APP_ASSETS)/metrics_hybrid.json"
	@echo "Synced hybrid model artifacts to $(APP_ASSETS)"

retrain-hybrid: train-hybrid sync-hybrid-model
	@echo "Done. Restart Flutter app to load updated hybrid model asset."
