// Put this first so Arduino auto generated prototypes can see Stats
struct Stats {
  float avg;
  float mn;
  float mx;
  float sd;
  bool valid;
};

/*************************************************************
  ESP32: BLE + Blynk + OLED + MAX30102 + MAX30205 + GSR

  Behavior
  1) Sample BPM, Temp, GSR every 1 second
  2) Collect 10 samples
  3) Compute avg, min, max, std dev for each over the 10 samples
  4) Send stats over BLE as a dictionary style JSON string:
     {
       "ts":123,
       "BPM":{"avg":..,"min":..,"max":..,"std":..},
       "GSR":{"avg":..,"min":..,"max":..,"std":..},
       "Temp":{"avg":..,"min":..,"max":..,"std":..}
     }
*************************************************************/

#define BLYNK_TEMPLATE_ID           "TMPL5v8AJmv62"
#define BLYNK_TEMPLATE_NAME         "Quickstart Device"
#define BLYNK_AUTH_TOKEN            "KRwjwBtqGNB2AG7ht6aKEmfb8ETcxRtL"

#define BLYNK_PRINT Serial

#include <math.h>
#include <WiFi.h>
#include <WiFiClient.h>
#include <BlynkSimpleEsp32.h>

#include <Wire.h>
#include "MAX30105.h"
#include "heartRate.h"
#include "ClosedCube_MAX30205.h"

#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// -------------------- WiFi --------------------
char ssid[] = "vnss";
char pass[] = "12345678";

// -------------------- I2C pins --------------------
#define SDA_PIN 21
#define SCL_PIN 22

// -------------------- GSR --------------------
#define GSR_PIN 34

// -------------------- Blynk virtual pins --------------------
#define VPIN_BPM   V4
#define VPIN_TEMP  V5
#define VPIN_GSR   V6

BlynkTimer timer;

// -------------------- MAX30102 --------------------
MAX30105 particleSensor;
bool max30102_ok = false;

const byte RATE_SIZE = 4;
byte rates[RATE_SIZE];
byte rateSpot = 0;
long lastBeat = 0;
float beatsPerMinute = 0;
int beatAvg = 0;

// -------------------- MAX30205 --------------------
ClosedCube_MAX30205 max30205;
bool max30205_ok = false;
uint8_t max30205Addr = 0;

float TEMP_OFFSET_C = 0.0f;

uint8_t findMAX30205Addr() {
  for (uint8_t a = 0x48; a <= 0x4F; a++) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0) return a;
  }
  return 0;
}

// -------------------- OLED (SPI) --------------------
#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64

#define OLED_MOSI   23
#define OLED_CLK    18
#define OLED_DC     16
#define OLED_CS     5
#define OLED_RESET  4

Adafruit_SSD1306 display(
  SCREEN_WIDTH, SCREEN_HEIGHT,
  OLED_MOSI, OLED_CLK, OLED_DC, OLED_RESET, OLED_CS
);

bool oled_ok = false;

void oledPrintStatus(const String& a, const String& b = "", const String& c = "") {
  if (!oled_ok) return;
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println(a);
  if (b.length()) display.println(b);
  if (c.length()) display.println(c);
  display.display();
}

void updateOLEDStats(float bpmAvg, float tempAvg, float gsrAvg) {
  if (!oled_ok) return;

  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);

  display.setTextSize(2);
  display.setCursor(0, 0);
  display.print("B:");
  display.print((int)(bpmAvg + 0.5f));

  display.setTextSize(1);
  display.setCursor(0, 28);
  display.print("T: ");
  if (isnan(tempAvg)) display.print("N/A");
  else display.print(tempAvg, 1);
  display.print(" C");

  display.setCursor(0, 44);
  display.print("G: ");
  display.print((int)(gsrAvg + 0.5f));

  display.setCursor(92, 44);
  display.print(Blynk.connected() ? "BK" : "--");

  display.display();
}

// -------------------- GSR average --------------------
int readGsrAverage() {
  long sum = 0;
  for (int i = 0; i < 10; i++) {
    sum += analogRead(GSR_PIN);
    delay(5);
  }
  return (int)(sum / 10);
}

// ==================== BLE SETUP ====================
#define BLE_DEVICE_NAME     "ESP32_HealthMonitor"
#define SERVICE_UUID        "12345678-1234-1234-1234-1234567890ab"
#define CHAR_UUID_NOTIFY    "abcd1234-5678-1234-5678-abcdef123456"

BLEServer* pServer = nullptr;
BLECharacteristic* pChar = nullptr;
volatile bool bleClientConnected = false;

