#include <Arduino.h>
#include <Servo.h>
#include <SoftwareSerial.h>

/*
  ==============================================================================
  L298N Dual Motor + Servo + RGB LED + Bluetooth (Non-Blocking)
  
  Motor A - Starwheel (OUT1 & OUT2):
    - ENA -> Pin 9 (PWM) | IN1 -> Pin 8 | IN2 -> Pin 4
  Motor B - Conveyor (OUT3 & OUT4):
    - ENB -> Pin 6 (PWM) | IN3 -> Pin 3 | IN4 -> Pin 7
  Servo:
    - Signal -> Pin A5
  RGB LED (Common Cathode assumed):
    - Red -> Pin 13 (Digital)
    - Green -> Pin 12 (Digital)
    - Blue -> Pin 5 (PWM)
  Bluetooth:
    - RXD -> Pin 10
    - TXD -> Pin 11
  ==============================================================================
*/

// --- Pins ---
const int enA = 9;
const int in1 = 8;
const int in2 = 4;

const int enB = 6;
const int in3 = 3;
const int in4 = 7;

const int servoPin = A5; 

const int pinR = 13;
const int pinG = 12;
const int pinB = 5;

// Bluetooth pins
SoftwareSerial bt(10, 11);

// --- Timing Configurations ---
const unsigned long FORWARD_BURST_MS  = 25;
const unsigned long WAIT_PAUSE_MS     = 100;
const unsigned long REVERSE_BURST_MS  = 15;
const unsigned long REST_GAP_MS       = 3000; // Increased to 3 seconds

// --- State Variables ---
bool motorsActive = true; // Starts ON automatically

// Starwheel State Machine
enum StarwheelState { SW_DELAY, SW_FORWARD, SW_WAIT, SW_REVERSE, SW_REST, SW_ANTI_JAM };
StarwheelState swState = SW_DELAY; // Start in delay mode
unsigned long swStateStartTime = 0;

// RGB LED State Machine
enum RGBMode { RGB_OFF, RGB_SOLID, RGB_FADE };
RGBMode rgbMode = RGB_OFF;
unsigned long fadeStartTime = 0;
unsigned long lastFadeUpdate = 0;
unsigned long rgbSolidStartTime = 0; // Added for the 1.5s timeout
int fadePhase = 0; 
int fadeState = 0;

// Conveyor State Machine
enum ConveyorState { CB_KICKSTART, CB_190, CB_150, CB_120, CB_STOP };
ConveyorState cbState = CB_KICKSTART;
unsigned long cbStateStartTime = 0;

// Servo Object
Servo myServo;

void setRGB(int r, int g, int b) {
  // Common Anode Logic (LOW = ON, HIGH/255 = OFF)
  digitalWrite(pinR, r > 127 ? LOW : HIGH);
  digitalWrite(pinG, g > 127 ? LOW : HIGH);
  analogWrite(pinB, 255 - b);
}

void stopAllMotors() {
  digitalWrite(enA, LOW); digitalWrite(in1, LOW); digitalWrite(in2, LOW);
  analogWrite(enB, 0); digitalWrite(in3, LOW); digitalWrite(in4, LOW);
}

void setup() {
  Serial.begin(115200);
  bt.begin(9600);
  
  Serial.println(F("================================================"));
  Serial.println(F(" STARWHEEL + CONVEYOR + SERVO + RGB + BT      "));
  Serial.println(F("================================================"));
  
  pinMode(enA, OUTPUT); pinMode(in1, OUTPUT); pinMode(in2, OUTPUT);
  pinMode(enB, OUTPUT); pinMode(in3, OUTPUT); pinMode(in4, OUTPUT);
  pinMode(pinR, OUTPUT); pinMode(pinG, OUTPUT); pinMode(pinB, OUTPUT);
  
  setRGB(0, 0, 0);
  stopAllMotors();
  
  myServo.attach(servoPin);
  myServo.write(0);
  
  Serial.println(F("Starting immediately..."));
  
  // Conveyor starts immediately
  digitalWrite(in3, HIGH);
  digitalWrite(in4, LOW);
  analogWrite(enB, 255);
  
  swStateStartTime = millis();
  cbStateStartTime = millis();
}

