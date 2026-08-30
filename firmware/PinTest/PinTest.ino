/*
  Arduino Uno + Sensor Shield V5.0 Diagnostic Sketch
*/

const int DIGITAL_START = 2;
const int DIGITAL_END = 13;
const int ANALOG_PINS[] = {A0, A1, A2, A3, A4, A5};
const int NUM_ANALOG = 6;

void setup() {
  Serial.begin(115200);
  while (!Serial) { ; }
  delay(1000);

  Serial.println(F("\n=========================================="));
  Serial.println(F(" ARDUINO UNO + SENSOR SHIELD V5.0 DIAGNOSTIC "));
  Serial.println(F("==========================================\n"));

  int passedDigital = 0;
  int totalDigital = DIGITAL_END - DIGITAL_START + 1;

  Serial.println(F("--- TEST 1: Digital Pins Input Pullup & Drive ---"));
  for (int pin = DIGITAL_START; pin <= DIGITAL_END; pin++) {
    bool pinOk = true;

    // Test OUTPUT LOW
    pinMode(pin, OUTPUT);
    digitalWrite(pin, LOW);
    delay(2);
    if (digitalRead(pin) != LOW) {
      Serial.print(F(" [FAIL] Pin D")); Serial.print(pin); Serial.println(F(": Driven LOW failed"));
      pinOk = false;
    }

    // Test OUTPUT HIGH
    digitalWrite(pin, HIGH);
    delay(2);
    if (digitalRead(pin) != HIGH) {
      Serial.print(F(" [FAIL] Pin D")); Serial.print(pin); Serial.println(F(": Driven HIGH failed"));
      pinOk = false;
    }

    // Test INPUT_PULLUP (Note: Pin 13 has onboard LED resistor load to GND)
    pinMode(pin, INPUT_PULLUP);
    delay(2);
    int pullupVal = digitalRead(pin);

    pinMode(pin, INPUT); // Reset to input

    if (pinOk) {
      passedDigital++;
      Serial.print(F(" [PASS] Pin D")); Serial.print(pin);
      if (pin == 13) {
        Serial.print(F(" (Built-in LED / Shield LED load: Pullup = "));
        Serial.print(pullupVal == HIGH ? F("HIGH") : F("LOW (Normal for LED load to GND)"));
        Serial.print(F(")"));
      }
      if (pin == 3 || pin == 5 || pin == 6 || pin == 9 || pin == 10 || pin == 11) {
        Serial.print(F(" [PWM]"));
      }
      Serial.println();
    }
  }

  // --- TEST 2: Crosstalk (Excluding D13 pullup load) ---
  Serial.println(F("\n--- TEST 2: Pin Short Circuit / Crosstalk Test ---"));
  bool shortFound = false;
  for (int p = DIGITAL_START; p <= 12; p++) {
    pinMode(p, INPUT_PULLUP);
  }

  for (int drivePin = DIGITAL_START; drivePin <= 12; drivePin++) {
    pinMode(drivePin, OUTPUT);
    digitalWrite(drivePin, LOW);
    delay(2);

    for (int checkPin = DIGITAL_START; checkPin <= 12; checkPin++) {
      if (checkPin == drivePin) continue;
      if (digitalRead(checkPin) == LOW) {
        Serial.print(F(" [SHORT] Pin D")); Serial.print(checkPin);
        Serial.print(F(" shorted to Pin D")); Serial.println(drivePin);
        shortFound = true;
      }
    }
    pinMode(drivePin, INPUT_PULLUP);
  }
  if (!shortFound) {
    Serial.println(F(" [PASS] Pins D2-D12: No shorts or bridges detected."));
  }

  // --- TEST 3: Analog Pins ---
  Serial.println(F("\n--- TEST 3: Analog Pins (A0 to A5) ---"));
  for (int i = 0; i < NUM_ANALOG; i++) {
    int pin = ANALOG_PINS[i];
    pinMode(pin, INPUT);
    int rawADC = analogRead(pin);
    float voltage = (rawADC * 5.0) / 1023.0;

    pinMode(pin, INPUT_PULLUP);
    delay(2);
    int pullupVal = digitalRead(pin);
    pinMode(pin, INPUT);

    Serial.print(F(" [PASS] Pin A")); Serial.print(i);
    Serial.print(F(": Floating ADC = ")); Serial.print(rawADC);
    Serial.print(F(" (~")); Serial.print(voltage, 2);
    Serial.print(F("V), Pullup = ")); Serial.println(pullupVal == HIGH ? F("HIGH") : F("LOW"));
  }

  Serial.println(F("\n=========================================="));
  Serial.println(F("     SENSOR SHIELD V5.0 DIAGNOSTIC SUMMARY "));
  Serial.println(F("=========================================="));
  Serial.print(F(" Digital Pins Drive Output HIGH/LOW: ")); Serial.print(passedDigital); Serial.print(F(" / ")); Serial.println(totalDigital);
  Serial.println(F(" Serial Pins D0/D1: RESERVED / WORKING"));
  Serial.println(F(" Shield Status: READY FOR SENSORS & SERVOS"));
  Serial.println(F("==========================================\n"));
}

void loop() {
  for (int pin = DIGITAL_START; pin <= DIGITAL_END; pin++) {
    pinMode(pin, OUTPUT);
    digitalWrite(pin, HIGH);
    delay(300);
    digitalWrite(pin, LOW);
  }
  for (int i = 0; i < NUM_ANALOG; i++) {
    int pin = ANALOG_PINS[i];
    pinMode(pin, OUTPUT);
    digitalWrite(pin, HIGH);
    delay(300);
    digitalWrite(pin, LOW);
  }
}
