# 🔌 Electrical Schematics & Pinout Specification

### Board: Arduino Uno R3 with Sensor Shield V5.0

---

## 1. L298N Motor Driver Connections
| L298N Pin | Arduino / Shield Pin | Function | Notes |
| :--- | :--- | :--- | :--- |
| **ENA** | Digital Pin 9 | PWM Speed Control | Jumper removed for PWM |
| **IN1** | Digital Pin 8 | Direction Logic A | Feeder Forward |
| **IN2** | Digital Pin 10 | Direction Logic B | Feeder Reverse |
| **ENB** | Digital Pin 11 | PWM Speed Control 2 | Starwheel Speed |
| **IN3** | Digital Pin 12 | Direction Logic C | Starwheel Forward |
| **IN4** | Digital Pin 13 | Direction Logic D | Starwheel Reverse |
| **GND** | Shield GND | Common Ground | **Must share ground with Arduino** |
| **+12V** | External 12V Battery | Motor Power Rail | Powers DC geared motors |

---

## 2. SG90 Servo Diverter Gate
| Servo Wire | Sensor Shield V5 Header | Function |
| :--- | :--- | :--- |
| **Signal (Orange/Yellow)** | Digital Pin 4 (Header D4) | PWM Angular Control (0° - 180°) |
| **VCC (Red)** | Header D4 VCC (+5V) | Regulated 5V |
| **GND (Brown/Black)** | Header D4 GND | Common Ground |

---

## 3. HC-05 Bluetooth Module
| HC-05 Pin | Arduino / Shield Pin | Function | Notes |
| :--- | :--- | :--- | :--- |
| **VCC** | +5V Pin | Logic Power | |
| **GND** | GND Pin | Ground | |
| **TXD** | Digital Pin 2 (RX) | SoftwareSerial RX | Reads bytes from phone |
| **RXD** | Digital Pin 3 (TX) | SoftwareSerial TX | Optional voltage divider recommended (5V to 3.3V) |

---

## 4. RGB Diagnostic Status LED
| LED Pin | Arduino Pin | Indication State |
| :--- | :--- | :--- |
| **Red** | Digital Pin 5 | Rejected / Defective Nut Diverted |
| **Green** | Digital Pin 6 | Premium Quality Nut Passed |
| **Blue** | Digital Pin 7 | Standby / Inspection Ready |