void loop() {
  unsigned long currentMillis = millis();
  
  // --- 0. Read Bluetooth or Serial Input ---
  char c = '\0';
  if (bt.available()) {
    c = bt.read();
  } else if (Serial.available()) {
    c = Serial.read();
  }
  
  // --- 1. RGB Transition & Timeout Logic ---
  if (rgbMode == RGB_SOLID) {
    if (currentMillis - rgbSolidStartTime >= 1500) {
      rgbMode = RGB_OFF;
      setRGB(0, 0, 0);
      Serial.println(F("RGB: Solid Timeout (1.5s)"));
    }
  } else if (rgbMode == RGB_FADE) {
    if (currentMillis - fadeStartTime >= 3000) {
      rgbMode = RGB_OFF;
      setRGB(0, 0, 0); // Turn off after 3 seconds
      Serial.println(F("RGB: Transition Completed"));
    } else if (currentMillis - lastFadeUpdate >= 100) { // Cycle fast (disco) because of no PWM
      lastFadeUpdate = currentMillis;
      fadePhase++;
      if (fadePhase > 2) fadePhase = 0;
      
      if (fadePhase == 0) setRGB(255, 0, 0); // Red
      else if (fadePhase == 1) setRGB(0, 255, 0); // Green
      else if (fadePhase == 2) setRGB(0, 0, 255); // Blue
    }
  }
  
  if (c != '\0') {
    if (c == '1') { 
      rgbMode = RGB_SOLID; 
      rgbSolidStartTime = currentMillis;
      setRGB(255, 0, 0); 
      myServo.write(0); 
    }
    else if (c == '2') { 
      rgbMode = RGB_SOLID; 
      rgbSolidStartTime = currentMillis;
      setRGB(0, 255, 0); 
      myServo.write(60); 
    }
    else if (c == '3') { 
      rgbMode = RGB_SOLID; 
      rgbSolidStartTime = currentMillis;
      setRGB(0, 0, 255); 
      myServo.write(120); 
    }
    else if (c == '4') { 
      rgbMode = RGB_SOLID; 
      rgbSolidStartTime = currentMillis;
      setRGB(255, 255, 255); 
      myServo.write(180); 
    }
    
    else if (c == '5') {
      // Signal 5: STOP
      motorsActive = false;
      stopAllMotors();
      Serial.println(F("Signal 5: MOTORS STOPPED"));
    }
    
    else if (c == '6') {
      // Signal 6: RESUME
      if (!motorsActive) {
        motorsActive = true;
        // Reset conveyor to kickstart
        cbState = CB_KICKSTART;
        cbStateStartTime = currentMillis;
        digitalWrite(in3, HIGH);
        digitalWrite(in4, LOW);
        analogWrite(enB, 255);
        
        // Reset starwheel to delay mode
        swState = SW_DELAY;
        swStateStartTime = currentMillis;
        Serial.println(F("Signal 6: MOTORS RESUMED (Starwheel waiting 2s)"));
      }
    }
    
    else if (c == '7') {
      // Signal 7: MANUAL STARWHEEL BURST
      motorsActive = true; // Ensure motors are active
      
      // Ensure conveyor is running if it was stopped
      if (cbState == CB_STOP) {
         cbState = CB_190; // Don't kickstart aggressively if it's just asleep
         analogWrite(enB, 190);
      }
      
      // Force Starwheel into Forward immediately
      swState = SW_FORWARD;
      swStateStartTime = currentMillis;
      digitalWrite(in1, HIGH);
      digitalWrite(in2, LOW);
      digitalWrite(enA, HIGH);
      Serial.println(F("Signal 7: MANUAL STARWHEEL PULSE"));
    }
    
    else if (c == '8') {
      // Signal 8: ANTI-JAM
      motorsActive = true; 
      swState = SW_ANTI_JAM;
      swStateStartTime = currentMillis;
      digitalWrite(in1, LOW);
      digitalWrite(in2, HIGH);
      digitalWrite(enA, HIGH); // Full power reverse
      Serial.println(F("Signal 8: ANTI-JAM REVERSE PULSE (50ms)"));
    }
  }

  if (!motorsActive) return; // Skip motor updates if stopped
  
  // --- 1. Starwheel State Machine ---
  switch (swState) {
    case SW_DELAY:
      // Wait 2 seconds before starting the first pulse
      if (currentMillis - swStateStartTime >= 2000) {
        digitalWrite(in1, HIGH);
        digitalWrite(in2, LOW);
        digitalWrite(enA, HIGH);
        swState = SW_FORWARD;
        swStateStartTime = currentMillis;
      }
      break;
    case SW_FORWARD:
      if (currentMillis - swStateStartTime >= FORWARD_BURST_MS) {
        digitalWrite(enA, LOW);
        swState = SW_WAIT;
        swStateStartTime = currentMillis;
      }
      break;
    case SW_WAIT:
      if (currentMillis - swStateStartTime >= WAIT_PAUSE_MS) {
        digitalWrite(in1, LOW);
        digitalWrite(in2, HIGH);
        digitalWrite(enA, HIGH);
        swState = SW_REVERSE;
        swStateStartTime = currentMillis;
      }
      break;
    case SW_REVERSE:
      if (currentMillis - swStateStartTime >= REVERSE_BURST_MS) {
        digitalWrite(enA, LOW);
        digitalWrite(in1, LOW);
        digitalWrite(in2, LOW); 
        swState = SW_REST;
        swStateStartTime = currentMillis;
      }
      break;
    case SW_REST:
      // Wait 3 seconds before next pulse
      if (currentMillis - swStateStartTime >= REST_GAP_MS) {
        digitalWrite(in1, HIGH);
        digitalWrite(in2, LOW);
        digitalWrite(enA, HIGH);
        swState = SW_FORWARD;
        swStateStartTime = currentMillis;
      }
      break;
    case SW_ANTI_JAM:
      if (currentMillis - swStateStartTime >= 50) { // 50ms pulse
        digitalWrite(enA, LOW);
        digitalWrite(in1, LOW);
        digitalWrite(in2, LOW); 
        swState = SW_REST; // Rest for 3s before trying forward again
        swStateStartTime = currentMillis;
      }
      break;
  }
  
  // --- 2. Conveyor State Machine ---
  switch (cbState) {
    case CB_KICKSTART:
      if (currentMillis - cbStateStartTime >= 100) {
        analogWrite(enB, 190);
        cbState = CB_190;
        cbStateStartTime = currentMillis;
      }
      break;
    case CB_190:
      if (currentMillis - cbStateStartTime >= 30) {
        analogWrite(enB, 150);
        cbState = CB_150;
        cbStateStartTime = currentMillis;
      }
      break;
    case CB_150:
      if (currentMillis - cbStateStartTime >= 30) {
        analogWrite(enB, 120);
        cbState = CB_120;
        cbStateStartTime = currentMillis;
      }
      break;
    case CB_120:
      if (currentMillis - cbStateStartTime >= 30) {
        analogWrite(enB, 0); // Stop
        cbState = CB_STOP;
        cbStateStartTime = currentMillis;
      }
      break;
    case CB_STOP:
      if (currentMillis - cbStateStartTime >= 25) {
        analogWrite(enB, 190); // Restart from 190
        cbState = CB_190;
        cbStateStartTime = currentMillis;
      }
      break;
  }
}
