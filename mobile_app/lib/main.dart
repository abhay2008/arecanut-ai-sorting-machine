import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'services/classifier_service.dart';
import 'services/bluetooth_service.dart';

void main() {
  runApp(const ArecanutApp());
}

class ArecanutApp extends StatelessWidget {
  const ArecanutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arecanut Classifier',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const ClassifierScreen(),
    );
  }
}

class ClassifierScreen extends StatefulWidget {
  const ClassifierScreen({super.key});

  @override
  State<ClassifierScreen> createState() => _ClassifierScreenState();
}

class _ClassifierScreenState extends State<ClassifierScreen> {
  final ArecanutClassifier _classifier = ArecanutClassifier();
  final BluetoothService _bluetoothService = BluetoothService();
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  String _bluetoothStatus = "Bluetooth: Connecting...";
  
  // App Mode: "LIVE" or "STATIC"
  String _appMode = "LIVE";

  // Static Picker Mode variables
  final ImagePicker _picker = ImagePicker();
  File? _selectedImage;
  ClassifierResult? _staticResult;
  String _staticPredictionResult = "Select an image to classify";
  bool _isStaticProcessing = false;

  // Live State Machine variables: "IDLE", "LOCKED", "FINALIZE"
  String _scanState = "IDLE";
  ClassifierResult? _liveResult;
  ClassifierResult? _result;
  bool _isProcessing = false;
  String _modelLoadError = "";

  // Zoom levels
  double _minZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  double _currentZoomLevel = 1.0;

  // Exposure offset list for bracketing (cycling helps find clean cuts for Bette vs Rashi)
  final List<double> _exposureOffsets = [0.0, -0.5, 0.5];
  int _exposureIndex = 0;

  // Temporal frame accumulator
  final List<Map<String, double>> _accumulatedProbabilities = [];
  final List<Uint8List> _accumulatedFrameBytes = [];
  bool _isProcessingFrame = false;
  DateTime? _lastFrameProcessedTime;

  // Nut absent grace timer
  DateTime? _nutLeftTime;

  // Best frame tracker for reinforcement overrides
  Uint8List? _bestFrameBytes;
  double _bestFrameConfidence = 0.0;
  String _bestFrameLabel = "";

  // Encoded frames for visual layout display during FINALIZE state
  final List<Uint8List> _finalFrameJpegs = [];
  final List<Uint8List> _finalFrameRgbBytes = [];

  @override
  void initState() {
    super.initState();
    _initModel();
    _initBluetooth();
  }

  Future<void> _initBluetooth() async {
    // Request Bluetooth permissions for Android 12+
    await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();

    bool connected = await _bluetoothService.connectToDevice("HC-05");
    if (mounted) {
      setState(() {
        _bluetoothStatus = connected ? "Bluetooth: Connected" : "Bluetooth: Failed";
      });
    }
  }

  // Initialise model and then camera
  Future<void> _initModel() async {
    try {
      await _classifier.loadModel();
      await _initCamera();
    } catch (e) {
      setState(() {
        _modelLoadError = e.toString();
      });
    }
    setState(() {});
  }

