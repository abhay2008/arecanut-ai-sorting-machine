#include <Arduino.h>
#include <SoftwareSerial.h>

/*
  ==============================================================================
  HC-05 BLUETOOTH RGB LED + HC-SR04 PROXIMITY SENSOR (ULTRA-SMOOTH TRANSITIONS)
  Board: Arduino Uno with Sensor Shield V5.0
  
  Hardware Pin Connections:
  -------------------------
  1. HC-SR04 Ultrasonic Distance Sensor:
     - VCC  -> 5V (V Header) on Sensor Shield
     - GND  -> GND (G Header) on Sensor Shield
     - Trig -> Digital Pin 12 (S Header)
     - Echo -> Digital Pin 13 (S Header)

  2. Bluetooth Module (HC-05 / HC-06):
     - TXD  -> Arduino Digital Pin 10 (SoftwareSerial RX)
     - RXD  -> Arduino Digital Pin 11 (SoftwareSerial TX)
     - VCC  -> 5V on Sensor Shield
     - GND  -> GND on Sensor Shield

  3. Common Anode RGB LED:
     - Common Anode -> 5V VCC on Sensor Shield (Longest leg)
     - Red Pin      -> Arduino Digital Pin 3 (PWM)
     - Green Pin    -> Arduino Digital Pin 5 (PWM)
     - Blue Pin     -> Arduino Digital Pin 6 (PWM)

  Smooth Proximity Logic:
  -----------------------
  - Instantaneous Distance Logging: 20 times per second (50ms interval).
  - Distance < 3.0 cm              -> Smooth Fade to GREEN
  - Distance < 6.0 cm (3cm - 6cm)  -> Smooth Fade to WHITE
  - Distance >= 6.0 cm             -> Smooth Fade to OFF
  - All state & color changes use non-blocking exponential smoothing (no harsh snapping).
  ==============================================================================
*/

// --- Pin Definitions ---
const int BT_RX_PIN  = 10; // SoftwareSerial RX (BT TXD)
const int BT_TX_PIN  = 11; // SoftwareSerial TX (BT RXD)

const int PIN_RED    = 3;  // Red LED Channel (PWM)
const int PIN_GREEN  = 5;  // Green LED Channel (PWM)
const int PIN_BLUE   = 6;  // Blue LED Channel (PWM)

const int PIN_TRIG   = 12; // HC-SR04 Trigger Pin
const int PIN_ECHO   = 13; // HC-SR04 Echo Pin

// --- SoftwareSerial Object ---
SoftwareSerial btSerial(BT_RX_PIN, BT_TX_PIN);

// --- Operation Modes ---
enum Mode {
  MODE_OFF,
  MODE_GREEN,
  MODE_RED,
  MODE_BLUE,
  MODE_FADE
};

Mode currentMode = MODE_OFF;

// --- Brightness Control ---
const uint8_t BRIGHTNESS_LEVELS[] = {255, 191, 128, 64}; // 100%, 75%, 50%, 25%
const char* BRIGHTNESS_NAMES[]   = {"100%", "75%", "50%", "25%"};
uint8_t brightnessIndex = 0;
uint8_t masterBrightness = 255;

// --- Distance Sensor & Proximity States ---
unsigned long lastDistanceMeasureTime = 0;
const unsigned long DISTANCE_SAMPLE_INTERVAL = 50; // 50ms = 20 measurements per second

enum ProximityState {
  STATE_FAR,   // >= 6.0 cm (Smooth Fade to OFF)
  STATE_WHITE, // < 6.0 cm and >= 3.0 cm (Smooth Fade to WHITE)
  STATE_GREEN  // < 3.0 cm (Smooth Fade to GREEN)
};

ProximityState currentProxState = STATE_FAR;

// --- Smooth Transition Target & Current Variables ---
uint8_t targetRed   = 0;
uint8_t targetGreen = 0;
uint8_t targetBlue  = 0;