class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override { bleClientConnected = true; }
  void onDisconnect(BLEServer* server) override {
    bleClientConnected = false;
    BLEDevice::startAdvertising();
  }
};

void setupBLE() {
  // Helps fit the JSON payload without truncation
  BLEDevice::setMTU(247);

  BLEDevice::init(BLE_DEVICE_NAME);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  pChar = pService->createCharacteristic(
    CHAR_UUID_NOTIFY,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );

  pChar->addDescriptor(new BLE2902());
  pChar->setValue("Booting...");

  pService->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  adv->start();

  Serial.println("BLE advertising started");
}

// -------------------- Stats helpers --------------------
Stats computeStats(const float* x, int n) {
  Stats s;
  s.valid = (n > 0);
  if (!s.valid) {
    s.avg = NAN; s.mn = NAN; s.mx = NAN; s.sd = NAN;
    return s;
  }

  float sum = 0.0f;
  float mn = x[0];
  float mx = x[0];

  for (int i = 0; i < n; i++) {
    sum += x[i];
    if (x[i] < mn) mn = x[i];
    if (x[i] > mx) mx = x[i];
  }

  float avg = sum / (float)n;

  float varSum = 0.0f;
  for (int i = 0; i < n; i++) {
    float d = x[i] - avg;
    varSum += d * d;
  }

  float variance = varSum / (float)n;
  float sd = sqrtf(variance);

  s.avg = avg;
  s.mn = mn;
  s.mx = mx;
  s.sd = sd;
  return s;
}

Stats computeStatsTempIgnoreNaN(const float* x, int n) {
  float tmp[10];
  int m = 0;
  for (int i = 0; i < n; i++) {
    if (!isnan(x[i])) tmp[m++] = x[i];
  }
  if (m == 0) {
    Stats s;
    s.valid = false;
    s.avg = NAN; s.mn = NAN; s.mx = NAN; s.sd = NAN;
    return s;
  }
  return computeStats(tmp, m);
}

// -------------------- Sampling buffers --------------------
static const int WIN = 10;

float bpmBuf[WIN];
float tempBuf[WIN];
float gsrBuf[WIN];
int sampleCount = 0;

// -------------------- BLE send stats as dictionary JSON --------------------
void bleSendStatsJSON(uint32_t tsMs, const Stats& b, const Stats& t, const Stats& g) {
  if (!pChar) return;

  char buf[320];

  if (!t.valid) {
    snprintf(
      buf, sizeof(buf),
      "{"
        "\"ts\":%lu,"
        "\"BPM\":{\"avg\":%.2f,\"min\":%.2f,\"max\":%.2f,\"std\":%.2f},"
        "\"GSR\":{\"avg\":%.2f,\"min\":%.2f,\"max\":%.2f,\"std\":%.2f},"
        "\"Temp\":{\"avg\":null,\"min\":null,\"max\":null,\"std\":null}"
      "}",
      (unsigned long)tsMs,
      b.avg, b.mn, b.mx, b.sd,
      g.avg, g.mn, g.mx, g.sd
    );
  } else {
    snprintf(
      buf, sizeof(buf),
      "{"
        "\"ts\":%lu,"
        "\"BPM\":{\"avg\":%.2f,\"min\":%.2f,\"max\":%.2f,\"std\":%.2f},"
        "\"GSR\":{\"avg\":%.2f,\"min\":%.2f,\"max\":%.2f,\"std\":%.2f},"
        "\"Temp\":{\"avg\":%.2f,\"min\":%.2f,\"max\":%.2f,\"std\":%.2f}"
      "}",
      (unsigned long)tsMs,
      b.avg, b.mn, b.mx, b.sd,
      g.avg, g.mn, g.mx, g.sd,
      t.avg, t.mn, t.mx, t.sd
    );
  }

  pChar->setValue((uint8_t*)buf, strlen(buf));
  if (bleClientConnected) pChar->notify();
}

