# 🌰 Areca Nut AI Sorting Machine — Closed-Loop Edge AI & Embedded Sorter

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![Embedded: Arduino Uno](https://img.shields.io/badge/Microcontroller-Arduino%20Uno%20%2B%20Sensor%20Shield%20V5.0-00979D?style=for-the-badge&logo=arduino)](https://www.arduino.cc/)
[![Edge AI: TFLite](https://img.shields.io/badge/Edge%20AI-TensorFlow%20Lite%20Quantized-FF6F00?style=for-the-badge&logo=tensorflow)](https://tensorflow.org/)
[![Mobile App: Flutter](https://img.shields.io/badge/Mobile-Flutter%20CameraX-02569B?style=for-the-badge&logo=flutter)](https://flutter.dev/)
[![Motor Control: L298N](https://img.shields.io/badge/Actuation-L298N%20%2B%20SG90%20Servo-E34F26?style=for-the-badge)](https://github.com)

An autonomous, real-time agricultural sorting machine that combines **on-device computer vision on a smartphone with an Arduino Uno embedded actuation system**. Developed to classify areca nuts into quality grades (healthy vs. defective/diseased/immature) and physically sort them using a motorized starwheel feeder and high-speed servo diverter gate.

---

## 📐 System Architecture & Closed-Loop Workflow

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │                                EDGE INFERENCE LAYER                             │
 │                                                                                 │
 │   ┌─────────────────┐       CameraX Feed       ┌────────────────────────────┐   │
 │   │  Areca Nut in   │ ───────────────────────> │    Flutter Mobile App      │   │
 │   │  Chute / Hopper │                          │  (Live Optical Inspection) │   │
 │   └─────────────────┘                          └─────────────┬──────────────┘   │
 │                                                              │                  │
 │                                                < 25ms Quantized TFLite Model    │
 │                                                (MobileNetV3 / Custom Binary)    │
 │                                                              │                  │
 │                                                              ▼                  │
 │                                                ┌────────────────────────────┐   │
 │                                                │ Classify: GOOD / DEFECTIVE │   │
 │                                                └─────────────┬──────────────┘   │
 └──────────────────────────────────────────────────────────────┼──────────────────┘
                                                                │
                                                Bluetooth SPP Serial Command
                                                (Target Class & Timestamp Byte)
                                                                │
 ┌──────────────────────────────────────────────────────────────┼──────────────────┐
 │                                                              ▼                  │
 │   ┌─────────────────────────────────────────────────────────────────────────┐   │
 │   │               Arduino Uno Microcontroller (Sensor Shield V5.0)          │   │
 │   │               • Non-blocking hardware timing & state engine             │   │
 │   │               • Ultrasonic distance validation (HC-SR04)                │   │
 │   └───────────────┬─────────────────────────────────────────┬───────────────┘   │
 │                   │                                         │                   │
 │       PWM Stepping Command                      Microsecond Servo Angle Pulse   │
 │                   ▼                                         ▼                   │
 │   ┌───────────────────────────────┐         ┌───────────────────────────────┐   │
 │   │ L298N Dual H-Bridge Driver    │         │ SG90 High-Speed Diverter Gate │   │
 │   │ • Starwheel Feeder Indexing   │         │ • Diverts Defective / Grade B │   │
 │   │ • Vibration Hopper Control    │         │ • Passes Premium Chali Nuts   │   │
 │   └───────────────────────────────┘         └───────────────────────────────┘   │
 │                                                                                 │
 │                                PHYSICAL ACTUATION LAYER                         │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## ⚡ Key Highlights & Engineering Depth

1. **On-Device Edge AI (< 25ms Latency):**
   - Quantized INT8/FP16 MobileNetV3 and YOLOv8n models trained on custom areca nut datasets (healthy, fungal rot, immature, split).
   - Zero-cloud dependency: inference runs entirely on the smartphone NPU/GPU via Flutter's `tflite_flutter` bindings.
2. **Synchronized Hardware Handshake:**
   - Communication via **HC-05 Bluetooth Serial (SPP)** with custom single-byte control protocols for minimal packet serialization overhead.
   - Non-blocking state machine on the Arduino Uno ensures zero motor stalls while receiving continuous optical classifications.
3. **Physical Mechanical Mechanism:**
   - **Motorized Starwheel:** Regulates nut flow into the optical inspection chamber one by one.
   - **Servo Diverter Chute:** Responds in `< 60ms` to physically deflect rejected nuts into an discard bin while letting quality yield pass through.
   - **Ultrasonic Triggering (HC-SR04):** Validates nut presence inside the chute before triggering optical evaluation.

---

## 🧰 Hardware Bill of Materials (BOM)

| Component | Specification / Purpose | Header / Pin on Sensor Shield |
| :--- | :--- | :--- |
| **Arduino Uno R3** | Primary 16 MHz ATmega328P embedded controller | Core MCU |
| **Sensor Shield V5.0** | Dedicated VCC/GND/Signal pin expansion board | Plugs onto Arduino Uno |
| **L298N Dual H-Bridge** | High-current dual DC motor driver for feeder/starwheel | Pins 8, 9 (PWM), 10, 11 |
| **SG90 Micro Servo** | High-speed directional sorting gate (0°–180°) | Digital Pin 4 (PWM) |
| **HC-05 Bluetooth** | Wireless UART serial link (38400 baud AT config / 9600 data) | RX: Pin 2 (SoftSerial TX), TX: Pin 3 (SoftSerial RX) |
| **HC-SR04 Ultrasonic** | Chute entry proximity and optical alignment check | Trig: Pin 12, Echo: Pin 13 |
| **RGB Status LED** | Real-time diagnostic state indicator (Red = Reject, Green = Pass, Blue = Standby) | Pins 5, 6, 7 |
| **12V DC Power Supply** | Independent motor rail powering L298N and starwheel | External terminal block |

---

## 📂 Repository Structure

```
arecanut-ai-sorting-machine/
├── firmware/
│   ├── L298N_Sorting_Control/
│   │   └── L298N_Sorting_Control.ino   # Main embedded control loop & state engine
│   ├── BT_AT_Config/
│   │   └── BT_AT_Config.ino            # HC-05 AT command configuration utility
│   ├── RGB_Bluetooth_Control/
│   │   └── RGB_Bluetooth_Control.ino   # Bluetooth diagnostic & LED state tester
│   ├── PinTest/
│   │   └── PinTest.ino                 # Automated Sensor Shield V5 pinout health check
│   └── ServoTest/
│       └── ServoTest.ino               # Servo sweep and calibration routine
├── mobile_app/
│   ├── pubspec.yaml                    # Flutter dependencies (camera, tflite, bluetooth)
│   ├── lib/
│   │   ├── main.dart                   # UI viewfinder, camera stream controller
│   │   └── services/
│   │       ├── classifier_service.dart # On-device TFLite model runner & image preprocessor
│   │       └── bluetooth_service.dart  # HC-05 SPP connection manager & packet emitter
│   └── assets/
│       └── labels.txt                  # Classification class definitions
├── ml_pipeline/
│   ├── train_binary_model.py           # MobileNetV3 transfer learning & quantization
│   └── train_yolo_detector.py          # YOLOv8n object detection & bounding box trainer
├── hardware/
│   └── WIRING_AND_PINOUTS.md           # Complete electrical schematic & connection table
└── README.md
```

---

## 🚀 Quick Start Guide

### 1. Flash the Arduino Controller
1. Open [`firmware/L298N_Sorting_Control/L298N_Sorting_Control.ino`](firmware/L298N_Sorting_Control/L298N_Sorting_Control.ino) in the Arduino IDE.
2. Select **Board: Arduino Uno** and the corresponding COM/USB port.
3. Install the standard `Servo` library.
4. Upload the sketch to the board.

### 2. Configure Bluetooth (HC-05)
1. Pair your Android smartphone with the `HC-05` device (default PIN: `1234` or `0000`).
2. Run `BT_AT_Config.ino` if baud rate modifications (default: 9600) are required.

### 3. Run the Flutter Edge Vision App
```bash
cd mobile_app
flutter pub get
flutter run --release
```
1. Connect to the `HC-05` module within the app.
2. Mount the smartphone onto the inspection chamber bracket over the sorting chute.
3. Power the 12V motor rail and begin continuous automated sorting.

---

## 👨‍💻 Author

**Abhay Kashyap**  
*Computer Science & Business Systems (CSBS) @ BMSCE Bangalore*  
*Specialist in Embedded Systems, Hardware-Software Integration & Edge AI*  
[GitHub Profile](https://github.com/abhay2008) • [LinkedIn](https://linkedin.com/in/)
