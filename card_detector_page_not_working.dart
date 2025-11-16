import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/material.dart'; // For Rect

/// A simple class to hold detection results
/// This must be a top-level class or defined in this file to be sendable
/// between isolates.
class Detection {
  final Rect boundingBox;
  final double confidence;
  final String label;

  Detection(this.boundingBox, this.confidence, this.label);
}

/// A simple class to package data for the isolate
class IsolateData {
  final CameraImage cameraImage;
  final int inputWidth;
  final int inputHeight;
  final SendPort sendPort;

  IsolateData(
      this.cameraImage, this.inputWidth, this.inputHeight, this.sendPort);
}

/// The main entry point for the isolate
class InferenceIsolate {
  late Isolate _isolate;
  late SendPort _sendPort;
  final ReceivePort _receivePort = ReceivePort();

  Interpreter? _interpreter;
  List<String> _labels = [];

  // Model input/output details
  // --- FIX: Make these static const ---
  static const int _numClasses = 2; // From your metadata
  static const double _confidenceThreshold = 0.5;
  // --- END OF FIX ---

  /// Starts the isolate and loads the TFLite model.
  Future<void> start() async {
    _isolate = await Isolate.spawn(
      _isolateEntry,
      _receivePort.sendPort,
      onError: _receivePort.sendPort,
      onExit: _receivePort.sendPort,
    );

    // Wait for the isolate to send back its SendPort
    _sendPort = await _receivePort.first;
  }

  /// The static entry point for the new isolate
  static void _isolateEntry(SendPort sendPort) async {
    final ReceivePort isolateReceivePort = ReceivePort();
    sendPort.send(isolateReceivePort.sendPort);

    // This is the new isolate's TFLite instance and labels
    Interpreter? isolateInterpreter;
    List<String> isolateLabels = [];

    // --- 1. Load Model and Labels in the Isolate ---
    try {
      // We need to use ServicesBinding.rootBundle within the isolate
      WidgetsFlutterBinding.ensureInitialized();

      final options = InterpreterOptions();
      isolateInterpreter = await Interpreter.fromAsset(
        'assets/id_card_best_float32.tflite',
        options: options,
      );

      final String labelsContent =
          await rootBundle.loadString('assets/labels.txt');
      isolateLabels =
          labelsContent.split('\n').where((label) => label.isNotEmpty).toList();

      debugPrint('[Isolate] Model and labels loaded successfully.');
      sendPort.send(true); // Signal success
    } catch (e) {
      debugPrint('[Isolate] Error loading model: $e');
      sendPort.send(false); // Signal failure
    }

    // --- 2. Listen for inference requests ---
    await for (final IsolateData isolateData in isolateReceivePort) {
      if (isolateInterpreter == null || isolateLabels.isEmpty) {
        debugPrint('[Isolate] Interpreter not ready.');
        continue;
      }

      // --- This is the heavy lifting, now on a background thread ---
      img.Image? rgbImage;

      // 1. Convert CameraImage to RGB
      if (isolateData.cameraImage.format.group == ImageFormatGroup.bgra8888) {
        rgbImage = _convertBGRAtoRGB(isolateData.cameraImage);
      } else {
        rgbImage = _convertYUVtoRGB(isolateData.cameraImage);
      }

      if (rgbImage == null) continue;

      // 2. Resize for model input
      img.Image resizedImage = img.copyResize(
        rgbImage,
        width: isolateData.inputWidth,
        height: isolateData.inputHeight,
      );

      // 3. Normalize and convert to Float32List
      Float32List inputTensor = _imageToFloat32List(
          resizedImage, isolateData.inputWidth, isolateData.inputHeight);

      // 4. Define output tensor
      List<dynamic> output = List.filled(1 * 6 * 3549, 0).reshape([1, 6, 3549]);

      // 5. Run inference
      try {
        isolateInterpreter.run(
            inputTensor.reshape(
                [1, isolateData.inputHeight, isolateData.inputWidth, 3]),
            output);
      } catch (e) {
        debugPrint('[Isolate] Error running inference: $e');
      }

      // 6. Process output
      List<Detection> detections = _processOutput(
          output[0], isolateLabels, _confidenceThreshold, _numClasses);

      // 7. Send results back to the main thread
      isolateData.sendPort.send(detections);
    }
  }