float currentRed   = 0.0;
float currentGreen = 0.0;
float currentBlue  = 0.0;

unsigned long lastSmoothUpdate = 0;
const unsigned long SMOOTH_INTERVAL_MS = 6; // 6ms loop for ultra-smooth fading

// --- Color Cross-Fade Animation Variables ---
unsigned long lastFadeStepTime = 0;
const unsigned long FADE_INTERVAL_MS = 15;
int fadeStep = 0;

// --- Function Declarations ---
void setTargetRGB(uint8_t red, uint8_t green, uint8_t blue);
void updateSmoothLED();
void applyCurrentMode();
void updateFadeAnimation();
void processCommand(char cmd);
void cycleBrightness();
float measureDistance();
void checkDistanceSensor();

void setup() {
  Serial.begin(115200);
  Serial.println(F("=================================================="));
  Serial.println(F(" RGB LED ULTRA-SMOOTH PROXIMITY INITIALIZING    "));
  Serial.println(F("=================================================="));

  btSerial.begin(9600);

  // Configure RGB Pins
  pinMode(PIN_RED, OUTPUT);
  pinMode(PIN_GREEN, OUTPUT);
  pinMode(PIN_BLUE, OUTPUT);

  // Configure HC-SR04 Pins
  pinMode(PIN_TRIG, OUTPUT);
  pinMode(PIN_ECHO, INPUT);
  digitalWrite(PIN_TRIG, LOW);

  // Start with LED OFF
  setTargetRGB(0, 0, 0);

  Serial.println(F("Pins Configured:"));
  Serial.println(F("  - Ultrasonic Sensor: Trig -> Pin 12, Echo -> Pin 13"));
  Serial.println(F("  - RGB LED: Red -> Pin 3, Green -> Pin 5, Blue -> Pin 6"));
  Serial.println(F("  - Bluetooth: RX -> Pin 10, TX -> Pin 11\n"));
  Serial.println(F("Smooth Proximity Logic:"));
  Serial.println(F("  - Distance < 3.0cm           -> Smooth Fade to GREEN"));
  Serial.println(F("  - Distance < 6.0cm (3-6cm)   -> Smooth Fade to WHITE"));
  Serial.println(F("  - Distance >= 6.0cm          -> Smooth Fade to OFF"));
  Serial.println(F("Logging instantaneous distance 20 times/sec (50ms interval)..."));
}

void loop() {
  // 1. Read Bluetooth Commands (Non-blocking)
  while (btSerial.available() > 0) {
    char cmd = btSerial.read();
    if (cmd != '\r' && cmd != '\n' && cmd != ' ') {
      processCommand(cmd);
    }
  }

  // 2. Read USB Serial Commands
  while (Serial.available() > 0) {
    char cmd = Serial.read();
    if (cmd != '\r' && cmd != '\n' && cmd != ' ') {
      processCommand(cmd);
    }
  }

  // 3. High-Frequency Distance Measurement & Multi-Zone Proximity Control (Every 50ms)
  checkDistanceSensor();

  // 4. Color Wheel Cross-Fade (Runs only when far and MODE_FADE is selected)
  if (currentProxState == STATE_FAR && currentMode == MODE_FADE) {
    updateFadeAnimation();
  }

  // 5. Always update smooth LED hardware outputs (Non-blocking exponential interpolation)
  updateSmoothLED();
}

/**
 * Updates target RGB colors for smooth interpolation
 */
void setTargetRGB(uint8_t red, uint8_t green, uint8_t blue) {
  targetRed   = red;
  targetGreen = green;
  targetBlue  = blue;
}

/**
 * Non-blocking smooth LED hardware driver.
 * Smoothly interpolates currentRed, currentGreen, currentBlue toward target values.
 */