// -------------------- every 1s: sample and every 10 samples: compute + send --------------------
void sampleEvery1s() {
  float tempC = NAN;
  if (max30205_ok) tempC = max30205.readTemperature() + TEMP_OFFSET_C;

  float bpmNow = (float)beatAvg;
  float gsrNow = (float)readGsrAverage();

  bpmBuf[sampleCount] = bpmNow;
  tempBuf[sampleCount] = tempC;
  gsrBuf[sampleCount] = gsrNow;

  sampleCount++;

  if (sampleCount >= WIN) {
    Stats b = computeStats(bpmBuf, WIN);
    Stats g = computeStats(gsrBuf, WIN);
    Stats t = computeStatsTempIgnoreNaN(tempBuf, WIN);

    uint32_t tsMs = millis();

    updateOLEDStats(b.avg, t.valid ? t.avg : NAN, g.avg);

    // BLE JSON dictionary send
    bleSendStatsJSON(tsMs, b, t, g);

    // Blynk sends window averages only
    if (Blynk.connected()) {
      Blynk.virtualWrite(VPIN_BPM, b.avg);
      if (t.valid) Blynk.virtualWrite(VPIN_TEMP, t.avg);
      Blynk.virtualWrite(VPIN_GSR, g.avg);
    }

    sampleCount = 0;
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);

  Serial.println("Init OLED...");
  oled_ok = display.begin(SSD1306_SWITCHCAPVCC);
  if (oled_ok) oledPrintStatus("OLED OK", "Booting...");
  else Serial.println("OLED init FAILED.");

  setupBLE();
  if (oled_ok) oledPrintStatus("BLE Advertising", BLE_DEVICE_NAME);

  Wire.begin(SDA_PIN, SCL_PIN);
  Wire.setClock(100000);

  analogReadResolution(12);
  analogSetAttenuation(ADC_11db);

  Serial.println("Init MAX30102...");
  if (oled_ok) oledPrintStatus("Init MAX30102...");

  max30102_ok = particleSensor.begin(Wire);
  if (!max30102_ok) {
    Serial.println("MAX30102 FAILED. Continuing without BPM.");
    if (oled_ok) oledPrintStatus("MAX30102 FAIL", "BPM will be 0");
  } else {
    particleSensor.setup();
    particleSensor.setPulseAmplitudeRed(0x0A);
    particleSensor.setPulseAmplitudeGreen(0);
    Serial.println("MAX30102 OK.");
    if (oled_ok) oledPrintStatus("MAX30102 OK", "Red LED should be ON");
  }

  Serial.println("Scan MAX30205...");
  if (oled_ok) oledPrintStatus("Scan MAX30205...");

  max30205Addr = findMAX30205Addr();
  if (max30205Addr == 0) {
    Serial.println("MAX30205 not found. Temp will be N/A.");
    max30205_ok = false;
    if (oled_ok) oledPrintStatus("MAX30205 NOT FOUND", "Temp = N/A");
  } else {
    max30205.begin(max30205Addr);
    max30205_ok = true;
    Serial.print("MAX30205 found at 0x");
    if (max30205Addr < 16) Serial.print("0");
    Serial.println(max30205Addr, HEX);
    if (oled_ok) oledPrintStatus("MAX30205 OK", "Addr: 0x" + String(max30205Addr, HEX));
  }

  Serial.println("WiFi connecting...");
  if (oled_ok) oledPrintStatus("WiFi connecting...", ssid);

  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, pass);

  unsigned long t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 6000) {
    delay(200);
    Serial.print(".");
  }
  Serial.println();

  Blynk.config(BLYNK_AUTH_TOKEN);

  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("WiFi OK IP: ");
    Serial.println(WiFi.localIP());
    if (oled_ok) oledPrintStatus("WiFi OK", WiFi.localIP().toString(), "Connecting Blynk...");
    Blynk.connect(3000);
  } else {
    Serial.println("WiFi FAIL (Blynk offline). BLE still works.");
    if (oled_ok) oledPrintStatus("WiFi FAIL", "Blynk offline", "BLE still works");
  }

  // sample every 1 second
  timer.setInterval(1000L, sampleEvery1s);

  if (oled_ok) oledPrintStatus("RUNNING",
                               String("Blynk: ") + (Blynk.connected() ? "ON" : "OFF"),
                               String("BLE: ADV"));
}

void loop() {
  if (Blynk.connected()) Blynk.run();
  timer.run();

  // MAX30102 BPM update loop
  if (max30102_ok) {
    particleSensor.check();

    if (particleSensor.available()) {
      long irValue = particleSensor.getIR();
      particleSensor.nextSample();

      if (checkForBeat(irValue)) {
        long delta = millis() - lastBeat;
        lastBeat = millis();
        beatsPerMinute = 60.0f / (delta / 1000.0f);

        if (beatsPerMinute < 255 && beatsPerMinute > 20) {
          rates[rateSpot++] = (byte)beatsPerMinute;
          rateSpot %= RATE_SIZE;

          beatAvg = 0;
          for (byte i = 0; i < RATE_SIZE; i++) beatAvg += rates[i];
          beatAvg /= RATE_SIZE;
        }
      }

      if (irValue < 50000) beatAvg = 0;
    }
  } else {
    beatAvg = 0;
  }

  delay(5);
}