  // Initialise camera preview
  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _modelLoadError = "No cameras available.";
        });
        return;
      }
      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      
      _minZoomLevel = await _cameraController!.getMinZoomLevel();
      _maxZoomLevel = await _cameraController!.getMaxZoomLevel();
      _currentZoomLevel = _minZoomLevel;
      await _cameraController!.setZoomLevel(_currentZoomLevel);
      
      setState(() {
        _isCameraInitialized = true;
      });
      _startImageStream();
    } catch (e) {
      setState(() {
        _modelLoadError = "Camera initialization failed: $e";
      });
    }
  }

  // Start reading frames from camera stream
  void _startImageStream() {
    if (_cameraController == null || !_isCameraInitialized) return;
    
    _cameraController!.startImageStream((CameraImage image) {
      if (_appMode != "LIVE" || _scanState == "FINALIZE" || _isProcessingFrame) return;
      
      final now = DateTime.now();
      if (_lastFrameProcessedTime != null && now.difference(_lastFrameProcessedTime!).inMilliseconds < 250) {
        return;
      }
      
      _lastFrameProcessedTime = now;
      _processCameraFrame(image);
    });
  }

  // Check texture details to verify if an arecanut object is present
  bool _isNutPresent(Uint8List rgbBytes) {
    if (rgbBytes.isEmpty) return false;
    final int total = rgbBytes.length ~/ 3;
    int sum = 0;
    for (int i = 0; i < rgbBytes.length; i += 3) {
      sum += rgbBytes[i];
    }
    final double mean = sum / total;
    
    double sumSqDiff = 0.0;
    for (int i = 0; i < rgbBytes.length; i += 3) {
      final double diff = rgbBytes[i] - mean;
      sumSqDiff += diff * diff;
    }
    final double variance = sumSqDiff / total;
    print("Detected frame texture variance: $variance");
    return variance > 120.0;
  }

  // Process a live frame
  Future<void> _processCameraFrame(CameraImage image) async {
    if (_isProcessingFrame) return;
    _isProcessingFrame = true;
    
    try {
      if (_scanState == "IDLE") {
        // Run prediction on the FULL frame to detect arecanuts anywhere
        final result = _classifier.predictCameraImageFull(image);
        if (result != null) {
          final double maxProb = result.probabilities[result.label] ?? 0.0;
          final bool hasNut = _isNutPresent(result.imageBytes);
          
          if (mounted) {
            setState(() {
              _liveResult = result;
            });
          }
          
          // Lock on if we see any arecanut with > 55% confidence and standard deviation check passes
          if (maxProb > 0.55 && hasNut) {
            if (mounted) {
              setState(() {
                _scanState = "LOCKED";
                _accumulatedProbabilities.clear();
                _accumulatedFrameBytes.clear();
                _bestFrameBytes = result.imageBytes;
                _bestFrameConfidence = maxProb;
                _bestFrameLabel = result.label;
                _accumulatedProbabilities.add(result.probabilities);
                _accumulatedFrameBytes.add(result.imageBytes);
                _nutLeftTime = null;
              });
            }
            // Zoom in immediately (zoom by 2.0 levels from min, bounded by max)
            double targetZoom = (_minZoomLevel + 2.0).clamp(_minZoomLevel, _maxZoomLevel);
            await _cameraController?.setZoomLevel(targetZoom);
            _currentZoomLevel = targetZoom;
            if (mounted) setState(() {});
            print("Nut detected! Target LOCKED. Zooming to $targetZoom");
          }
        }
      } else if (_scanState == "LOCKED") {
        // Run prediction on the CENTER CROP frame for close-up scanning
        final result = _classifier.predictCameraImage(image);
        if (result != null) {
          final double maxProb = result.probabilities[result.label] ?? 0.0;
          final bool hasNut = _isNutPresent(result.imageBytes);
          
          if (mounted) {
            setState(() {
              _liveResult = result;
            });
          }
          
          if (maxProb > 0.50 && hasNut) {
            // Nut is in the frame!
            _nutLeftTime = null;
            
            // Accumulate valid frame probabilities and images
            _accumulatedProbabilities.add(result.probabilities);
            _accumulatedFrameBytes.add(result.imageBytes);
            
            // Cap at 10 frames to hold history representation
            if (_accumulatedFrameBytes.length > 10) {
              _accumulatedFrameBytes.removeAt(0);
              _accumulatedProbabilities.removeAt(0);
            }
            
            // Track highest confidence frame for reinforcement
            if (maxProb > _bestFrameConfidence) {
              _bestFrameConfidence = maxProb;
              _bestFrameBytes = result.imageBytes;
              _bestFrameLabel = result.label;
            }
            
            // Cycle exposure offset to capture cut details under different lighting conditions
            await _cycleExposure();
          } else {
            // Nut left the target frame
            if (_nutLeftTime == null) {
              // Zoom out back to 0.5x immediately
              _nutLeftTime = DateTime.now();
              await _cameraController?.setZoomLevel(_minZoomLevel);
              _currentZoomLevel = _minZoomLevel;
              if (mounted) setState(() {});
              print("Nut left frame. Zooming out back to $_minZoomLevel.");
            } else {
              // Check if 3 seconds have passed
              final goneDuration = DateTime.now().difference(_nutLeftTime!);
              if (goneDuration.inSeconds >= 3) {
                _finalizeScan();
              } else {
                if (mounted) setState(() {});
              }
            }
          }
        }
      }
    } catch (e) {
      print("Frame processing error: $e");
    } finally {
      _isProcessingFrame = false;
    }
  }

  // Cycles camera exposure offset to capture detail details
  Future<void> _cycleExposure() async {
    if (_cameraController == null || !_isCameraInitialized) return;
    try {
      _exposureIndex = (_exposureIndex + 1) % _exposureOffsets.length;
      final offset = _exposureOffsets[_exposureIndex];
      await _cameraController!.setExposureOffset(offset);
      if (mounted) setState(() {});
    } catch (e) {
      print("Failed to set exposure offset: $e");
    }
  }

  // Finalize scanning and calculate averaged prediction
  void _finalizeScan() {
    if (mounted) {
      setState(() {
        _scanState = "FINALIZE";
      });
    }
    
    if (_accumulatedProbabilities.isEmpty || _bestFrameBytes == null) {
      _resetScan();
      return;
    }
    
    // Average the confidence percentages over all valid accumulated frames
    final Map<String, double> averageProbs = {};
    for (var label in _classifier.labels) {
      double sum = 0.0;
      for (var frameMap in _accumulatedProbabilities) {
        sum += frameMap[label] ?? 0.0;
      }
      averageProbs[label] = sum / _accumulatedProbabilities.length;
    }
    
    // Select the class with the highest average probability
    String finalLabel = _classifier.labels.first;
    double maxVal = -1.0;
    for (var entry in averageProbs.entries) {
      if (entry.value > maxVal) {
        maxVal = entry.value;
        finalLabel = entry.key;
      }
    }
    
    final finalResult = ClassifierResult(
      label: finalLabel,
      probabilities: averageProbs,
      isOverride: false,
      imageBytes: _bestFrameBytes!,
    );
    
    // Convert accumulated raw RGB frames to displayable JPEGs in the UI strip
    _finalFrameJpegs.clear();
    _finalFrameRgbBytes.clear();
    for (var rgbBytes in _accumulatedFrameBytes) {
      try {
        final imgImage = img.Image.fromBytes(
          width: 224,
          height: 224,
          bytes: rgbBytes.buffer,
          order: img.ChannelOrder.rgb,
        );
        final jpegBytes = Uint8List.fromList(img.encodeJpg(imgImage));
        _finalFrameJpegs.add(jpegBytes);
        _finalFrameRgbBytes.add(rgbBytes);
      } catch (e) {
        print("Failed to encode accumulated frame JPEG: $e");
      }
    }
    
    if (mounted) {
      setState(() {
        _result = finalResult;
      });
    }
  }

  // Handle correction or verification feedback (LIVE mode)
  Future<void> _handleScanVerification(bool isCorrect) async {
    if (_result == null) return;
    
    if (isCorrect) {
      if (mounted) {
        setState(() {
          _isProcessing = true;
        });
      }
      await _classifier.saveCorrectionFromBytes(_result!.imageBytes, _result!.label, _result!.rawProbabilities);
      await _resetScan();
    } else {
      final labels = _classifier.labels;
      String? selectedLabel = await showDialog<String>(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Correct Classification'),
            content: const Text('Select the correct variant of arecanut:'),
            actions: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: labels.map((label) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, label),
                      child: Text(label),
                    ),
                  );
                }).toList(),
              ),
            ],
          );
        },
      );
      
      if (selectedLabel != null) {
        if (mounted) {
          setState(() {
            _isProcessing = true;
          });
        }
        await _classifier.saveCorrectionFromBytes(_result!.imageBytes, selectedLabel, _result!.rawProbabilities);
        await _resetScan();
      }
    }
  }

  // Opens reinforcement training popup for a specific individual captured frame
  Future<void> _handleFrameCorrection(Uint8List rgbBytes, Uint8List jpegBytes) async {
    final labels = _classifier.labels;
    String? selectedLabel = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Reinforce/Correct Frame'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  jpegBytes,
                  width: 120,
                  height: 120,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 16),
              const Text('Select classification to train this frame:'),
            ],
          ),
          actions: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: labels.map((label) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, label),
                    child: Text(label),
                  ),
                );
              }).toList(),
            ),
          ],
        );
      },
    );
    
    if (selectedLabel != null) {
      if (mounted) {
        setState(() {
          _isProcessing = true;
        });
      }
      await _classifier.saveCorrectionFromBytes(rgbBytes, selectedLabel);
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Trained frame as: $selectedLabel"),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  // Reset tracker state machine back to idle
  Future<void> _resetScan() async {
    _nutLeftTime = null;
    _bestFrameBytes = null;
    _bestFrameConfidence = 0.0;
    _bestFrameLabel = "";
    _accumulatedFrameBytes.clear();
    _finalFrameJpegs.clear();
    _finalFrameRgbBytes.clear();
    
    try {
      await _cameraController?.setExposureOffset(0.0);
      _exposureIndex = 0;
      await _cameraController?.setZoomLevel(_minZoomLevel);
      _currentZoomLevel = _minZoomLevel;
    } catch (e) {
      print("Failed to reset camera: $e");
    }
    
    if (mounted) {
      setState(() {
        _result = null;
        _liveResult = null;
        _scanState = "IDLE";
        _accumulatedProbabilities.clear();
        _isProcessing = false;
      });
    }
  }

  // Static Mode: Handle image selection
  Future<void> _handleImageSelection(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
      );

      if (pickedFile == null) return;

      setState(() {
        _selectedImage = File(pickedFile.path);
        _isStaticProcessing = true;
        _staticPredictionResult = "Running inference...";
        _staticResult = null;
      });

      final result = _classifier.predict(_selectedImage!);

      setState(() {
        _staticResult = result;
        _isStaticProcessing = false;
        if (result != null) {
          _staticPredictionResult = result.isOverride
              ? "Overridden: ${result.label}"
              : "Result: ${result.label}";
        } else {
          _staticPredictionResult = "Error running model.";
        }
      });
    } catch (e) {
      setState(() {
        _staticPredictionResult = "Error running model: $e";
        _isStaticProcessing = false;
        _staticResult = null;
      });
    }
  }

  // Static Mode: Correction dialog
  Future<void> _showStaticCorrectionDialog() async {
    if (_selectedImage == null || _staticResult == null) return;
    
    final labels = _classifier.labels;
    String? selectedLabel = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Correct Classification'),
          content: const Text('Select the correct variant of arecanut:'),
          actions: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: labels.map((label) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, label),
                    child: Text(label),
                  ),
                );
              }).toList(),
            ),
          ],
        );
      },
    );

    if (selectedLabel != null) {
      setState(() {
        _isStaticProcessing = true;
      });
      await _classifier.saveCorrection(_selectedImage!, selectedLabel);
      final newResult = _classifier.predict(_selectedImage!);
      setState(() {
        _staticResult = newResult;
        _staticPredictionResult = "Overridden: $selectedLabel";
        _isStaticProcessing = false;
      });
    }
  }

  @override
  void dispose() {
    _bluetoothService.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Arecanut Classifier'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Bluetooth Status
              Text(
                _bluetoothStatus,
                style: TextStyle(
                  color: _bluetoothStatus.contains("Connected") ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),

              // Mode Selector switch tabs
              Container(
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _appMode = "LIVE";
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        decoration: BoxDecoration(
                          color: _appMode == "LIVE" ? Colors.green : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          "Live Scanner",
                          style: TextStyle(
                            color: _appMode == "LIVE" ? Colors.white : Colors.black87,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _appMode = "STATIC";
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        decoration: BoxDecoration(
                          color: _appMode == "STATIC" ? Colors.green : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          "Single Photo",
                          style: TextStyle(
                            color: _appMode == "STATIC" ? Colors.white : Colors.black87,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Start Model Button
              ElevatedButton.icon(
                onPressed: () {
                  _bluetoothService.sendSignal("5");
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Sent signal 5 via Bluetooth')),
                  );
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start Model', style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
              const SizedBox(height: 24),

              if (_appMode == "LIVE") ...[
                // --- LIVE MODE UI ---
                Container(
                  width: 300,
                  height: 300,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _scanState == "LOCKED" ? Colors.green : Colors.grey[700]!,
                      width: 4,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _isCameraInitialized && _cameraController != null
                        ? Stack(
                            fit: StackFit.expand,
                            children: [
                              CameraPreview(_cameraController!),
                              // Center target crop zone reticle
                              Center(
                                child: Container(
                                  width: 150,
                                  height: 150,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: _scanState == "LOCKED" 
                                          ? Colors.green.withOpacity(0.8) 
                                          : Colors.white.withOpacity(0.5),
                                      width: 3,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                              // Status indicator badge
                              Positioned(
                                top: 12,
                                left: 12,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _scanState == "LOCKED" 
                                        ? Colors.green.withOpacity(0.8) 
                                        : Colors.grey[800]!.withOpacity(0.8),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    _scanState,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              // Active Exposure Indicator Badge
                              if (_scanState == "LOCKED")
                                Positioned(
                                  top: 12,
                                  right: 12,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.6),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      "EV: ${_exposureOffsets[_exposureIndex] > 0 ? "+" : ""}${_exposureOffsets[_exposureIndex].toStringAsFixed(1)}",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          )
                        : const Center(
                            child: CircularProgressIndicator(),
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Live mode console readout
                if (_scanState == "LOCKED") ...[
                  if (_nutLeftTime != null) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.timer, color: Colors.orange, size: 18),
                          const SizedBox(width: 6),
                          Text(
                            "Nut left frame. Auto-finalizing in ${3 - DateTime.now().difference(_nutLeftTime!).inSeconds}s",
                            style: const TextStyle(
                              color: Colors.orange,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else if (_liveResult != null) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.gps_fixed, color: Colors.green, size: 18),
                              const SizedBox(width: 6),
                              Text(
                                "Tracking: ${_liveResult!.label} (${(_liveResult!.probabilities[_liveResult!.label]! * 100).toStringAsFixed(0)}%)",
                                style: const TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                          if (_liveResult!.estimatedDiameterMm > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              "Sizing: ${_liveResult!.sizeClass} (${_liveResult!.estimatedDiameterMm.toStringAsFixed(1)} mm)",
                              style: TextStyle(
                                color: Colors.green[700],
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ] else ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8.0),
                    child: Text(
                      "Place an arecanut inside the box to scan",
                      style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
                
                if (_scanState == "FINALIZE" && _result != null) ...[
                  const SizedBox(height: 16),
                  const Text(
                    "Final Scan Result",
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black54),
                  ),
                  Text(
                    _result!.label,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Colors.green[800],
                    ),
                  ),
                  if (_result!.estimatedDiameterMm > 0) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green[50],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.green[200]!),
                      ),
                      child: Text(
                        "Estimated Size: ${_result!.sizeClass} (${_result!.estimatedDiameterMm.toStringAsFixed(1)} mm)",
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.green[800]),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Angles Averaged Confidence:",
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black54),
                    ),
                  ),
                  const SizedBox(height: 6),
                  ..._result!.probabilities.entries.map((entry) {
                    final label = entry.key;
                    final prob = entry.value;
                    final percent = (prob * 100).toStringAsFixed(1);
                    final isWinner = label == _result!.label;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                label,
                                style: TextStyle(
                                  fontWeight: isWinner ? FontWeight.bold : FontWeight.normal,
                                  color: isWinner ? Colors.black87 : Colors.black54,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                "$percent%",
                                style: TextStyle(
                                  fontWeight: isWinner ? FontWeight.bold : FontWeight.normal,
                                  color: isWinner ? Colors.black87 : Colors.black54,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: prob,
                              minHeight: 6,
                              backgroundColor: Colors.grey[200],
                              valueColor: AlwaysStoppedAnimation<Color>(
                                isWinner ? Colors.green : Colors.grey[400]!,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                  const SizedBox(height: 16),
                  
                  // Captured frame list for individual confirmation override selection
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Captured Nut Sweep Frames (Tap to train/reinforce specific frame):",
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black54),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 90,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _finalFrameJpegs.length,
                      itemBuilder: (context, index) {
                        final jpeg = _finalFrameJpegs[index];
                        final rgb = _finalFrameRgbBytes[index];
                        return GestureDetector(
                          onTap: () => _handleFrameCorrection(rgb, jpeg),
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.green, width: 2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.memory(
                                  jpeg,
                                  width: 80,
                                  height: 80,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  
                  const SizedBox(height: 20),
                  const Text(
                    "Was this prediction correct?",
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isProcessing ? null : () => _handleScanVerification(true),
                        icon: const Icon(Icons.check, color: Colors.white),
                        label: const Text("Yes"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        onPressed: _isProcessing ? null : () => _handleScanVerification(false),
                        icon: const Icon(Icons.close, color: Colors.white),
                        label: const Text("Wrong"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: _isProcessing ? null : _resetScan,
                    child: const Text("Cancel and Restart Scan"),
                  ),
                ] else ...[
                  const SizedBox(height: 160),
                ],
              ] else ...[
                // --- STATIC MODE UI ---
                Container(
                  width: 300,
                  height: 300,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey[400]!),
                  ),
                  child: _selectedImage != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(15),
                          child: Image.file(_selectedImage!, fit: BoxFit.cover),
                        )
                      : const Icon(Icons.image_not_supported, size: 80, color: Colors.grey),
                ),
                const SizedBox(height: 32),
                
                if (_staticResult != null) ...[
                  Text(
                    _staticResult!.isOverride ? "Overridden Prediction" : "Model Prediction",
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    _staticResult!.label,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: _staticResult!.isOverride ? Colors.blue[800] : Colors.green[800],
                    ),
                  ),
                  if (_staticResult!.estimatedDiameterMm > 0) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green[50],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.green[200]!),
                      ),
                      child: Text(
                        "Estimated Size: ${_staticResult!.sizeClass} (${_staticResult!.estimatedDiameterMm.toStringAsFixed(1)} mm)",
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.green[800]),
                      ),
                    ),
                  ],
                  if (_staticResult!.isOverride) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.blue[50],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.blue[200]!),
                      ),
                      child: Text(
                        "Learned User Override",
                        style: TextStyle(fontSize: 12, color: Colors.blue[800], fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Confidence Breakdown:",
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black54),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._staticResult!.probabilities.entries.map((entry) {
                    final label = entry.key;
                    final prob = entry.value;
                    final percent = (prob * 100).toStringAsFixed(1);
                    final isWinner = label == _staticResult!.label;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                label,
                                style: TextStyle(
                                  fontWeight: isWinner ? FontWeight.bold : FontWeight.normal,
                                  color: isWinner ? Colors.black87 : Colors.black54,
                                ),
                              ),
                              Text(
                                "$percent%",
                                style: TextStyle(
                                  fontWeight: isWinner ? FontWeight.bold : FontWeight.normal,
                                  color: isWinner ? Colors.black87 : Colors.black54,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: prob,
                              minHeight: 8,
                              backgroundColor: Colors.grey[200],
                              valueColor: AlwaysStoppedAnimation<Color>(
                                isWinner 
                                  ? (_staticResult!.isOverride ? Colors.blue : Colors.green) 
                                  : Colors.grey[400]!,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _isStaticProcessing ? null : _showStaticCorrectionDialog,
                    icon: const Icon(Icons.edit, size: 18),
                    label: Text(_staticResult!.isOverride ? "Change Correction" : "Correct Prediction"),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.blue[700],
                    ),
                  ),
                ] else ...[
                  Text(
                    _staticPredictionResult,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: _staticPredictionResult.contains("Result") ? Colors.green[800] : Colors.black87,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 32),
                
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isStaticProcessing || !_classifier.isLoaded
                          ? null 
                          : () => _handleImageSelection(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Camera'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _isStaticProcessing || !_classifier.isLoaded
                          ? null 
                          : () => _handleImageSelection(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Gallery'),
                    ),
                  ],
                ),
              ],

              // --- MODEL STATUS & STATS PANEL ---
              const SizedBox(height: 32),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.green[200]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.psychology, color: Colors.green[800]),
                        const SizedBox(width: 8),
                        Text(
                          "AI Model Tuning Stats",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.green[900],
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Base Classifier model:", style: TextStyle(fontSize: 12, color: Colors.black54)),
                        Text("MobileNet Edge TFLite", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.green[800])),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Base Engine File Size:", style: TextStyle(fontSize: 12, color: Colors.black54)),
                        const Text("1.64 MB", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Reinforcement Database:", style: TextStyle(fontSize: 12, color: Colors.black54)),
                        Text(
                          "${_classifier.correctionsFileSize.toStringAsFixed(2)} KB",
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Active Custom Overrides:", style: TextStyle(fontSize: 12, color: Colors.black54)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green[100],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            "${_classifier.correctionsCount} overrides trained",
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green[900]),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "Improving Ability Index: ${_classifier.modelSpecializationIndex.toStringAsFixed(2)} specialization index",
                      style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: Colors.green[700],
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton.icon(
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text("Reset Database"),
                              content: const Text("Clear all local overrides and start training fresh?"),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context, false),
                                  child: const Text("Cancel"),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text("Reset", style: TextStyle(color: Colors.red)),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            await _classifier.clearCorrections();
                            if (mounted) setState(() {});
                          }
                        },
                        icon: const Icon(Icons.delete_sweep, size: 16, color: Colors.red),
                        label: const Text("Clear Override Database", style: TextStyle(fontSize: 11, color: Colors.red)),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              if (_modelLoadError.isNotEmpty)
                Text(
                  "Failed to load model: $_modelLoadError",
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                )
              else if (!_classifier.isLoaded)
                const Text("Loading AI architecture weights...", style: TextStyle(color: Colors.orange)),
            ],
          ),
        ),
      ),
    );
  }
}