void updateSmoothLED() {
  unsigned long now = millis();
  if (now - lastSmoothUpdate >= SMOOTH_INTERVAL_MS) {
    lastSmoothUpdate = now;

    // Smoothness interpolation factor (0.12 = silky smooth 300ms transition)
    float speed = 0.12;

    currentRed   += (targetRed   - currentRed)   * speed;
    currentGreen += (targetGreen - currentGreen) * speed;
    currentBlue  += (targetBlue  - currentBlue)  * speed;

    // Snap to exact target when extremely close
    if (abs(targetRed   - currentRed)   < 0.4) currentRed   = targetRed;
    if (abs(targetGreen - currentGreen) < 0.4) currentGreen = targetGreen;
    if (abs(targetBlue  - currentBlue)  < 0.4) currentBlue  = targetBlue;

    // Apply masterBrightness scaling
    uint8_t scaledR = (uint8_t(currentRed)   * masterBrightness) / 255;
    uint8_t scaledG = (uint8_t(currentGreen) * masterBrightness) / 255;
    uint8_t scaledB = (uint8_t(currentBlue)  * masterBrightness) / 255;

    // Common Anode Inversion: analogWrite(pin, 255 - scaledValue)
    analogWrite(PIN_RED,   255 - scaledR);
    analogWrite(PIN_GREEN, 255 - scaledG);
    analogWrite(PIN_BLUE,  255 - scaledB);
  }
}

/**
 * Measure instantaneous distance in centimeters using HC-SR04
 */
float measureDistance() {
  digitalWrite(PIN_TRIG, LOW);
  delayMicroseconds(2);
  digitalWrite(PIN_TRIG, HIGH);
  delayMicroseconds(10);
  digitalWrite(PIN_TRIG, LOW);

  unsigned long duration = pulseIn(PIN_ECHO, HIGH, 20000);

  if (duration == 0) {
    return -1.0; // Out of range or no echo
  }

  float distanceCm = (duration * 0.0343) / 2.0;
  return distanceCm;
}

/**
 * Checks distance sensor 20 times per second (every 50ms).
 * Smoothly transitions LED:
 *   - Distance < 3.0 cm              -> Smooth GREEN
 *   - Distance < 6.0 cm (3cm - 6cm)  -> Smooth WHITE
 *   - Distance >= 6.0 cm             -> Smooth OFF
 */
void checkDistanceSensor() {
  unsigned long currentMillis = millis();

  if (currentMillis - lastDistanceMeasureTime >= DISTANCE_SAMPLE_INTERVAL) {
    lastDistanceMeasureTime = currentMillis;

    float currentDistance = measureDistance();

    if (currentDistance > 0.0) {
      // Log instantaneous distance 20 times/sec
      Serial.print(F("[DIST] "));
      Serial.print(currentDistance, 1);
      Serial.println(F(" cm"));

      // Zone 1: Distance < 3.0 cm -> Smooth GREEN
      if (currentDistance < 3.0) {
        if (currentProxState != STATE_GREEN) {
          currentProxState = STATE_GREEN;
          Serial.println(F(" ~~~ PROXIMITY ZONE 1: Distance < 3cm -> Smooth FADE to GREEN ~~~"));
          setTargetRGB(0, 255, 0); // Smooth Green
        }
      } 
      // Zone 2: Distance < 6.0 cm (3cm to 6cm) -> Smooth WHITE
      else if (currentDistance < 6.0) {
        if (currentProxState != STATE_WHITE) {
          currentProxState = STATE_WHITE;
          Serial.println(F(" ~~~ PROXIMITY ZONE 2: Distance < 6cm -> Smooth FADE to WHITE ~~~"));
          setTargetRGB(255, 255, 255); // Smooth White
        }
      } 
      // Zone 3: Distance >= 6.0 cm -> Smooth OFF / Normal State
      else {
        if (currentProxState != STATE_FAR) {
          currentProxState = STATE_FAR;
          Serial.println(F(" ~~~ Distance >= 6cm -> Smooth FADE to OFF ~~~"));
          setTargetRGB(0, 0, 0); // Smooth OFF
        }
      }
    } else {
      Serial.println(F("[DIST] Out of range / No echo"));
      if (currentProxState != STATE_FAR) {
        currentProxState = STATE_FAR;
        setTargetRGB(0, 0, 0);
      }
    }
  }
}

