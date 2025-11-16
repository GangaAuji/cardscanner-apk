import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'dart:math' as math;
import 'captured_cards_screen.dart';

// A simple class to hold detection results
class Detection {
  final Rect boundingBox;
  final double confidence;
  final String label;

  Detection(this.boundingBox, this.confidence, this.label);
}

class CardDetectorPage extends StatefulWidget {
  const CardDetectorPage({super.key});

  @override
  State<CardDetectorPage> createState() => _CardDetectorPageState();
}

class _CardDetectorPageState extends State<CardDetectorPage>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  Interpreter? _interpreter;
  List<String> _labels = []; // To store class labels

  bool _isCameraInitialized = false;
  bool _isDetecting = false;
  bool _shouldCapture = false;
  List<Detection> _detections = [];
  img.Image? _currentFrameImage; // To store the full-res image for cropping

  // Frame skipping for performance - AGGRESSIVE
  int _frameCount = 0;
  int _frameSkip = 10; // Process every 10th frame for better performance
  int _processingTime = 0; // Track processing time in ms
  bool _isProcessingAsync = false; // Track if async processing is running

  // Detection state tracking
  int _stableDetectionCount = 0;
  final int _requiredStableFrames = 3; // Reduced to 3 for faster feedback
  bool _hasLoggedSample = false; // Flag to log model output once

  // State variable to hold the user instruction message
  String _instructionMessage = "Position ID card inside the frame";

  // Thresholds for guidance
  final double _guideConfidenceThreshold = 0.65;
  final double _minAreaThreshold = 0.25; // 25% of view area
  final double _maxAreaThreshold = 0.70; // 70% of view area
  final double _optimalMinArea = 0.35; // 35% - optimal minimum
  final double _optimalMaxArea = 0.55; // 55% - optimal maximum

  // Model input/output details - Must match model training size
  final int _inputWidth = 416; // Model expects 416x416
  final int _inputHeight = 416; // Model expects 416x416
  // Output: [1, 6, 3549] - [batch, properties, num_boxes]
  // Properties: [x, y, w, h, class_0_score, class_1_score]
  final double _confidenceThreshold =
      0.7; // Higher threshold to filter false positives
  final int _numClasses = 2; // Based on your metadata.yaml
  final int _propertiesPerBox = 6; // x, y, w, h, score_0, score_1

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    // 1. Request permissions
    await _requestPermissions();

    // 2. Load TFLite model and labels
    await _loadModel();
    await _loadLabels();

    // 3. Initialize camera
    await _initializeCamera();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.camera,
      Permission.storage, // Or Permission.photos on iOS
    ].request();
  }

  Future<void> _loadModel() async {
    try {
      // --- FIX: This function should ONLY load the model. ---
      // All camera-related logic has been removed from here.
      final options = InterpreterOptions();
      _interpreter = await Interpreter.fromAsset(
        'assets/id_card_best_float32.tflite',
        options: options,
      );
      debugPrint('TFLite model loaded successfully.');
      // --- END OF FIX ---
    } catch (e) {
      debugPrint('Failed to load TFLite model: $e');
    }
  }

  Future<void> _loadLabels() async {
    try {
      // Load the new labels file
      final String labelsContent =
          await rootBundle.loadString('assets/labels.txt');
      _labels =
          labelsContent.split('\n').where((label) => label.isNotEmpty).toList();
      debugPrint('Labels loaded: $_labels');
    } catch (e) {
      debugPrint('Failed to load labels file: $e');
    }
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      debugPrint('No cameras available.');
      return;
    }

    _cameraController = CameraController(
      cameras[0], // Use the first available camera (usually rear)
      ResolutionPreset.low, // <-- FIX 1: Use low res for much faster processing
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.bgra8888, // <-- Keep BGRA for speed
    );

    try {
      // --- CRITICAL FIX: Await initialization FIRST. ---
      await _cameraController!.initialize();

      // --- THEN, start the image stream. ---
      _cameraController!.startImageStream((CameraImage cameraImage) {
        // Skip frames aggressively for performance
        _frameCount++;
        if (_frameCount % _frameSkip != 0) return;

        // Skip if already processing or resources not ready
        if (_isDetecting ||
            _isProcessingAsync ||
            _interpreter == null ||
            _labels.isEmpty) return;

        _isDetecting = true;
        _isProcessingAsync = true;
        _runInference(cameraImage);
      });

      // --- FINALLY, set state to true to build the UI. ---
      setState(() => _isCameraInitialized = true);
      debugPrint('Camera initialized.');
    } catch (e) {
      debugPrint('Failed to initialize camera: $e');
    }
  }

  Future<void> _runInference(CameraImage cameraImage) async {
    final startTime = DateTime.now().millisecondsSinceEpoch;

    try {
      // 1. Convert CameraImage to RGB Image - OPTIMIZED
      img.Image? rgbImage;
      if (cameraImage.format.group == ImageFormatGroup.bgra8888) {
        rgbImage = _convertBGRAtoRGB(cameraImage);
      } else {
        rgbImage = _convertYUVtoRGB(cameraImage);
      }

      if (rgbImage == null) {
        _isDetecting = false;
        _isProcessingAsync = false;
        return;
      }

      // 2. Resize DIRECTLY for model input - skip storing full-res unless capturing
      img.Image resizedImage = img.copyResize(
        rgbImage,
        width: _inputWidth,
        height: _inputHeight,
        interpolation: img.Interpolation.nearest, // Faster interpolation
      );

      // Only store full-res when we might capture
      if (_shouldCapture) {
        _currentFrameImage = rgbImage;
      }

      // 3. Normalize and convert to Float32List (input tensor)
      Float32List inputTensor = _imageToFloat32List(resizedImage);

      // 4. Define output tensor
      // Your output shape is [1, 6, 3549].
      List<dynamic> output = List.filled(1 * _propertiesPerBox * 3549, 0)
          .reshape([1, _propertiesPerBox, 3549]);

      // 5. Run inference
      _interpreter!
          .run(inputTensor.reshape([1, _inputHeight, _inputWidth, 3]), output);

      // 6. Process the output
      List<Detection> detections = _processOutput(output[0]);

      // Logic for user guidance with improved messages
      String newMessage;

      if (detections.isEmpty) {
        newMessage = "Position ID card inside the frame";
        _stableDetectionCount = 0;
      } else {
        // Sort to get the best detection
        detections.sort((a, b) => b.confidence.compareTo(a.confidence));
        final Detection bestDetection = detections.first;
        final double area =
            bestDetection.boundingBox.width * bestDetection.boundingBox.height;

        if (bestDetection.confidence < _guideConfidenceThreshold) {
          newMessage = "Hold steady - Detecting card...";
          _stableDetectionCount = 0;
        } else if (area < _minAreaThreshold) {
          newMessage = "Move closer - Card too far";
          _stableDetectionCount = 0;
        } else if (area > _maxAreaThreshold) {
          newMessage = "Move back - Card too close";
          _stableDetectionCount = 0;
        } else {
          // Check if in optimal range
          if (area >= _optimalMinArea && area <= _optimalMaxArea) {
            _stableDetectionCount++;
            if (_stableDetectionCount >= _requiredStableFrames) {
              newMessage = "✓ Perfect! Tap capture button";
            } else {
              newMessage =
                  "Hold steady... ${_stableDetectionCount}/${_requiredStableFrames}";
            }
          } else {
            newMessage = "Adjust position slightly";
            _stableDetectionCount = 0;
          }
        }
      }

      // 7. Check if we should capture an image
      if (_shouldCapture && detections.isNotEmpty) {
        // Find the best detection (highest confidence)
        await _captureAndCrop(detections.first);
        _shouldCapture = false;
      }

      // Track processing time
      final endTime = DateTime.now().millisecondsSinceEpoch;
      _processingTime = endTime - startTime;

      // Update UI only if mounted
      if (mounted) {
        setState(() {
          _detections = detections;
          _instructionMessage = newMessage;
        });
      }
    } catch (e) {
      debugPrint('Error in inference: $e');
    } finally {
      _isDetecting = false;
      _isProcessingAsync = false;
    }
  }

  double _sigmoid(double x) {
    return 1.0 / (1.0 + math.exp(-x));
  }

  List<Detection> _processOutput(List<List<double>> output) {
    // Input is [6, 3549]
    // Properties are at indices:
    // 0: x_center
    // 1: y_center
    // 2: width
    // 3: height
    // 4: class_0_score
    // 5: class_1_score

    List<Detection> detections = [];
    int numDetections = output[0].length; // 3549

    // Debug: Log sample values ONCE to understand model output
    if (!_hasLoggedSample && numDetections > 0) {
      _hasLoggedSample = true;
      debugPrint('=== MODEL OUTPUT SAMPLE ===');
      for (int idx in [0, 100, 500, 1000, 2000]) {
        if (idx < numDetections) {
          double rawC0 = output[4][idx];
          double rawC1 = output[5][idx];
          double sigC0 = _sigmoid(rawC0);
          double sigC1 = _sigmoid(rawC1);
          debugPrint(
              'Anchor $idx: c0_raw=$rawC0 c1_raw=$rawC1 | c0_sig=$sigC0 c1_sig=$sigC1');
        }
      }
      debugPrint('===========================');
    }

    for (int i = 0; i < numDetections; i++) {
      // Find the class with the highest score
      double maxScore = 0;
      int maxScoreIndex = -1;

      // Get class scores from indices 4 and 5, apply sigmoid activation
      for (int j = 0; j < _numClasses; j++) {
        double rawScore = output[4 + j][i];
        double score = _sigmoid(
            rawScore); // Apply sigmoid to convert logits to probabilities
        if (score > maxScore) {
          maxScore = score;
          maxScoreIndex = j;
        }
      }

      // Check if the highest score meets the confidence threshold
      if (maxScore > _confidenceThreshold) {
        // Coordinates are normalized [0, 1] relative to 416x416 input
        double xCenter = output[0][i];
        double yCenter = output[1][i];
        double w = output[2][i];
        double h = output[3][i];

        // Convert from [center, w, h] to [left, top, w, h] for Rect
        double left = (xCenter - w / 2);
        double top = (yCenter - h / 2);

        String label = _labels[maxScoreIndex];

        detections.add(
          Detection(
            Rect.fromLTWH(left, top, w, h), // Normalized coordinates
            maxScore,
            label,
          ),
        );
      }
    }

    if (detections.isNotEmpty) {
      debugPrint('Found ${detections.length} valid detections');
    }
    // You should apply Non-Max Suppression (NMS) here to filter overlapping boxes
    // For simplicity, we'll skip NMS, but it's crucial for good results.

    return detections;
  }

  Future<void> _captureAndCrop(Detection bestDetection) async {
    if (_currentFrameImage == null) return;

    // 1. Get original image dimensions
    final int originalWidth = _currentFrameImage!.width;
    final int originalHeight = _currentFrameImage!.height;

    // 2. Scale the normalized bounding box to the original image dimensions
    // Note: The camera preview might be landscape, so width > height
    final double scaleX = originalWidth.toDouble();
    final double scaleY = originalHeight.toDouble();

    final int x = (bestDetection.boundingBox.left * scaleX)
        .toInt()
        .clamp(0, originalWidth);
    final int y = (bestDetection.boundingBox.top * scaleY)
        .toInt()
        .clamp(0, originalHeight);
    final int w = (bestDetection.boundingBox.width * scaleX).toInt();
    final int h = (bestDetection.boundingBox.height * scaleY).toInt();

    // Ensure cropped coordinates are valid
    if (x + w > originalWidth) {
      debugPrint('Cropped width exceeds image width.');
      // w = originalWidth - x; // You could clamp it
    }
    if (y + h > originalHeight) {
      debugPrint('Cropped height exceeds image height.');
      // h = originalHeight - y; // You could clamp it
    }

    // 3. Crop the image from the full-resolution frame
    img.Image croppedImage = img.copyCrop(
      _currentFrameImage!,
      x: x,
      y: y,
      width: w,
      height: h,
    );

    // 4. Get a path to save the file
    final Directory appDir = await getApplicationDocumentsDirectory();
    final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final String filePath = '${appDir.path}/card_$timestamp.png';

    // 5. Save the cropped image
    try {
      File(filePath).writeAsBytesSync(img.encodePng(croppedImage));
      debugPrint('Image saved to $filePath');

      // Show a confirmation with navigation option
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Card saved to $filePath'),
            action: SnackBarAction(
              label: 'View',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const CapturedCardsScreen(),
                  ),
                );
              },
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('Failed to save image: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive) {
      _cameraController!.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  @override
  void dispose() {
    // --- FIX 3: Stop the stream to prevent crash on hot restart ---
    _cameraController?.stopImageStream();
    // --- END OF FIX ---
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCameraInitialized) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('ID Card Scanner'),
        backgroundColor: Colors.blue.shade700,
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library),
            tooltip: 'View Captured Cards',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const CapturedCardsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: OrientationBuilder(
        builder: (context, orientation) {
          return Stack(
            fit: StackFit.expand,
            children: [
              // Camera Preview with proper aspect ratio
              Center(
                child: AspectRatio(
                  aspectRatio: _cameraController!.value.aspectRatio,
                  child: CameraPreview(_cameraController!),
                ),
              ),

              // Bounding Boxes
              CustomPaint(
                painter: BoundingBoxPainter(
                  detections: _detections,
                  previewSize: _cameraController!.value.previewSize!,
                  screenSize: MediaQuery.of(context).size,
                ),
              ),

              // Card Frame Guide Overlay - only show when card is detected
              if (_detections.isNotEmpty)
                Center(
                  child: Container(
                    width: MediaQuery.of(context).size.width * 0.85,
                    height: MediaQuery.of(context).size.width *
                        0.85 *
                        0.63, // ID card aspect ratio
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.greenAccent,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),

              // Instruction Message with visual feedback
              Positioned(
                bottom: 100,
                left: 20,
                right: 20,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                  decoration: BoxDecoration(
                    color: _stableDetectionCount >= _requiredStableFrames
                        ? Colors.green.withOpacity(0.9)
                        : Colors.black.withOpacity(0.75),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _stableDetectionCount >= _requiredStableFrames
                          ? Colors.greenAccent
                          : Colors.white.withOpacity(0.3),
                      width: 2,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_stableDetectionCount >= _requiredStableFrames)
                        const Icon(
                          Icons.check_circle,
                          color: Colors.white,
                          size: 24,
                        ),
                      if (_stableDetectionCount >= _requiredStableFrames)
                        const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          _instructionMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Performance Indicator (Top Right)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'FPS: ${_processingTime > 0 ? (1000 / (_processingTime * _frameSkip)).toStringAsFixed(1) : "0"}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          if (_detections.isNotEmpty &&
              _stableDetectionCount >= _requiredStableFrames) {
            _shouldCapture = true;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('📸 Capturing card...'),
                duration: Duration(seconds: 1),
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('⚠️ Position card correctly first'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        },
        icon: const Icon(Icons.camera_alt),
        label: const Text('Capture'),
        backgroundColor: _stableDetectionCount >= _requiredStableFrames
            ? Colors.green
            : Colors.blue,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  // --- Image Conversion Helpers ---

  img.Image? _convertBGRAtoRGB(CameraImage image) {
    // This is a faster conversion than YUV
    try {
      final int width = image.width;
      final int height = image.height;
      final bytes = image.planes[0].bytes;

      var imgData = img.Image(width: width, height: height);
      var imgPixels = imgData.getBytes();

      for (int i = 0, j = 0; i < bytes.length; i += 4, j += 3) {
        // BGRA8888 to RGB888
        // We can also just use the B, G, R channels and ignore A
        imgPixels[j] = bytes[i + 2]; // Red
        imgPixels[j + 1] = bytes[i + 1]; // Green
        imgPixels[j + 2] = bytes[i]; // Blue
      }

      // Handle device rotation
      final rotation = _cameraController?.value.deviceOrientation;
      if (rotation == null) return imgData;

      switch (rotation) {
        case DeviceOrientation.portraitUp:
          return img.copyRotate(imgData, angle: 90);
        case DeviceOrientation.landscapeLeft:
          return imgData;
        case DeviceOrientation.landscapeRight:
          return img.copyRotate(imgData, angle: 180);
        case DeviceOrientation.portraitDown:
          return img.copyRotate(imgData, angle: -90);
      }
    } catch (e) {
      debugPrint("Error converting BGRA to RGB: $e");
      return null;
    }
  }

  img.Image? _convertYUVtoRGB(CameraImage image) {
    // This conversion is expensive.
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
      // Handle device rotation
      final rotation = _cameraController?.value.deviceOrientation;
      if (rotation == null) return imgData; // Default if controller is disposed

      switch (rotation) {
        case DeviceOrientation.portraitUp:
          return img.copyRotate(imgData, angle: 90);
        case DeviceOrientation.landscapeLeft:
          return imgData;
        case DeviceOrientation.landscapeRight:
          return img.copyRotate(imgData, angle: 180);
        case DeviceOrientation.portraitDown:
          return img.copyRotate(imgData, angle: -90);
      }
    } catch (e) {
      debugPrint("Error converting YUV to RGB: $e");
      return null;
    }
  }

  Float32List _imageToFloat32List(img.Image image) {
    var floatList = Float32List(_inputHeight * _inputWidth * 3);
    var imgBytes = image.getBytes(); // Get the byte buffer
    int pixelIndex = 0;

    for (int i = 0; i < imgBytes.length; i += 3) {
      // Assuming imgBytes is RGB format from our _convertBGRAtoRGB
      // This avoids the slow getPixel() method.
      floatList[pixelIndex++] = imgBytes[i] / 255.0; // Red
      floatList[pixelIndex++] = imgBytes[i + 1] / 255.0; // Green
      floatList[pixelIndex++] = imgBytes[i + 2] / 255.0; // Blue
    }
    return floatList;
  }
}

// --- Bounding Box Painter ---

class BoundingBoxPainter extends CustomPainter {
  final List<Detection> detections;
  final Size previewSize; // Size of the camera feed (e.g., 1280x720)
  final Size screenSize; // Size of the phone screen

  BoundingBoxPainter({
    required this.detections,
    required this.previewSize,
    required this.screenSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;

    final paint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;

    final fillPaint = Paint()
      ..color = Colors.greenAccent.withOpacity(0.2)
      ..style = PaintingStyle.fill;

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    // Calculate scale and offset to map preview size to screen size
    final double scaleX = screenSize.width / previewSize.height;
    final double scaleY = screenSize.height / previewSize.width;
    // Use 'min' to fit the preview within the screen, letterboxing if needed
    final double scale = math.min(scaleX, scaleY);

    final double offsetX = (screenSize.width - previewSize.height * scale) / 2;
    final double offsetY = (screenSize.height - previewSize.width * scale) / 2;

    for (var detection in detections) {
      // 1. Scale normalized [0,1] box to preview dimensions
      //    We swap height/width because the preview is rotated 90deg in portrait
      final Rect previewRect = Rect.fromLTWH(
        detection.boundingBox.left * previewSize.height,
        detection.boundingBox.top * previewSize.width,
        detection.boundingBox.width * previewSize.height,
        detection.boundingBox.height * previewSize.width,
      );

      // 2. Scale and offset previewRect to screenRect
      final Rect screenRect = Rect.fromLTWH(
        previewRect.left * scale + offsetX,
        previewRect.top * scale + offsetY,
        previewRect.width * scale,
        previewRect.height * scale,
      );

      // Draw filled rectangle
      canvas.drawRect(screenRect, fillPaint);
      // Draw rectangle border
      canvas.drawRect(screenRect, paint);

      // Draw label with confidence
      final text =
          '${detection.label} ${(detection.confidence * 100).toStringAsFixed(0)}%';
      textPainter.text = TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          backgroundColor: Colors.green,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(screenRect.left, screenRect.top - 25),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}
