import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:camera/camera.dart';

class ClassifierResult {
  final String label;
  final Map<String, double> probabilities;
  final Map<String, double>? rawProbabilities;
  final bool isOverride;
  final Uint8List imageBytes;
  final double estimatedDiameterMm;
  final String sizeClass;

  ClassifierResult({
    required this.label,
    required this.probabilities,
    this.rawProbabilities,
    required this.isOverride,
    required this.imageBytes,
    this.estimatedDiameterMm = 0.0,
    this.sizeClass = "Medium",
  });
}

class ArecanutClassifier {
  late Interpreter _interpreter;
  late List<String> _labels;
  bool _isModelLoaded = false;
  Map<String, String> _localCorrections = {};
  File? _correctionsFile;

  bool get isLoaded => _isModelLoaded;
  List<String> get labels => _labels;
  int get correctionsCount => _localCorrections.length;
  
  double _fileSizeInKB = 0.0;
  double get correctionsFileSize => _fileSizeInKB;

  /// Calculates the structural adaptation level of the local network deployment
  double get modelSpecializationIndex {
    if (correctionsCount == 0 || _fileSizeInKB == 0) return 0.0;
    // Logarithmic growth scaling against exponential storage density limits
    double baseLog = math.log(1 + correctionsCount) / math.log(2);
    double storageFactor = 1.0 - math.exp(-_fileSizeInKB / 5.0);
    return double.parse((baseLog * storageFactor).toStringAsFixed(2));
  }

  Future<void> updateDatabaseStats() async {
    try {
      if (_correctionsFile != null && await _correctionsFile!.exists()) {
        int bytes = await _correctionsFile!.length();
        _fileSizeInKB = bytes / 1024.0;
      } else {
        _fileSizeInKB = 0.0;
      }
    } catch (e) {
      _fileSizeInKB = 0.0;
    }
  }

