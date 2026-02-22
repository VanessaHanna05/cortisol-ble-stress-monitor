SHELL := /bin/bash

VENV ?= .venv
PYTHON := $(VENV)/bin/python
PIP := $(VENV)/bin/pip

WESAD_ROOT ?= /Users/naderalmasri/Desktop/Project_IoT/datasets/WESAD
WESAD_FEATURES ?= data/wesad_features.csv
LOCAL_DIR ?= local_sessions
COMBINED_FEATURES ?= data/combined_features.csv
OUT_BASE ?= artifacts
OUT_COMBINED ?= artifacts_combined
APP_ASSETS ?= ../cortisol_ble_app/assets/models
LOCAL_WEIGHT ?= 2.0
WINDOW_SECONDS ?= 30
STEP_SECONDS ?= 5

.PHONY: help venv prepare-wesad train-wesad train-combined sync-combined-model retrain-combined

help:
	@echo "Targets:"
	@echo "  make venv                  # Create/update venv and install deps"
	@echo "  make prepare-wesad         # Build WESAD feature CSV"
	@echo "  make train-wesad           # Train baseline model on WESAD"
	@echo "  make train-combined        # Train combined model (WESAD + local sessions)"
	@echo "  make sync-combined-model   # Copy combined model artifacts to app assets"
	@echo "  make retrain-combined      # One-command combined retrain + sync"
	@echo ""
	@echo "Config vars:"
	@echo "  WESAD_ROOT=$(WESAD_ROOT)"
	@echo "  LOCAL_DIR=$(LOCAL_DIR)"
	@echo "  LOCAL_WEIGHT=$(LOCAL_WEIGHT)"

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

sync-combined-model:
	mkdir -p "$(APP_ASSETS)"
	cp "$(OUT_COMBINED)/model_flutter.json" "$(APP_ASSETS)/model_flutter.json"
	cp "$(OUT_COMBINED)/metrics.json" "$(APP_ASSETS)/metrics.json"
	@echo "Synced model artifacts to $(APP_ASSETS)"

retrain-combined: train-combined sync-combined-model
	@echo "Done. Restart Flutter app to load updated model asset."