/**
 * Re-applies active mode target color
 */
void applyCurrentMode() {
  switch (currentMode) {
    case MODE_OFF:
      setTargetRGB(0, 0, 0);
      break;
    case MODE_GREEN:
      setTargetRGB(0, 255, 0);
      break;
    case MODE_RED:
      setTargetRGB(255, 0, 0);
      break;
    case MODE_BLUE:
      setTargetRGB(0, 0, 255);
      break;
    case MODE_FADE:
      // Handled by updateFadeAnimation()
      break;
  }
}

/**
 * Cycle brightness: 100% -> 75% -> 50% -> 25% -> 100%
 */
void cycleBrightness() {
  brightnessIndex = (brightnessIndex + 1) % 4;
  masterBrightness = BRIGHTNESS_LEVELS[brightnessIndex];

  String msg = " -> Brightness set to: " + String(BRIGHTNESS_NAMES[brightnessIndex]);
  Serial.println(msg);
  btSerial.println(msg);

  if (currentProxState == STATE_FAR) {
    applyCurrentMode();
  }
}

/**
 * Command processor
 */
void processCommand(char cmd) {
  Serial.print(F("Command Received: '"));
  Serial.print(cmd);
  Serial.println(F("'"));

  switch (cmd) {
    case '0':
      currentMode = MODE_OFF;
      setTargetRGB(0, 0, 0);
      Serial.println(F(" -> Mode Set: LED OFF"));
      btSerial.println(F("LED OFF"));
      break;

    case '1':
      currentMode = MODE_GREEN;
      setTargetRGB(0, 255, 0);
      Serial.println(F(" -> Mode Set: Solid GREEN"));
      btSerial.println(F("Solid GREEN"));
      break;

    case '2':
      currentMode = MODE_RED;
      setTargetRGB(255, 0, 0);
      Serial.println(F(" -> Mode Set: Solid RED"));
      btSerial.println(F("Solid RED"));
      break;

    case '3':
      currentMode = MODE_BLUE;
      setTargetRGB(0, 0, 255);
      Serial.println(F(" -> Mode Set: Solid BLUE"));
      btSerial.println(F("Solid BLUE"));
      break;

    case '4':
      currentMode = MODE_FADE;
      fadeStep = 0;
      lastFadeStepTime = millis();
      Serial.println(F(" -> Mode Set: Continuous Smooth Color Cross-Fade"));
      btSerial.println(F("Color Cross-Fade Mode"));
      break;

    case '5':
      cycleBrightness();
      break;

    default:
      Serial.println(F(" -> Unknown Command! Use '0', '1', '2', '3', '4', or '5'."));
      break;
  }
}

/**
 * Non-blocking color wheel cross-fade animation.
 */
void updateFadeAnimation() {
  unsigned long currentMillis = millis();

  if (currentMillis - lastFadeStepTime >= FADE_INTERVAL_MS) {
    lastFadeStepTime = currentMillis;

    uint8_t r = 0, g = 0, b = 0;
    int phase = fadeStep / 255;
    int pos = fadeStep % 255;

    switch (phase) {
      case 0: r = 255;       g = pos;       b = 0;         break;
      case 1: r = 255 - pos; g = 255;       b = 0;         break;
      case 2: r = 0;         g = 255;       b = pos;       break;
      case 3: r = 0;         g = 255 - pos; b = 255;       break;
      case 4: r = pos;       g = 0;         b = 255;       break;
      case 5: r = 255;       g = 0;         b = 255 - pos; break;
    }

    setTargetRGB(r, g, b);
    fadeStep = (fadeStep + 1) % 1530;
  }
}
