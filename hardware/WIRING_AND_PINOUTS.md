# 🔌 Electrical Schematics & Pinout Specification

### Controller: Arduino Uno R3 with Sensor Shield V5.0

---

## 1. L298N Dual H-Bridge Motor Driver Connections
| L298N Terminal / Pin | Arduino Uno Pin | Subsystem | Function / Role |
| :--- | :--- | :--- | :--- |
| **ENA** | Digital Pin 9 (PWM) | Motor A (Starwheel Feeder) | High-speed forward/reverse indexing bursts |
| **IN1** | Digital Pin 8 | Motor A (Starwheel Feeder) | Forward rotation logic |
| **IN2** | Digital Pin 4 | Motor A (Starwheel Feeder) | Reverse micro-agitation & anti-jam logic |
| **ENB** | Digital Pin 6 (PWM) | Motor B (Conveyor Belt) | Step-down vibrational PWM speed ramping |
| **IN3** | Digital Pin 3 | Motor B (Conveyor Belt) | Forward conveyor feed logic |
| **IN4** | Digital Pin 7 | Motor B (Conveyor Belt) | Direction reference logic |
| **GND** | Arduino GND | Power Ground | **Common ground shared with Arduino & 12V supply** |
| **+12V** | External 12V DC Supply | Motor Rail | High-torque DC geared motor power |

---

## 2. SG90 High-Speed Diverter Servo
| Servo Lead | Arduino Pin / Header | Function |
| :--- | :--- | :--- |
| **Signal (Orange/Yellow)** | Analog Pin A5 (Header A5) | PWM Angle Deflection (0° to 180°) |
| **VCC (+5V Red)** | Sensor Shield +5V Header | Regulated 5V Rail |
| **GND (Brown/Black)** | Sensor Shield GND Header | Ground Reference |

---

## 3. HC-05 Bluetooth SPP Module
| HC-05 Pin | Arduino Pin | Subsystem | Notes |
| :--- | :--- | :--- | :--- |
| **RXD** | Digital Pin 10 | SoftwareSerial RX | Receives sorting bytes from mobile camera client |
| **TXD** | Digital Pin 11 | SoftwareSerial TX | Status & telemetry output |
| **VCC** | +5V Pin | Logic Power | Regulated 5V supply |
| **GND** | GND Pin | Ground | Common system ground |

---

## 4. RGB Diagnostic Status LED (Common Anode)
| LED Pin | Arduino Pin | Indication State | Sorting Grade |
| :--- | :--- | :--- | :--- |
| **Red (R)** | Digital Pin 13 | Solid Red (0°) | **Gorabalu** (Immature / raw whole dried nut) |
| **Green (G)** | Digital Pin 12 | Solid Green (60°) | **Gootu / Goto / Bette** (Medium-grade processed nut) |
| **Blue (B)** | Digital Pin 5 (PWM) | Solid Blue (120°) | **Rashi Edi** (Tender boiled whole nut - prime market grade) |
| **White (R+G+B)**| Pins 13, 12, 5 | Solid White (180°) | **Hasa** (Premium husked / select tender grade) |
