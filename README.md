# 🌰 Areca Nut AI Sorting Machine — Closed-Loop Edge Vision & Mechatronic Sorter

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![Embedded: Arduino Uno](https://img.shields.io/badge/Microcontroller-Arduino%20Uno%20%2B%20Sensor%20Shield%20V5.0-00979D?style=for-the-badge&logo=arduino)](https://www.arduino.cc/)
[![Edge AI: TFLite](https://img.shields.io/badge/Edge%20AI-TensorFlow%20Lite%20Quantized-FF6F00?style=for-the-badge&logo=tensorflow)](https://tensorflow.org/)
[![Mobile App: Flutter](https://img.shields.io/badge/Mobile-Flutter%20CameraX-02569B?style=for-the-badge&logo=flutter)](https://flutter.dev/)
[![Motor Control: L298N](https://img.shields.io/badge/Actuation-L298N%20Dual%20H--Bridge-E34F26?style=for-the-badge)](https://github.com)
[![Actuator: SG90](https://img.shields.io/badge/Deflector-SG90%20High--Speed%20Servo-4CAF50?style=for-the-badge)](https://github.com)

An autonomous, closed-loop agricultural grading and sorting machine engineered to solve the bottleneck of manual areca nut inspection. The system integrates **on-device edge computer vision on a smartphone with custom Arduino embedded mechatronics**, featuring a motorized **starwheel singulation feeder**, a **micro-vibrational step-down conveyor**, and a **high-speed multi-angle servo diverter gate**.

---

## 📐 End-to-End System Architecture

```
 ┌─────────────────────────────────────────────────────────────────────────────────────────┐
 │                                   EDGE COMPUTER VISION LAYER                            │
 │                                                                                         │
 │   ┌───────────────────────────┐      CameraX Stream      ┌──────────────────────────┐   │
 │   │ Optical Chamber (Areca    │ ───────────────────────> │ Flutter Edge Vision App  │   │
 │   │ Nut Indexed by Starwheel) │                          │ (Live Camera Viewfinder) │   │
 │   └───────────────────────────┘                          └────────────┬─────────────┘   │
 │                                                                       │                 │
 │                                                         < 25ms Quantized TFLite Model   │
 │                                                         (MobileNetV3 / YOLOv8n INT8)    │
 │                                                                       │                 │
 │                                                                       ▼                 │
 │                                                          Grade Classification Result:   │
 │                                                          ['1'=Reject, '2'=B, '3'=Std,   │
 │                                                           '4'=Chali Premium, '8'=Jam]   │
 │                                                                       │                 │
 └───────────────────────────────────────────────────────────────────────┼─────────────────┘
                                                                         │
                                                   Bluetooth SPP (HC-05) Serial Link
                                                   Single-Byte Payload @ 9600 Baud
                                                                         │
 ┌───────────────────────────────────────────────────────────────────────┼─────────────────┐
 │                                                                       ▼                 │
 │   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
 │   │                  Arduino Uno R3 + Sensor Shield V5.0 Controller                 │   │
 │   │            • Non-blocking hardware timers & multi-state machine loops           │   │
 │   │            • Real-time RGB LED state diagnostics & ultrasonic sync              │   │
 │   └───────────────────┬─────────────────────────────┬───────────────────────────┬───┘   │
 │                       │                             │                           │       │
 │            Forward/Reverse Pulsing          Step-Down PWM (255->0)        Microsecond   │
 │              Anti-Jam State Engine          Vibrational Alignment        Angular Pulse  │
 │                       │                             │                           │       │
 │                       ▼                             ▼                           ▼       │
 │             ┌───────────────────┐         ┌───────────────────┐       ┌─────────────┐   │
 │             │  Motor A (L298N)  │         │  Motor B (L298N)  │       │ SG90 Servo  │   │
 │             │ Starwheel Feeder  │         │ Step-Down Conveyor│       │ Diverter    │   │
 │             │ (Nut Singulator)  │         │ (Linear Vibrator) │       │ (4 Chutes)  │   │
 │             └───────────────────┘         └───────────────────┘       └─────────────┘   │
 │                                                                                         │
 │                                     PHYSICAL MECHATRONIC LAYER                          │
 └─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## ⚙️ Core Mechatronic Innovations

### 1. Starwheel Singulation & Anti-Jam State Machine
Bulk areca nuts have irregular geometries and fibrous husks, making them prone to bridging and clogging at hopper throats. 

To achieve **100% individual nut singulation**, the Starwheel driver implements a **5-stage non-blocking cycle** in [`firmware/L298N_Sorting_Control/L298N_Sorting_Control.ino`](firmware/L298N_Sorting_Control/L298N_Sorting_Control.ino):

```
┌─────────────┐  2000ms   ┌───────────────┐   60ms burst   ┌─────────────┐
│  SW_DELAY   │ ────────> │  SW_FORWARD   │ ─────────────> │   SW_WAIT   │
└─────────────┘           └───────────────┘                └──────┬──────┘
       ▲                                                          │ 30ms inertia pause
       │ 3000ms optical inspection gap                            ▼
┌──────┴──────┐            30ms micro-reverse pulse        ┌─────────────┐
│   SW_REST   │ <───────────────────────────────────────── │ SW_REVERSE  │
└─────────────┘   (Relieves mechanical throat tension)     └─────────────┘
```

- **Forward Index Pulse (`SW_FORWARD`):** `60ms` high-torque burst rotates the starwheel pocket precisely one unit.
- **Inertia Stabilization (`SW_WAIT`):** `30ms` pause eliminates mechanical bounce.
- **Micro-Reverse Throat Agitation (`SW_REVERSE`):** `30ms` reverse pulse immediately relieves mechanical tension, clearing neighboring trapped nuts.
- **Optical Window (`SW_REST`):** `3000ms` window allows camera inference, servo positioning, and physical nut drop.
- **Emergency Anti-Jam Override (`SW_ANTI_JAM`):** Signal `'8'` from mobile app triggers a high-torque 50ms reverse pulse to dislodge foreign obstructions.

---

### 2. Conveyor Step-Down PWM & Micro-Vibrational Alignment
The feed conveyor uses an engineered **staircase PWM duty-cycle curve** to create micro-vibrations that linearly orient the nuts along the centerline without flipping them:
- `CB_KICKSTART`: `255 PWM` (100ms) to overcome motor static friction.
- `CB_190` $\rightarrow$ `CB_150` $\rightarrow$ `CB_120`: Progressive 30ms stepped deceleration.
- `CB_STOP`: `25ms` zero-power rest before looping back to `190 PWM`.

This continuous PWM ramping generates micro-vibration harmonics that smoothly feed individual nuts toward the optical inspection lens.

---

### 3. Multi-Angle High-Speed Servo Diverter (4 Quality Grades)
When the on-device TFLite model classifies a nut, the mobile app transmits a single-byte command over Bluetooth SPP. The Arduino positions the **SG90 servo diverter gate** and updates the RGB status LED:

| Signal Byte | Nut Quality Grade | Servo Angle | RGB State | Physical Destination |
| :---: | :--- | :---: | :---: | :--- |
| `'1'` | **Reject / Defective** *(Fungal rot, cracked, diseased)* | **0°** | 🔴 Solid Red | Bin A (Discard / Industrial Byproduct) |
| `'2'` | **Grade B / Commercial** *(Immature, partial husk)* | **60°** | 🟢 Solid Green | Bin B (Secondary Processing) |
| `'3'` | **Standard Commercial** *(Matured, uniform cut)* | **120°** | 🔵 Solid Blue | Bin C (Standard Retail Market) |
| `'4'` | **Premium Chali** *(Highest density, flawless)* | **180°** | ⚪ Solid White | Bin D (Premium Export Grade) |
| `'5'` | **Emergency Stop** | — | — | Kills all motors & conveyor rails |
| `'6'` | **Resume System** | — | — | Re-initializes starwheel & conveyor cycles |
| `'7'` | **Manual Index Burst** | — | — | Forces 1 starwheel forward step |
| `'8'` | **Anti-Jam Reverse** | — | — | 50ms reverse torque burst |

---

## 🔬 Edge AI & Computer Vision Pipeline

1. **Dataset & Classes:**
   - Custom-curated optical dataset of areca nuts categorized into healthy Chali, Bette, diseased/black rot, and immature green nuts.
2. **Model Architecture:**
   - **MobileNetV3-Small:** Optimized transfer learning backbone with global average pooling and dropout.
   - **Quantization:** Fully quantized INT8 / FP16 TFLite model (`arecanut_model_quantized.tflite`) resulting in a tiny `< 2.5 MB` binary footprint.
   - **Inference Speed:** **< 22ms** per frame on standard Android / ARM NPUs, enabling real-time classification at 30+ FPS.
3. **Cross-Platform Mobile Client (`mobile_app`):**
   - Built with **Flutter & CameraX** for high-throughput frame streaming.
   - Integrated Bluetooth SPP service (`flutter_bluetooth_serial`) with automatic reconnection and keep-alive heartbeats.

---

## 🧰 Electrical Pinout & Wiring Specification

### Controller: Arduino Uno R3 + Sensor Shield V5.0

| Component | Pin / Header | Function | Connection Details |
| :--- | :--- | :--- | :--- |
| **L298N ENA** | Digital Pin 9 (PWM) | Starwheel Speed Control | Jumper removed; connected to PWM D9 |
| **L298N IN1** | Digital Pin 8 | Starwheel Direction Logic A | Forward indexing |
| **L298N IN2** | Digital Pin 10 | Starwheel Direction Logic B | Anti-jam reverse |
| **L298N ENB** | Digital Pin 11 (PWM) | Conveyor Speed PWM | Step-down vibrational control |
| **L298N IN3** | Digital Pin 12 | Conveyor Direction Logic A | Continuous forward feed |
| **L298N IN4** | Digital Pin 13 | Conveyor Direction Logic B | Ground reference |
| **SG90 Servo** | Digital Pin 4 (PWM) | Diverter Gate Deflection | Signal to Header D4 on Sensor Shield |
| **HC-05 RX** | Digital Pin 2 (SoftSerial TX)| Bluetooth Data Link | SoftwareSerial communication |
| **HC-05 TX** | Digital Pin 3 (SoftSerial RX)| Bluetooth Data Link | Reads mobile classification bytes |
| **RGB LED (R)** | Digital Pin 5 | Red Status Channel | Common Anode (LOW = ON) |
| **RGB LED (G)** | Digital Pin 6 | Green Status Channel | Common Anode (LOW = ON) |
| **RGB LED (B)** | Digital Pin 7 (PWM) | Blue Status Channel | Smooth brightness modulation |

---

## 📂 Repository File Tree

```
arecanut-ai-sorting-machine/
├── firmware/
│   ├── L298N_Sorting_Control/
│   │   └── L298N_Sorting_Control.ino   # Complete starwheel, conveyor, servo, and BT engine
│   ├── BT_AT_Config/
│   │   └── BT_AT_Config.ino            # HC-05 AT command & baud-rate configuration tool
│   ├── RGB_Bluetooth_Control/
│   │   └── RGB_Bluetooth_Control.ino   # Diagnostic RGB color fade & Bluetooth receiver
│   ├── PinTest/
│   │   └── PinTest.ino                 # Diagnostic sketch validating Sensor Shield V5 headers
│   └── ServoTest/
│       └── ServoTest.ino               # Servo sweep and calibration routine
├── mobile_app/
│   ├── pubspec.yaml                    # Flutter dependencies (CameraX, TFLite, Bluetooth)
│   ├── lib/
│   │   ├── main.dart                   # Camera viewfinder UI, status monitors, manual overrides
│   │   └── services/
│   │       ├── classifier_service.dart # On-device TFLite runner & image normalization
│   │       └── bluetooth_service.dart  # Bluetooth SPP connection & byte emitter
│   └── assets/
│       └── labels.txt                  # 4-grade classification labels
├── ml_pipeline/
│   ├── train_binary_model.py           # MobileNetV3 training and TFLite INT8 quantization
│   └── train_yolo_detector.py          # YOLOv8n object detection & spatial locator
├── hardware/
│   └── WIRING_AND_PINOUTS.md           # Full electrical schematic & voltage rail map
└── README.md
```

---

## 🚀 Getting Started

### 1. Hardware Assembly & Flashing
1. Mount the **Sensor Shield V5.0** onto the **Arduino Uno R3**.
2. Wire the L298N dual H-bridge motor driver, SG90 servo, HC-05 Bluetooth module, and RGB LED according to [`hardware/WIRING_AND_PINOUTS.md`](hardware/WIRING_AND_PINOUTS.md).
3. Connect an external **12V DC power supply** to the L298N power terminal block (ensure common ground with Arduino GND).
4. Open [`firmware/L298N_Sorting_Control/L298N_Sorting_Control.ino`](firmware/L298N_Sorting_Control/L298N_Sorting_Control.ino) in Arduino IDE and upload to the board.

### 2. Mobile App Setup
```bash
cd mobile_app
flutter pub get
flutter run --release
```
1. Pair your mobile device with `HC-05` (default PIN: `1234`).
2. Mount the smartphone onto the overhead optical inspection bracket above the conveyor drop point.
3. Tap **Connect HC-05** in the app and start automated sorting.

---

## 👨‍💻 Author

**Abhay Kashyap**  
*Computer Science & Business Systems (CSBS) @ BMSCE Bangalore*  
*Specialist in Embedded Systems, Hardware-Software Integration & Edge AI*  
[GitHub Profile](https://github.com/abhay2008) • [LinkedIn](https://linkedin.com/in/)
