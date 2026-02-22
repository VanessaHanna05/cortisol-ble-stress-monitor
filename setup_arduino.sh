#!/usr/bin/env bash
set -euo pipefail

# Install Arduino CLI (Linux)
curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh

# Move binary to a global path if possible, otherwise keep local binary
if command -v sudo >/dev/null 2>&1; then
  sudo mv bin/arduino-cli /usr/local/bin/
  ARDUINO_CLI="arduino-cli"
else
  mkdir -p "$HOME/.local/bin"
  mv bin/arduino-cli "$HOME/.local/bin/arduino-cli"
  export PATH="$HOME/.local/bin:$PATH"
  ARDUINO_CLI="$HOME/.local/bin/arduino-cli"
fi

"$ARDUINO_CLI" config init || true
"$ARDUINO_CLI" core update-index
"$ARDUINO_CLI" core install esp32:esp32

# Required libraries (names may vary by index)
"$ARDUINO_CLI" lib install "Blynk"
"$ARDUINO_CLI" lib install "MAX30105"
"$ARDUINO_CLI" lib install "ClosedCube MAX30205"
"$ARDUINO_CLI" lib install "Adafruit SSD1306"
"$ARDUINO_CLI" lib install "Adafruit GFX Library"

# Compile sketch
"$ARDUINO_CLI" compile \
  --fqbn esp32:esp32:esp32 \
  sketch_feb18a/sketch_feb18a.ino