# ID Card Scanner - Testing Guide

## Critical Fixes Applied

### 1. **Model Input Size Corrected**
- Changed back from 320x320 to **416x416** (as required by model)
- Model metadata shows: `tensor: float32[1,416,416,3]`
- This was causing detection failures

### 2. **Detection Threshold Lowered**
- Reduced from 0.5 to **0.4** for better detection sensitivity
- Added extensive debug logging to track detection process

### 3. **UI Made Responsive**
- Added `OrientationBuilder` for portrait/landscape support
- Camera preview wrapped in `AspectRatio` widget
- Frame guide overlay to help users align card

### 4. **Bounding Boxes Enhanced**
- Bright green color with semi-transparent fill
- Thicker borders (4px)
- Larger text labels
- Debug logging for each drawn box

## How to Test

### Step 1: Run the App
```bash
flutter run
```

### Step 2: Check Console Output
Watch for these debug messages:
- `TFLite model loaded successfully.`
- `Labels loaded: [id-card, ID CARD]`
- `Camera initialized.`
- `Processing 3549 potential detections...`
- `Detection found! Score: 0.XXX, Class: X`
- `Box: center(X, Y), size(W, H)`
- `Total valid detections: N`
- `Drawing N bounding boxes...`
- `Detection: id-card, conf: 0.XXX`
- `Drawing rect at: Rect.fromLTRB(...)`

### Step 3: Test Detection
1. **Point camera at an ID card** (Aadhaar, driver's license, etc.)
2. **Watch the frame guide overlay** - it should turn green when card detected
3. **Look for green bounding box** around the detected card
4. **Check the instruction message** at bottom - should update based on card position

### Step 4: Test in Different Orientations
1. **Portrait mode**: Hold phone vertically
2. **Landscape mode**: Rotate phone horizontally
3. UI should adapt automatically

### Step 5: Test Capture
1. Position card until message shows "✓ Perfect! Tap capture button"
2. Capture button should turn green
3. Tap to capture
4. Check gallery (top-right icon) for captured image

## If Detection Still Not Working

### Debug Checklist:

1. **Check Console for Detection Messages**
   - If you see "Processing 3549 potential detections..." but no "Detection found!" messages, the model isn't finding anything above threshold

2. **Try Lower Threshold** (line 67)
   ```dart
   final double _confidenceThreshold = 0.3; // Try even lower
   ```

3. **Verify Model is Loaded**
   - Check for "TFLite model loaded successfully." in console
   - If missing, check `assets/id_card_best_float32.tflite` exists

4. **Check Labels File**
   - Look for "Labels loaded: [id-card, ID CARD]" in console
   - Verify `assets/labels.txt` has two lines

5. **Test with Different Cards**
   - Some cards may be easier to detect
   - Try with better lighting
   - Ensure card fills ~40-60% of the frame guide

### Expected Detection Output:
```
flutter: Processing 3549 potential detections...
flutter: Detection found! Score: 0.723, Class: 0
flutter: Box: center(0.523, 0.412), size(0.456, 0.287)
flutter: Total valid detections: 1
flutter: Drawing 1 bounding boxes...
flutter: Detection: id-card, conf: 0.723
flutter: Drawing rect at: Rect.fromLTRB(123.4, 234.5, 567.8, 456.7)
```

## Performance Monitoring

- **FPS counter** shows in top-right corner
- Should see ~12-15 FPS (processing every 5th frame)
- Camera preview should be smooth at 60 FPS

## Known Issues

1. **First few frames might be slow** - Model warmup period
2. **Detection works best with good lighting**
3. **Card should be relatively flat and in focus**
4. **Background should be contrasting with card**

## Model Information

- **Input**: `float32[1, 416, 416, 3]` - RGB image
- **Output**: `float32[1, 6, 3549]` - [batch, properties, anchors]
- **Properties**: [x_center, y_center, width, height, class_0_score, class_1_score]
- **Classes**: 0=id-card, 1=ID CARD
- **Anchors**: 3549 detection boxes at various scales

## Visual Features

1. **Card Frame Guide**: White/green border showing where to place card
2. **Bounding Boxes**: Green boxes around detected cards
3. **Confidence Labels**: Shows card type and confidence %
4. **Status Messages**: Real-time guidance at bottom
5. **FPS Counter**: Performance indicator at top-right
6. **Capture Button**: Changes color when ready (green = good to capture)