  /// Sends a CameraImage to the isolate for processing.
  void runInference(CameraImage cameraImage, int inputWidth, int inputHeight) {
    // Send the CameraImage and a SendPort for the reply
    final IsolateData data = IsolateData(
        cameraImage, inputWidth, inputHeight, _receivePort.sendPort);
    _sendPort.send(data);
  }

  /// Listens for results from the isolate.
  Stream<List<Detection>> get resultsStream => _receivePort
      .where((message) => message is List<Detection>)
      .cast<List<Detection>>();

  /// Stops the isolate
  void stop() {
    _isolate.kill(priority: Isolate.immediate);
  }

  // --- Static Image Conversion Helpers (must be static or top-level) ---

  static img.Image? _convertBGRAtoRGB(CameraImage image) {
    try {
      final int width = image.width;
      final int height = image.height;
      final bytes = image.planes[0].bytes;

      var imgData = img.Image(width: width, height: height);
      var imgPixels = imgData.getBytes();

      for (int i = 0, j = 0; i < bytes.length; i += 4, j += 3) {
        imgPixels[j] = bytes[i + 2]; // Red
        imgPixels[j + 1] = bytes[i + 1]; // Green
        imgPixels[j + 2] = bytes[i]; // Blue
      }
      return imgData;
    } catch (e) {
      debugPrint("[Isolate] Error converting BGRA to RGB: $e");
      return null;
    }
  }

  static img.Image? _convertYUVtoRGB(CameraImage image) {
    try {
      final int width = image.width;
      final int height = image.height;
      final int uvRowStride = image.planes[1].bytesPerRow;
      final int uvPixelStride = image.planes[1].bytesPerPixel!;

      final yPlane = image.planes[0].bytes;
      final uPlane = image.planes[1].bytes;
      final vPlane = image.planes[2].bytes;

      var imgData = img.Image(width: width, height: height);

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int uvIndex =
              uvPixelStride * (x / 2).floor() + uvRowStride * (y / 2).floor();
          final int index = y * width + x;

          final yp = yPlane[index];
          final up = uPlane[uvIndex];
          final vp = vPlane[uvIndex];

          int r = (yp + vp * 1.402).round().clamp(0, 255);
          int g = (yp - up * 0.344 - vp * 0.714).round().clamp(0, 255);
          int b = (yp + up * 1.772).round().clamp(0, 255);

          imgData.setPixelRgba(x, y, r, g, b, 255);
        }
      }
      return imgData;
    } catch (e) {
      debugPrint("[Isolate] Error converting YUV to RGB: $e");
      return null;
    }
  }

  static Float32List _imageToFloat32List(
      img.Image image, int inputWidth, int inputHeight) {
    var floatList = Float32List(inputHeight * inputWidth * 3);
    var imgBytes = image.getBytes();
    int pixelIndex = 0;
    for (int i = 0; i < imgBytes.length; i += 3) {
      floatList[pixelIndex++] = imgBytes[i] / 255.0; // Red
      floatList[pixelIndex++] = imgBytes[i + 1] / 255.0; // Green
      floatList[pixelIndex++] = imgBytes[i + 2] / 255.0; // Blue
    }
    return floatList;
  }

  static List<Detection> _processOutput(List<List<double>> output,
      List<String> labels, double confidenceThreshold, int numClasses) {
    List<Detection> detections = [];
    int numDetections = output[0].length; // 3549

    for (int i = 0; i < numDetections; i++) {
      double maxScore = 0;
      int maxScoreIndex = -1;

      for (int j = 0; j < numClasses; j++) {
        double score = output[4 + j][i];
        if (score > maxScore) {
          maxScore = score;
          maxScoreIndex = j;
        }
      }

      if (maxScore > confidenceThreshold) {
        double xCenter = output[0][i];
        double yCenter = output[1][i];
        double w = output[2][i];
        double h = output[3][i];
        double left = (xCenter - w / 2);
        double top = (yCenter - h / 2);

        String label = labels[maxScoreIndex];

        detections.add(
          Detection(
            Rect.fromLTWH(left, top, w, h),
            maxScore,
            label,
          ),
        );
      }
    }
    return detections;
  }
}
