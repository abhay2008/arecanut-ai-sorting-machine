# 🌰 Automated Arecanut AI Sorting Machine

### *Edge AI Optical Sorter & Physical Grading Machine for Malnad Arecanut Varieties*

[![BMSCE Undergrad](https://img.shields.io/badge/1st_Year_Undergrad-CSBS_%40_BMSCE-00f0ff?style=for-the-badge)](https://bmsce.ac.in)
[![Target R&D](https://img.shields.io/badge/Target_R%26D-MAMCOS_%26_NAMCOS-orange?style=for-the-badge)](https://mamcos.in)
[![Inference Latency](https://img.shields.io/badge/Edge_AI-<22ms_TFLite-10B981?style=for-the-badge)](ml_pipeline/run_pipeline.py)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](LICENSE)

---

## 📖 Overview

The **Automated Arecanut AI Sorting Machine** is a working engineering prototype designed to automate the classification and physical separation of areca nuts (*Areca catechu*) cultivated and processed across Karnataka's **Malnad region** (Shivamogga, Thirthahalli, Channagiri, Sagar, Sirsi, Sringeri).

In traditional Malnad arecanut processing, grading is performed through manual hand-picking—a slow, labor-intensive, and subjective bottleneck that limits processing throughput during harvest seasons. 

This project bridges **edge computer vision (Dual-Stream MobileNetV3 + Dynamic Texture Attention)** with **embedded mechatronics (Arduino Uno + L298N + Starwheel Feeder + Conveyor + Servo Diverter)** to automatically inspect, classify, and physically channel nuts into 4 distinct commercial quality bins in real time.

> [!IMPORTANT]
> **Industrial R&D & Commercial Roadmap:**  
> This prototype has been developed as an applied engineering project with plans to collaborate with major regional marketing and processing cooperatives—including **MAMCOS** (*The Malnad Areca Marketing Cooperative Society Ltd.*, Shivamogga) and **NAMCOS / TSS** (*North Kanara / Nyamathi Areca Marketing Cooperative Societies*)—for further industrial scaling, high-speed multi-lane vibration feeders, and factory-floor deployment.

---

## 🌴 The 4 Malnad Arecanut Varieties Classified

The system is trained and mechanically calibrated for the 4 canonical processed commercial varieties of the Malnad belt:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       MALNAD ARECANUT VARIETIES                             │
├──────────────┬──────────────┬───────────────────┬─────────────┬─────────────┤
│ Variety Name │ Signal / Bin │ Visual & Physical │ Market Role │ Diverter    │
│              │              │ Characteristics   │ & Quality   │ Servo Angle │
├──────────────┼──────────────┼───────────────────┼─────────────┼─────────────┤
│ 1. Gorabalu  │  Signal '1'  │ Whole dry raw nut │ Secondary / │     0°      │
│              │   (Red LED)  │ Immature or dried │ Commercial  │             │
├──────────────┼──────────────┼───────────────────┼─────────────┼─────────────┤
│ 2. Gootu     │  Signal '2'  │ Rounded processed │ Standard    │    60°      │
│    (Goto)    │  (Green LED) │ nut / medium grade│ Commercial  │             │
├──────────────┼──────────────┼───────────────────┼─────────────┼─────────────┤
│ 3. Rashi Edi │  Signal '3'  │ Tender boiled and │ Prime High- │   120°      │
│  (Rashi Idi) │  (Blue LED)  │ dried whole nut   │ Volume Grade│             │
├──────────────┼──────────────┼───────────────────┼─────────────┼─────────────┤
│ 4. Hasa      │  Signal '4'  │ Premium husked,   │ Top Export  │   180°      │
│              │  (White LED) │ select tender cut │ Grade       │             │
└──────────────┴──────────────┴───────────────────┴─────────────┴─────────────┘
```

---

## 🏛️ System Architecture

```
                  ┌────────────────────────────────────────┐
                  │    OVERHEAD SMARTPHONE CAMERA CLIENT   │
                  │   Flutter + CameraX + TFLite (<22ms)   │
                  └───────────────────┬────────────────────┘
                                      │ Bluetooth SPP (9600 Baud)
                                      │ Signals: '1', '2', '3', '4'
                                      ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                            ARDUINO UNO R3 CONTROLLER                                 │
│  Non-Blocking State Machine • Step-Down PWM Conveyor • Tension-Relieving Starwheel   │
└──────┬──────────────────────────────┬──────────────────────────────┬─────────────────┘
       │                              │                              │
       │ PWM D9, D8, D4               │ PWM D6, D3, D7               │ Pin A5
       ▼                              ▼                              ▼
┌──────────────┐              ┌──────────────┐               ┌──────────────┐
│  MOTOR A     │              │  MOTOR B     │               │  SG90 SERVO  │
│  Starwheel   │              │  Conveyor    │               │  Diverter    │
│  Feeder      │              │  Step-Down   │               │  Gate        │
└──────────────┘              └──────────────┘               └──────────────┘
```

---

## ⚙️ Mechanical & Firmware Engineering

### 1. Starwheel Feeder Anti-Jam State Machine
To prevent nut jamming and ensure exact single-nut dispensing onto the inspection conveyor, the starwheel feeder runs a non-blocking asynchronous state cycle:

```
┌──────────────┐       25ms high-torque burst      ┌─────────────┐
│  SW_FORWARD  │ ────────────────────────────────> │   SW_WAIT   │
└──────────────┘                                   └──────┬──────┘
       ▲                                                  │ 100ms inertia pause
       │ 3000ms optical inspection gap                    ▼
┌──────┴──────┐          15ms micro-reverse pulse  ┌─────────────┐
│   SW_REST   │ <───────────────────────────────── │ SW_REVERSE  │
└─────────────┘   (Relieves mechanical throat)     └─────────────┘
```

* **Forward Indexing (`SW_FORWARD`):** `25ms` burst indexes one nut pocket.
* **Inertia Stabilization (`SW_WAIT`):** `100ms` pause eliminates motor overshoot.
* **Micro-Reverse Throat Agitation (`SW_REVERSE`):** `15ms` reverse pulse relieves throat tension and dislodges double-fed nuts.
* **Optical Inspection Rest (`SW_REST`):** `3000ms` gap allows live CameraX inference, Bluetooth transmission, and servo positioning.
* **Emergency Anti-Jam Override (`SW_ANTI_JAM`):** Signal `'8'` triggers a full-torque `50ms` reverse pulse to clear blockages.

### 2. Conveyor Step-Down PWM & Micro-Vibrational Alignment
The feed conveyor utilizes a **staircase PWM duty-cycle curve** to create micro-vibrations that linearly orient the nuts along the centerline:
* `CB_KICKSTART`: `255 PWM` (100ms) to overcome motor static friction.
* `CB_190` $\rightarrow$ `CB_150` $\rightarrow$ `CB_120`: Progressive 30ms stepped deceleration.
* `CB_STOP`: `25ms` zero-power rest before looping back to `190 PWM`.

### 3. High-Speed 4-Grade Servo Diverter
Upon classification, the Arduino routes the nut via an **SG90 servo diverter gate** and updates the RGB status LED:

| Signal Byte | Grade Variety | Servo Angle | RGB State | Physical Action |
| :---: | :--- | :---: | :---: | :--- |
| `'1'` | **Gorabalu** | **0°** | 🔴 Solid Red (1.5s) | Channeled to Bin 1 |
| `'2'` | **Gootu (Goto / Bette)** | **60°** | 🟢 Solid Green (1.5s) | Channeled to Bin 2 |
| `'3'` | **Rashi Edi (Rashi Idi)** | **120°** | 🔵 Solid Blue (1.5s) | Channeled to Bin 3 |
| `'4'` | **Hasa** | **180°** | ⚪ Solid White (1.5s)| Channeled to Bin 4 |
| `'5'` | **Emergency Stop** | — | All Motors OFF | Immediate line shutdown |
| `'6'` | **Resume Cycle** | — | Motors Restarted | Kickstarts conveyor & feeder |
| `'7'` | **Manual Index Pulse** | — | Feeder Step | Single manual starwheel burst |
| `'8'` | **Anti-Jam Reverse** | — | Reverse Burst | 50ms full-torque clearing pulse |

---

## 🔬 Multi-Input Dual-Stream Edge AI Architecture

The classification engine ([`ml_pipeline/run_pipeline.py`](ml_pipeline/run_pipeline.py)) is a **Functional Multi-Input Dual-Stream Keras Model** engineered to handle lighting variations and camera zoom levels in physical field conditions:

```
[ Camera Image: 224x224x3 ] ──> MobileNetV3Small (Frozen/Fine-Tuned) ──> GlobalAvgPool (1024D) ──┐
                                                                                                  │
                                                                   [ Multiply: Texture Attention ]│
                                                                                             ▲    │
[ Metadata: (Zoom, EV, Flash) ] ──> Dense(16) ──> Dense(1024, Sigmoid) ──────────────────────┘    │
              │                                                                                   ▼
              └───────────────────> Dense(16) ──> Dense(8) ──> [ Concatenate ] ──> Dense(64) ──> Softmax (4 Classes)
```

1. **Dual-Stream Input:**
   * **Image Stream:** `(224, 224, 3)` RGB tensor processed through a `MobileNetV3Small` backbone.
   * **Metadata Stream:** 3-dimensional vector `[zoom, exposure, torch_flag]` capturing camera optical zoom (1x vs 3x), exposure value (`ev_-0.5`, `ev_0.0`, `ev_+0.5`), and flash status.
2. **Dynamic Texture Attention Mechanism:**
   * Uses camera optical zoom metadata to compute channel-wise sigmoid attention weights ($W_{attn} \in [0, 1]^{1024}$), multiplying the visual feature map to adapt feature weighting between macro surface texture and overall nut geometry.
3. **Edge Optimization:**
   * Quantized to INT8 / FP16 TFLite (`arecanut_model_quantized.tflite`).
   * Execution latency: **< 22ms** on mobile NPUs.

---

## 🧰 Electrical Pinout & Wiring Specification

### Controller: Arduino Uno R3 with Sensor Shield V5.0

| Component | Arduino / Shield Pin | Function | Notes |
| :--- | :--- | :--- | :--- |
| **L298N ENA** | Digital Pin 9 (PWM) | Motor A Speed Control | Feeder pulse control |
| **L298N IN1** | Digital Pin 8 | Motor A Direction A | Forward feeder indexing |
| **L298N IN2** | Digital Pin 4 | Motor A Direction B | Reverse micro-agitation & anti-jam |
| **L298N ENB** | Digital Pin 6 (PWM) | Motor B Speed Control | Vibrational PWM ramping |
| **L298N IN3** | Digital Pin 3 | Motor B Direction A | Forward conveyor feed |
| **L298N IN4** | Digital Pin 7 | Motor B Direction B | Direction reference |
| **SG90 Servo** | Analog Pin A5 (Signal) | Diverter Gate Deflection | 0°, 60°, 120°, 180° |
| **HC-05 RXD** | Digital Pin 10 (SoftSerial TX)| Bluetooth Data Link | SoftwareSerial communication |
| **HC-05 TXD** | Digital Pin 11 (SoftSerial RX)| Bluetooth Data Link | Receives classification bytes |
| **RGB LED (R)** | Digital Pin 13 | Red Channel | Common Anode (LOW = ON) |
| **RGB LED (G)** | Digital Pin 12 | Green Channel | Common Anode (LOW = ON) |
| **RGB LED (B)** | Digital Pin 5 (PWM) | Blue Channel | Smooth PWM modulation |

---

## 📂 Repository Structure

```
arecanut-ai-sorting-machine/
├── firmware/
│   └── L298N_Sorting_Control/
│       └── L298N_Sorting_Control.ino   # Non-blocking starwheel, conveyor, servo, and BT engine
├── ml_pipeline/
│   ├── run_pipeline.py                 # Multi-input dual-stream Keras training & TFLite exporter
│   ├── train_binary_model.py           # MobileNetV3 binary nut-detection pipeline
│   └── train_yolo_detector.py          # YOLOv8n object detection & spatial locator
├── hardware/
│   └── WIRING_AND_PINOUTS.md           # Electrical schematics & terminal pinouts
└── README.md
```

---

## 💼 Business & Economic Impact (CSBS Dimension)

* **Labor Cost Reduction:** Replaces manual grading shifts, reducing processing labor costs during peak post-harvest seasons.
* **Fair Price Realization for Farmers:** Eliminates human sorting bias and inconsistency, ensuring farmers receive accurate market pricing based on objective optical grading standards.
* **Cooperative Ready:** Designed to integrate into the intake grading lines of cooperative societies (**MAMCOS, NAMCOS, TSS**), streamlining bulk auction lot valuations.

---

## 👤 Author

**Abhay Kashyap**  
*1st Year Undergrad — B.Tech in Computer Science & Business Systems (CSBS)*  
*B.M.S. College of Engineering (BMSCE), Bangalore, India*  
GitHub: [@abhay2008](https://github.com/abhay2008) • Email: [abhaykashyap2008@gmail.com](mailto:abhaykashyap2008@gmail.com)  
Portfolio: [abhayportfolio.vercel.app](https://abhayportfolio.vercel.app)
