#include <Arduino.h>
#include <Servo.h>

/*
  ==============================================================================
  Servo Motor Hardware Diagnostic & Sweep Test
  Board: Arduino Uno with Sensor Shield V5.0
  Pin Connection: Servo Signal -> Digital Pin 4 (Header D4 on Sensor Shield)
  
  Sensor Shield Header Pinout (3-pin header on Pin 4):
    - G (Ground) -> Servo Brown / Black wire
    - V (5V Power) -> Servo Red wire
    - S (Signal) -> Servo Yellow / Orange wire
  ==============================================================================
*/

const int PIN_SERVO = 4; // Servo Signal connected to Digital Pin 4
Servo myServo;

void setup() {
  Serial.begin(115200);
  Serial.println(F("================================================"));
  Serial.println(F("       SERVO MOTOR DIAGNOSTIC TEST (PIN 4)      "));
  Serial.println(F("================================================"));

  // Attach servo object to Pin 4
  myServo.attach(PIN_SERVO);

  // Set initial position to 0 degrees
  myServo.write(0);
  delay(1000);

  Serial.println(F("Servo attached to Pin 4. Starting sweep test...\n"));
}

void loop() {
  // --- TEST 1: Smooth Sweep 0° to 180° ---
  Serial.println(F(">> [TEST 1] Smoothly sweeping from 0° to 180°..."));
  for (int angle = 0; angle <= 180; angle += 2) {
    myServo.write(angle);
    delay(15); // Controls sweep speed (~1.35 seconds total)
  }
  Serial.println(F("   Reached 180°. Holding for 1 second."));
  delay(1000);

  // --- TEST 2: Smooth Sweep 180° back to 0° ---
  Serial.println(F(">> [TEST 2] Smoothly sweeping back from 180° to 0°..."));
  for (int angle = 180; angle >= 0; angle -= 2) {
    myServo.write(angle);
    delay(15);
  }
  Serial.println(F("   Reached 0°. Holding for 1 second."));
  delay(1000);

  // --- TEST 3: Discrete Angle Jumps ---
  Serial.println(F(">> [TEST 3] Discrete Positional Jumps:"));
  
  Serial.println(F("   - Moving to Center (90°)"));
  myServo.write(90);
  delay(1000);

  Serial.println(F("   - Moving to Max (180°)"));
  myServo.write(180);
  delay(1000);

  Serial.println(F("   - Moving to Center (90°)"));
  myServo.write(90);
  delay(1000);

  Serial.println(F("   - Moving to Min (0°)"));
  myServo.write(0);
  delay(1000);

  Serial.println(F("Servo Diagnostic Cycle Complete. Pausing 2s before repeating...\n"));
  delay(2000);
}
