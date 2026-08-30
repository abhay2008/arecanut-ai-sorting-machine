#include <Arduino.h>
#include <SoftwareSerial.h>

/*
  ==============================================================================
  HC-05 / HC-06 Bluetooth AT Command & Password Configurator
  ==============================================================================
  
  Connections (Same as before on Sensor Shield V5):
    - BT TXD -> Arduino Pin 10 (SoftwareSerial RX)
    - BT RXD -> Arduino Pin 11 (SoftwareSerial TX)
    - BT VCC -> 5V
    - BT GND -> GND
    
  How to enter AT mode on HC-05:
    1. Unplug Arduino power (or disconnect 5V wire from BT module).
    2. Hold down the small tiny button on the HC-05 module (near EN/KEY pin).
    3. Plug Arduino power back in while holding the button.
    4. The onboard LED on HC-05 will blink SLOWLY (once every 2 seconds).
       This indicates it is in AT Command Mode (38400 baud).

  For HC-06:
    - If the red LED on HC-06 is blinking fast (not paired), it is ALREADY in AT mode (9600 baud).
  ==============================================================================
*/

const int BT_RX_PIN = 10;
const int BT_TX_PIN = 11;

SoftwareSerial btSerial(BT_RX_PIN, BT_TX_PIN);

void setup() {
  Serial.begin(115200);
  while (!Serial) { ; }
  delay(1000);

  Serial.println(F("=================================================="));
  Serial.println(F("   HC-05 / HC-06 BLUETOOTH AT COMMAND CONFIGURATOR"));
  Serial.println(F("=================================================="));

  // Try 38400 first (Default AT mode speed for HC-05)
  btSerial.begin(38400);

  Serial.println(F("1. Attempting AT ping at 38400 baud (HC-05 AT mode)..."));
  btSerial.print("AT\r\n");
  delay(500);

  bool responded = false;
  while (btSerial.available()) {
    char c = btSerial.read();
    Serial.write(c);
    responded = true;
  }

  if (!responded) {
    Serial.println(F("\nNo response at 38400. Trying 9600 baud (HC-06 / default mode)..."));
    btSerial.begin(9600);
    btSerial.print("AT\r\n");
    btSerial.print("AT\r");
    btSerial.print("AT");
    delay(500);

    while (btSerial.available()) {
      char c = btSerial.read();
      Serial.write(c);
    }
  }

  Serial.println(F("\n\n=================================================="));
  Serial.println(F("  SERIAL PASSTHROUGH READY"));
  Serial.println(F("  Select 'Both NL & CR' at 115200 in Serial Monitor"));
  Serial.println(F("  Common AT Commands:"));
  Serial.println(F("    AT            -> Test connection (Returns OK)"));
  Serial.println(F("    AT+PSWD?      -> Query password (HC-05)"));
  Serial.println(F("    AT+PSWD=\"1234\" -> Set password to 1234 (HC-05)"));
  Serial.println(F("    AT+PIN1234    -> Set password to 1234 (HC-06)"));
  Serial.println(F("    AT+NAME?      -> Query module name"));
  Serial.println(F("==================================================\n"));
}

void loop() {
  // Read from Bluetooth module and send to Serial Monitor
  if (btSerial.available()) {
    Serial.write(btSerial.read());
  }

  // Read from Serial Monitor and send to Bluetooth module
  if (Serial.available()) {
    btSerial.write(Serial.read());
  }
}
