# install arduino-cli (linux)
curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh
sudo mv bin/arduino-cli /usr/local/bin/

arduino-cli config init
arduino-cli core update-index
arduino-cli core install esp32:esp32

# required libs (names may vary by index)
arduino-cli lib install "Blynk"
arduino-cli lib install "MAX30105"
arduino-cli lib install "ClosedCube MAX30205"
arduino-cli lib install "Adafruit SSD1306"
arduino-cli lib install "Adafruit GFX Library"

# compile
arduino-cli compile \
  --fqbn esp32:esp32:esp32 \
  sketch_feb18a/sketch_feb18a.ino