  // Initialize the local corrections database file
  Future<void> _initCorrections() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      _correctionsFile = File('${directory.path}/arecanut_corrections.json');
      if (await _correctionsFile!.exists()) {
        final content = await _correctionsFile!.readAsString();
        final Map<String, dynamic> jsonMap = json.decode(content);
        _localCorrections = jsonMap.map((key, value) => MapEntry(key, value.toString()));
        print("Loaded ${_localCorrections.length} local corrections.");
        await updateDatabaseStats();
      }
    } catch (e) {
      print("Failed to initialize corrections database: $e");
    }
  }

  // 1. Initialise the engine and load the files
  Future<void> loadModel() async {
    try {
      // Configure hardware delegates for performance acceleration
      final options = InterpreterOptions();
      // NOTE: XNNPackDelegate is commented out to prevent silent freezes/hangs 
      // on certain Android devices and emulators.
      // if (Platform.isAndroid) {
      //   options.addDelegate(XNNPackDelegate()); // Fast execution on mobile CPUs
      // }
      
      _interpreter = await Interpreter.fromAsset(
        'assets/arecanut_model_quantized.tflite',
        options: options
      );

      // Load the mapping keys
      final labelsString = await rootBundle.loadString('assets/labels.txt');
      _labels = labelsString.split('\n').map((s) => s.trim()).toList();
      
      await _initCorrections();
      
      _isModelLoaded = true;
      print("Model setup complete.");
    } catch (e) {
      print("Error initialization failed: $e");
      rethrow;
    }
  }

  // Converts a live CameraImage from standard stream format to cropped 224x224 RGB bytes directly
  Uint8List? convertCameraImageToRGB(CameraImage image) {
    if (image.format.group == ImageFormatGroup.yuv420) {
      return _convertYUV420ToRGB(image);
    } else if (image.format.group == ImageFormatGroup.bgra8888) {
      return _convertBGRA8888ToRGB(image);
    }
    return null;
  }

  // Fast sub-sampled YUV420 to RGB converter with center crop
  Uint8List _convertYUV420ToRGB(CameraImage image) {
    final width = image.width;
    final height = image.height;
    
    // We crop the center square region
    final cropSize = (width < height ? width : height) ~/ 2;
    final startX = (width - cropSize) ~/ 2;
    final startY = (height - cropSize) ~/ 2;
    
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    
    final yBuffer = yPlane.bytes;
    final uBuffer = uPlane.bytes;
    final vBuffer = vPlane.bytes;
    
    final yRowStride = yPlane.bytesPerRow;
    final yPixelStride = yPlane.bytesPerPixel ?? 1;
    
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 2;
    
    final vRowStride = vPlane.bytesPerRow;
    final vPixelStride = vPlane.bytesPerPixel ?? 2;
    
    const targetWidth = 224;
    const targetHeight = 224;
    final outBuffer = Uint8List(targetWidth * targetHeight * 3);
    int outIndex = 0;
    
    for (int y = 0; y < targetHeight; y++) {
      final int srcY = startY + (y * cropSize / targetHeight).toInt();
      for (int x = 0; x < targetWidth; x++) {
        final int srcX = startX + (x * cropSize / targetWidth).toInt();
        
        final int yIdx = srcY * yRowStride + srcX * yPixelStride;
        
        final int uvX = srcX ~/ 2;
        final int uvY = srcY ~/ 2;
        
        final int uIdx = uvY * uvRowStride + uvX * uvPixelStride;
        final int vIdx = uvY * vRowStride + uvX * vPixelStride;
        
        if (yIdx >= yBuffer.length || uIdx >= uBuffer.length || vIdx >= vBuffer.length) {
          outBuffer[outIndex++] = 0;
          outBuffer[outIndex++] = 0;
          outBuffer[outIndex++] = 0;
          continue;
        }
        
        final int yVal = yBuffer[yIdx] & 0xFF;
        final int uVal = uBuffer[uIdx] & 0xFF;
        final int vVal = vBuffer[vIdx] & 0xFF;
        
        final int r = (yVal + 1.370705 * (vVal - 128)).toInt().clamp(0, 255);
        final int g = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128)).toInt().clamp(0, 255);
        final int b = (yVal + 1.732446 * (uVal - 128)).toInt().clamp(0, 255);
        
        outBuffer[outIndex++] = r;
        outBuffer[outIndex++] = g;
        outBuffer[outIndex++] = b;
      }
    }
    return outBuffer;
  }

  // Fast sub-sampled BGRA8888 to RGB converter with center crop (for iOS)
  Uint8List _convertBGRA8888ToRGB(CameraImage image) {
    final width = image.width;
    final height = image.height;
    
    final cropSize = (width < height ? width : height) ~/ 2;
    final startX = (width - cropSize) ~/ 2;
    final startY = (height - cropSize) ~/ 2;
    
    final plane = image.planes[0];
    final buffer = plane.bytes;
    final rowStride = plane.bytesPerRow;
    final pixelStride = plane.bytesPerPixel ?? 4;
    
    const targetWidth = 224;
    const targetHeight = 224;
    final outBuffer = Uint8List(targetWidth * targetHeight * 3);
    int outIndex = 0;
    
    for (int y = 0; y < targetHeight; y++) {
      final int srcY = startY + (y * cropSize / targetHeight).toInt();
      for (int x = 0; x < targetWidth; x++) {
        final int srcX = startX + (x * cropSize / targetWidth).toInt();
        
        final int idx = srcY * rowStride + srcX * pixelStride;
        
        if (idx + 2 >= buffer.length) {
          outBuffer[outIndex++] = 0;
          outBuffer[outIndex++] = 0;
          outBuffer[outIndex++] = 0;
          continue;
        }
        
        final int b = buffer[idx] & 0xFF;
        final int g = buffer[idx + 1] & 0xFF;
        final int r = buffer[idx + 2] & 0xFF;
        
        outBuffer[outIndex++] = r;
        outBuffer[outIndex++] = g;
        outBuffer[outIndex++] = b;
      }
    }
    return outBuffer;
  }

  // Computes the perceptual Average Hash of a 224x224 RGB image
  Uint8List computeAverageHash(Uint8List rgbBytes) {
    final List<double> pixels = List.filled(256, 0.0);
    for (int ty = 0; ty < 16; ty++) {
      for (int tx = 0; tx < 16; tx++) {
        double sum = 0.0;
        int count = 0;
        int srcStartX = tx * 14;
        int srcStartY = ty * 14;
        for (int sy = 0; sy < 14; sy++) {
          for (int sx = 0; sx < 14; sx++) {
            int px = srcStartX + sx;
            int py = srcStartY + sy;
            int index = (py * 224 + px) * 3;
            if (index + 2 < rgbBytes.length) {
              double r = rgbBytes[index].toDouble();
              double g = rgbBytes[index + 1].toDouble();
              double b = rgbBytes[index + 2].toDouble();
              double gray = 0.299 * r + 0.587 * g + 0.114 * b;
              sum += gray;
              count++;
            }
          }
        }
        pixels[ty * 16 + tx] = count > 0 ? (sum / count) : 0.0;
      }
    }
    
    double mean = pixels.reduce((a, b) => a + b) / 256.0;
    
    final Uint8List hashBytes = Uint8List(32);
    for (int i = 0; i < 256; i++) {
      if (pixels[i] >= mean) {
        int byteIndex = i ~/ 8;
        int bitIndex = i % 8;
        hashBytes[byteIndex] |= (1 << bitIndex);
      }
    }
    return hashBytes;
  }

  // Hamming distance helper (number of differing bits)
  int hammingDistance(Uint8List h1, Uint8List h2) {
    int dist = 0;
    for (int i = 0; i < 32; i++) {
      int xorVal = h1[i] ^ h2[i];
      while (xorVal > 0) {
        dist += xorVal & 1;
        xorVal >>= 1;
      }
    }
    return dist;
  }

  // Euclidean distance helper for raw probability vectors
  double euclideanDistance(List<double> v1, List<double> v2) {
    if (v1.length != v2.length) return double.maxFinite;
    double sum = 0.0;
    for (int i = 0; i < v1.length; i++) {
      sum += (v1[i] - v2[i]) * (v1[i] - v2[i]);
    }
    return math.sqrt(sum);
  }

  // Converts a byte array to a hex string for storage keys
  String bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // Converts a hex string back to a byte array
  Uint8List hexToBytes(String hex) {
    final Uint8List bytes = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  // Looks up the closest matching user override. Returns null if none is close enough.
  String? lookupOverride(Uint8List rgbBytes, Map<String, double> currentRawProb) {
    if (_localCorrections.isEmpty) return null;
    
    final currentHash = computeAverageHash(rgbBytes);
    final List<double> currentProbList = _labels.map((l) => currentRawProb[l] ?? 0.0).toList();
    
    String? bestLabel;
    double minProbDistance = 10.0;
    int minHammingDistance = 256;
    
    _localCorrections.forEach((savedHex, storedVal) {
      try {
        final savedHash = hexToBytes(savedHex);
        final hamDist = hammingDistance(currentHash, savedHash);
        
        String savedLabel = storedVal;
        List<double>? savedProbList;
        
        if (storedVal.startsWith('{') && storedVal.endsWith('}')) {
          final decoded = json.decode(storedVal);
          savedLabel = decoded['label'] ?? storedVal;
          if (decoded['rawProb'] != null) {
            savedProbList = List<double>.from(
              (decoded['rawProb'] as List).map((x) => (x as num).toDouble())
            );
          }
        }
        
        // 1. Check aHash visual similarity (Hamming distance threshold of 40 bits out of 256)
        if (hamDist <= 40 && hamDist < minHammingDistance) {
          minHammingDistance = hamDist;
          bestLabel = savedLabel;
        }
        
        // 2. Check neural network feature similarity (Euclidean distance on probabilities threshold of 0.12)
        if (savedProbList != null && currentProbList.isNotEmpty) {
          final probDist = euclideanDistance(currentProbList, savedProbList);
          if (probDist < 0.12 && probDist < minProbDistance) {
            minProbDistance = probDist;
            bestLabel = savedLabel;
          }
        }
      } catch (e) {
        // Skip malformed entries
      }
    });
    
    if (bestLabel != null) {
      print("Override match found! Hamming: $minHammingDistance, ProbDist: $minProbDistance, Label: $bestLabel");
    }
    return bestLabel;
  }

  // Estimates the physical size of a nut using row and column pixel variance boundaries
  Map<String, dynamic> estimateNutSize(Uint8List rgbBytes) {
    final List<double> colStds = List.filled(224, 0.0);
    final List<double> rowStds = List.filled(224, 0.0);
    
    // 1. Column standard deviations
    for (int x = 0; x < 224; x++) {
      double sum = 0.0;
      for (int y = 0; y < 224; y++) {
        int idx = (y * 224 + x) * 3;
        double gray = 0.299 * rgbBytes[idx] + 0.587 * rgbBytes[idx + 1] + 0.114 * rgbBytes[idx + 2];
        sum += gray;
      }
      double mean = sum / 224.0;
      double sqSum = 0.0;
      for (int y = 0; y < 224; y++) {
        int idx = (y * 224 + x) * 3;
        double gray = 0.299 * rgbBytes[idx] + 0.587 * rgbBytes[idx + 1] + 0.114 * rgbBytes[idx + 2];
        sqSum += (gray - mean) * (gray - mean);
      }
      colStds[x] = math.sqrt(sqSum / 224.0);
    }
    
    // 2. Row standard deviations
    for (int y = 0; y < 224; y++) {
      double sum = 0.0;
      for (int x = 0; x < 224; x++) {
        int idx = (y * 224 + x) * 3;
        double gray = 0.299 * rgbBytes[idx] + 0.587 * rgbBytes[idx + 1] + 0.114 * rgbBytes[idx + 2];
        sum += gray;
      }
      double mean = sum / 224.0;
      double sqSum = 0.0;
      for (int x = 0; x < 224; x++) {
        int idx = (y * 224 + x) * 3;
        double gray = 0.299 * rgbBytes[idx] + 0.587 * rgbBytes[idx + 1] + 0.114 * rgbBytes[idx + 2];
        sqSum += (gray - mean) * (gray - mean);
      }
      rowStds[y] = math.sqrt(sqSum / 224.0);
    }
    
    // Find dynamic adaptive thresholds based on standard deviation range
    double maxColStd = colStds.reduce(math.max);
    double colThreshold = math.max(6.0, maxColStd * 0.35);
    
    double maxRowStd = rowStds.reduce(math.max);
    double rowThreshold = math.max(6.0, maxRowStd * 0.35);
    
    // Find peaks to walk outwards from
    int colPeak = 112;
    double maxColVal = -1.0;
    for (int i = 20; i < 204; i++) {
      if (colStds[i] > maxColVal) {
        maxColVal = colStds[i];
        colPeak = i;
      }
    }
    
    int rowPeak = 112;
    double maxRowVal = -1.0;
    for (int i = 20; i < 204; i++) {
      if (rowStds[i] > maxRowVal) {
        maxRowVal = rowStds[i];
        rowPeak = i;
      }
    }
    
    // Walk outwards from peaks to find bounds, ignoring edge noise
    int left = colPeak;
    int consecutiveBelowCol = 0;
    while (left > 0) {
      if (colStds[left] < colThreshold) {
        consecutiveBelowCol++;
        if (consecutiveBelowCol >= 4) {
          left += 3;
          break;
        }
      } else {
        consecutiveBelowCol = 0;
      }
      left--;
    }
    
    int right = colPeak;
    consecutiveBelowCol = 0;
    while (right < 223) {
      if (colStds[right] < colThreshold) {
        consecutiveBelowCol++;
        if (consecutiveBelowCol >= 4) {
          right -= 3;
          break;
        }
      } else {
        consecutiveBelowCol = 0;
      }
      right++;
    }
    
    int top = rowPeak;
    int consecutiveBelowRow = 0;
    while (top > 0) {
      if (rowStds[top] < rowThreshold) {
        consecutiveBelowRow++;
        if (consecutiveBelowRow >= 4) {
          top += 3;
          break;
        }
      } else {
        consecutiveBelowRow = 0;
      }
      top--;
    }
    
    int bottom = rowPeak;
    consecutiveBelowRow = 0;
    while (bottom < 223) {
      if (rowStds[bottom] < rowThreshold) {
        consecutiveBelowRow++;
        if (consecutiveBelowRow >= 4) {
          bottom -= 3;
          break;
        }
      } else {
        consecutiveBelowRow = 0;
      }
      bottom++;
    }
    
    int width = (left != -1 && right != -1 && right > left) ? (right - left) : 0;
    int height = (top != -1 && bottom != -1 && bottom > top) ? (bottom - top) : 0;
    double sizeInPixels = (width + height) / 2.0;
    
    String sizeClass = "Medium";
    // Calibration factor: assuming ~12-15cm distance, 1px is approx 0.22mm
    double estimatedDiameterMm = sizeInPixels * 0.22;
    
    if (estimatedDiameterMm > 23.5) {
      sizeClass = "Large";
    } else if (estimatedDiameterMm < 18.0) {
      sizeClass = "Small";
    }
    
    return {
      "diameterMm": estimatedDiameterMm,
      "sizeClass": sizeClass,
    };
  }

  // Boosts specific class probabilities based on estimated geometric size
  Map<String, double> boostProbabilitiesWithSizing(Map<String, double> probabilities, String sizeClass) {
    final boosted = Map<String, double>.from(probabilities);
    
    // Sort labels by raw probability descending to find top 2 classes
    final sortedEntries = probabilities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
      
    if (sortedEntries.length < 2) return boosted;
    
    final String topClass = sortedEntries[0].key;
    final String secondClass = sortedEntries[1].key;
    
    final bool isBetteAndGoragalu = (topClass == "Bette" && secondClass == "Goragalu") ||
                                    (topClass == "Goragalu" && secondClass == "Bette");
                                    
    final bool isBetteAndHasa = (topClass == "Bette" && secondClass == "Hasa") ||
                                (topClass == "Hasa" && secondClass == "Bette");
                                
    if (isBetteAndGoragalu) {
      if (sizeClass == "Large") {
        // Boost Goragalu over Bette
        boosted["Goragalu"] = (boosted["Goragalu"] ?? 0.0) + 0.30;
      } else {
        // Boost Bette over Goragalu
        boosted["Bette"] = (boosted["Bette"] ?? 0.0) + 0.15;
      }
    } else if (isBetteAndHasa) {
      if (sizeClass == "Small") {
        // Boost Hasa over Bette
        boosted["Hasa"] = (boosted["Hasa"] ?? 0.0) + 0.30;
      } else {
        // Boost Bette over Hasa
        boosted["Bette"] = (boosted["Bette"] ?? 0.0) + 0.15;
      }
    }
    
    // Re-normalize probabilities so they sum up to 1.0
    double sum = boosted.values.reduce((a, b) => a + b);
    if (sum > 0) {
      boosted.forEach((key, val) {
        boosted[key] = val / sum;
      });
    }
    
    return boosted;
  }

  // Runs prediction on raw camera stream frames
  ClassifierResult? predictCameraImage(CameraImage image) {
    if (!_isModelLoaded) return null;
    
    final rgbBytes = convertCameraImageToRGB(image);
    if (rgbBytes == null) return null;
    
    final sizeInfo = estimateNutSize(rgbBytes);
    final double diameterMm = sizeInfo["diameterMm"] ?? 0.0;
    final String sizeClass = sizeInfo["sizeClass"] ?? "Medium";
    
    // 1. Run raw prediction on model
    var output = Uint8List(1 * _labels.length).reshape([1, _labels.length]);
    _interpreter.run(rgbBytes, output);
    
    List<int> results = output[0] as List<int>;
    double sum = results.map((val) => val.toDouble()).reduce((a, b) => a + b);
    Map<String, double> rawProbabilities = {};
    
    for (int i = 0; i < _labels.length; i++) {
      double prob = sum > 0 ? (results[i].toDouble() / sum) : (1.0 / _labels.length);
      rawProbabilities[_labels[i]] = prob;
    }
    
    // 2. Check for user-defined overrides using both aHash and raw probabilities
    final correctedLabel = lookupOverride(rgbBytes, rawProbabilities);
    if (correctedLabel != null) {
      final Map<String, double> probabilities = {};
      for (var l in _labels) {
        probabilities[l] = (l == correctedLabel) ? 1.0 : 0.0;
      }
      return ClassifierResult(
        label: correctedLabel,
        probabilities: probabilities,
        rawProbabilities: rawProbabilities,
        isOverride: true,
        imageBytes: rgbBytes,
        estimatedDiameterMm: diameterMm,
        sizeClass: sizeClass,
      );
    }
    
    // 3. Apply sizing boosts to the raw predictions
    final boostedProbabilities = boostProbabilitiesWithSizing(rawProbabilities, sizeClass);
    
    // Find the boosted winning label
    String finalLabel = _labels[0];
    double maxProb = -1.0;
    for (var entry in boostedProbabilities.entries) {
      if (entry.value > maxProb) {
        maxProb = entry.value;
        finalLabel = entry.key;
      }
    }
    
    return ClassifierResult(
      label: finalLabel,
      probabilities: boostedProbabilities,
      rawProbabilities: rawProbabilities,
      isOverride: false,
      imageBytes: rgbBytes,
      estimatedDiameterMm: diameterMm,
      sizeClass: sizeClass,
    );
  }

  // Converts a live CameraImage from standard stream format to full-frame 224x224 RGB bytes directly
  Uint8List? convertCameraImageToRGBFull(CameraImage image) {
    if (image.format.group == ImageFormatGroup.yuv420) {
      return _convertYUV420ToRGBFull(image);
    } else if (image.format.group == ImageFormatGroup.bgra8888) {
      return _convertBGRA8888ToRGBFull(image);
    }
    return null;
  }

  // Fast sub-sampled YUV420 to RGB converter on full frame (no cropping)
  Uint8List _convertYUV420ToRGBFull(CameraImage image) {
    final width = image.width;
    final height = image.height;
    
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    
    final yBuffer = yPlane.bytes;
    final uBuffer = uPlane.bytes;
    final vBuffer = vPlane.bytes;
    
    final yRowStride = yPlane.bytesPerRow;
    final yPixelStride = yPlane.bytesPerPixel ?? 1;
    
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 2;
    
    final vRowStride = vPlane.bytesPerRow;
    final vPixelStride = vPlane.bytesPerPixel ?? 2;
    
    const targetWidth = 224;
    const targetHeight = 224;
    final outBuffer = Uint8List(targetWidth * targetHeight * 3);
    int outIndex = 0;
    
    for (int y = 0; y < targetHeight; y++) {
      final int srcY = (y * height / targetHeight).toInt();
      for (int x = 0; x < targetWidth; x++) {
        final int srcX = (x * width / targetWidth).toInt();
        
        final int yIdx = srcY * yRowStride + srcX * yPixelStride;
        
        final int uvX = srcX ~/ 2;
        final int uvY = srcY ~/ 2;
        
        final int uIdx = uvY * uvRowStride + uvX * uvPixelStride;
        final int vIdx = uvY * vRowStride + uvX * vPixelStride;
        
        if (yIdx >= yBuffer.length || uIdx >= uBuffer.length || vIdx >= vBuffer.length) {
          outBuffer[outIndex++] = 0;
          outBuffer[outIndex++] = 0;
          outBuffer[outIndex++] = 0;
          continue;
        }
        
        final int yVal = yBuffer[yIdx] & 0xFF;
        final int uVal = uBuffer[uIdx] & 0xFF;
        final int vVal = vBuffer[vIdx] & 0xFF;
        
        final int r = (yVal + 1.370705 * (vVal - 128)).toInt().clamp(0, 255);
        final int g = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128)).toInt().clamp(0, 255);
        final int b = (yVal + 1.732446 * (uVal - 128)).toInt().clamp(0, 255);
        
        outBuffer[outIndex++] = r;
        outBuffer[outIndex++] = g;
        outBuffer[outIndex++] = b;
      }
    }
    return outBuffer;
  }

  // Fast sub-sampled BGRA8888 to RGB converter on full frame (no cropping) (for iOS)
  Uint8List _convertBGRA8888ToRGBFull(CameraImage image) {
    final width = image.width;
    final height = image.height;
    
    final plane = image.planes[0];
    final buffer = plane.bytes;
    final rowStride = plane.bytesPerRow;
    final pixelStride = plane.bytesPerPixel ?? 4;
    
    const targetWidth = 224;
    const targetHeight = 224;
    final outBuffer = Uint8List(targetWidth * targetHeight * 3);
    int outIndex = 0;
    
    for (int y = 0; y < targetHeight; y++) {
      final int srcY = (y * height / targetHeight).toInt();
      for (int x = 0; x < targetWidth; x++) {
        final int srcX = (x * width / targetWidth).toInt();
        
        final int idx = srcY * rowStride + srcX * pixelStride;
        
        if (idx + 2 >= buffer.length) {
          outBuffer[outIndex++] = 0;
          outBuffer[outIndex++] = 0;
          outBuffer[outIndex++] = 0;
          continue;
        }
        
        final int b = buffer[idx] & 0xFF;
        final int g = buffer[idx + 1] & 0xFF;
        final int r = buffer[idx + 2] & 0xFF;
        
        outBuffer[outIndex++] = r;
        outBuffer[outIndex++] = g;
        outBuffer[outIndex++] = b;
      }
    }
    return outBuffer;
  }

  // Runs prediction on raw camera stream frames using the full frame
  ClassifierResult? predictCameraImageFull(CameraImage image) {
    if (!_isModelLoaded) return null;
    
    final rgbBytes = convertCameraImageToRGBFull(image);
    if (rgbBytes == null) return null;
    
    final sizeInfo = estimateNutSize(rgbBytes);
    final double diameterMm = sizeInfo["diameterMm"] ?? 0.0;
    final String sizeClass = sizeInfo["sizeClass"] ?? "Medium";
    
    // 1. Run raw prediction on model
    var output = Uint8List(1 * _labels.length).reshape([1, _labels.length]);
    _interpreter.run(rgbBytes, output);
    
    List<int> results = output[0] as List<int>;
    double sum = results.map((val) => val.toDouble()).reduce((a, b) => a + b);
    Map<String, double> rawProbabilities = {};
    
    for (int i = 0; i < _labels.length; i++) {
      double prob = sum > 0 ? (results[i].toDouble() / sum) : (1.0 / _labels.length);
      rawProbabilities[_labels[i]] = prob;
    }
    
    // 2. Check for user-defined similarity overrides first
    final correctedLabel = lookupOverride(rgbBytes, rawProbabilities);
    if (correctedLabel != null) {
      final Map<String, double> probabilities = {};
      for (var l in _labels) {
        probabilities[l] = (l == correctedLabel) ? 1.0 : 0.0;
      }
      return ClassifierResult(
        label: correctedLabel,
        probabilities: probabilities,
        rawProbabilities: rawProbabilities,
        isOverride: true,
        imageBytes: rgbBytes,
        estimatedDiameterMm: diameterMm,
        sizeClass: sizeClass,
      );
    }
    
    // 3. Apply sizing boosts to the raw predictions
    final boostedProbabilities = boostProbabilitiesWithSizing(rawProbabilities, sizeClass);
    
    // Find the boosted winning label
    String finalLabel = _labels[0];
    double maxProb = -1.0;
    for (var entry in boostedProbabilities.entries) {
      if (entry.value > maxProb) {
        maxProb = entry.value;
        finalLabel = entry.key;
      }
    }
    
    return ClassifierResult(
      label: finalLabel,
      probabilities: boostedProbabilities,
      rawProbabilities: rawProbabilities,
      isOverride: false,
      imageBytes: rgbBytes,
      estimatedDiameterMm: diameterMm,
      sizeClass: sizeClass,
    );
  }

  ClassifierResult? predict(File imageFile) {
    if (!_isModelLoaded) return null;

    final imageBytes = imageFile.readAsBytesSync();
    // Convert to working canvas image object
    img.Image? originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) return null;

    // Resize exactly to match your MobileNet input shape (224x224)
    img.Image resizedImage = img.copyResize(originalImage, width: 224, height: 224);

    // Prepare 4D Array buffer shape matching [1, 224, 224, 3]
    var input = Uint8List(1 * 224 * 224 * 3);
    var bufferIndex = 0;

    for (int y = 0; y < 224; y++) {
      for (int x = 0; x < 224; x++) {
        var pixel = resizedImage.getPixel(x, y);
        input[bufferIndex++] = pixel.r.toInt();
        input[bufferIndex++] = pixel.g.toInt();
        input[bufferIndex++] = pixel.b.toInt();
      }
    }

    final sizeInfo = estimateNutSize(input);
    final double diameterMm = sizeInfo["diameterMm"] ?? 0.0;
    final String sizeClass = sizeInfo["sizeClass"] ?? "Medium";

    // 1. Run raw prediction on model
    var output = Uint8List(1 * _labels.length).reshape([1, _labels.length]);
    _interpreter.run(input, output);

    List<int> results = output[0] as List<int>;
    double sum = results.map((val) => val.toDouble()).reduce((a, b) => a + b);
    Map<String, double> rawProbabilities = {};

    for (int i = 0; i < _labels.length; i++) {
      double prob = sum > 0 ? (results[i].toDouble() / sum) : (1.0 / _labels.length);
      rawProbabilities[_labels[i]] = prob;
    }

    // 2. Check for user-defined similarity overrides first
    final correctedLabel = lookupOverride(input, rawProbabilities);
    if (correctedLabel != null) {
      final Map<String, double> probabilities = {};
      for (var l in _labels) {
        probabilities[l] = (l == correctedLabel) ? 1.0 : 0.0;
      }
      return ClassifierResult(
        label: correctedLabel,
        probabilities: probabilities,
        rawProbabilities: rawProbabilities,
        isOverride: true,
        imageBytes: imageBytes,
        estimatedDiameterMm: diameterMm,
        sizeClass: sizeClass,
      );
    }

    // 3. Apply sizing boosts to the raw predictions
    final boostedProbabilities = boostProbabilitiesWithSizing(rawProbabilities, sizeClass);
    
    // Find the boosted winning label
    String finalLabel = _labels[0];
    double maxProb = -1.0;
    for (var entry in boostedProbabilities.entries) {
      if (entry.value > maxProb) {
        maxProb = entry.value;
        finalLabel = entry.key;
      }
    }

    return ClassifierResult(
      label: finalLabel,
      probabilities: boostedProbabilities,
      rawProbabilities: rawProbabilities,
      isOverride: false,
      imageBytes: imageBytes,
      estimatedDiameterMm: diameterMm,
      sizeClass: sizeClass,
    );
  }

  // Save a new user correction from raw bytes directly
  Future<void> saveCorrectionFromBytes(Uint8List rgbBytes, String correctLabel, [Map<String, double>? rawProbabilities]) async {
    try {
      final hashBytes = computeAverageHash(rgbBytes);
      final hexHash = bytesToHex(hashBytes);
      
      Map<String, double>? finalRawProb = rawProbabilities;
      if (finalRawProb == null && _isModelLoaded) {
        var output = Uint8List(1 * _labels.length).reshape([1, _labels.length]);
        _interpreter.run(rgbBytes, output);
        List<int> results = output[0] as List<int>;
        double sum = results.map((val) => val.toDouble()).reduce((a, b) => a + b);
        finalRawProb = {};
        for (int i = 0; i < _labels.length; i++) {
          double prob = sum > 0 ? (results[i].toDouble() / sum) : (1.0 / _labels.length);
          finalRawProb[_labels[i]] = prob;
        }
      }
      
      final Map<String, dynamic> data = {
        "label": correctLabel,
        "aHash": hexHash,
      };
      if (finalRawProb != null) {
        data["rawProb"] = _labels.map((l) => finalRawProb![l] ?? 0.0).toList();
      }
      
      _localCorrections[hexHash] = json.encode(data);
      
      if (_correctionsFile != null) {
        await _correctionsFile!.writeAsString(json.encode(_localCorrections));
        print("Correction saved for image perceptual hash $hexHash: $correctLabel");
        await updateDatabaseStats();
      }
    } catch (e) {
      print("Failed to save correction: $e");
    }
  }

  // Save a new user correction to the local database file (for static files)
  Future<void> saveCorrection(File imageFile, String correctLabel) async {
    img.Image? originalImage = img.decodeImage(imageFile.readAsBytesSync());
    if (originalImage != null) {
      img.Image resizedImage = img.copyResize(originalImage, width: 224, height: 224);
      final rgbBytes = Uint8List(224 * 224 * 3);
      int index = 0;
      for (int y = 0; y < 224; y++) {
        for (int x = 0; x < 224; x++) {
          var pixel = resizedImage.getPixel(x, y);
          rgbBytes[index++] = pixel.r.toInt();
          rgbBytes[index++] = pixel.g.toInt();
          rgbBytes[index++] = pixel.b.toInt();
        }
      }
      await saveCorrectionFromBytes(rgbBytes, correctLabel);
    }
  }

  // Clear all saved user corrections from database and memory
  Future<void> clearCorrections() async {
    _localCorrections.clear();
    try {
      if (_correctionsFile != null && await _correctionsFile!.exists()) {
        await _correctionsFile!.delete();
      }
    } catch (e) {
      print("Failed to delete corrections file: $e");
    }
    await updateDatabaseStats();
  }
}