import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:soundpool/soundpool.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:image/image.dart' as imglib;
import 'package:flutter/foundation.dart';
import 'package:tflite/tflite.dart';
import 'breedinfo.dart';
import 'dart:io';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intent/intent.dart' as android_intent;
import 'package:intent/action.dart' as android_action;
import 'package:intent/category.dart' as android_category;

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key key}) : super(key: key);
  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  CameraController _controller;
  bool _cameraInitialized = false;
  bool _isDetecting = false;
  String _topText = '';
  Soundpool _pool;
  int _soundId;
  CameraImage _savedImage;
  Map _savedRect;
  Uint8List _snapShot;
  ui.Image _buttonImage;
  bool _showingWiki = false;
  bool _showSnapshot = false;
  bool _tfliteBusy = false;
  String _tempPath;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIOverlays([SystemUiOverlay.bottom]);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
    _initializeApp();
  }

  void _initializeApp() async {
    await PermissionHandler().requestPermissions(<PermissionGroup>[
      PermissionGroup.camera,
      PermissionGroup.storage,
    ]);

    _pool = Soundpool(streamType: StreamType.notification);
    _soundId = await rootBundle
        .load("assets/178186__snapper4298__camera-click-nikon.wav")
        .then((ByteData soundData) {
      return _pool.load(soundData);
    });

    Directory tempDir = await getTemporaryDirectory();
    _tempPath = tempDir.path + '/tempfile.png';

    await Tflite.loadModel(
        model: "assets/ssd_mobilenet.tflite",
        labels: "assets/ssd_mobilenet.txt");

    List<CameraDescription> cameras = await availableCameras();
    _controller = CameraController(cameras[0], ResolutionPreset.medium);
    _controller.initialize().then((_) async {
      _cameraInitialized = true;
      await _controller
          .startImageStream((CameraImage image) => _processCameraImage(image));
      setState(() {});
    });
  }

  void _processCameraImage(CameraImage image) async {
    if (_showingWiki) return;
    if (_isDetecting) return;
    _isDetecting = true;
    Future findDogFuture = _findDog(image);
    List results = await Future.wait(
        [findDogFuture, Future.delayed(Duration(milliseconds: 500))]);
    setState(() {
      _savedImage = image;
      _savedRect = results[0];
    });
    _isDetecting = false;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: GestureDetector(
      onTapDown: (TapDownDetails details) async {
        double mediaHeight = MediaQuery.of(context).size.height;
        if (details.localPosition.dy < mediaHeight * 0.8) return;
        double mediaWidth = MediaQuery.of(context).size.width;
        double xTap = details.localPosition.dx;

        if (xTap < mediaWidth * 0.35) {
          // Left button tapped: show Gallery.
          var intent = android_intent.Intent();
          intent.setAction(android_action.Action.ACTION_MAIN);
          intent.addCategory(android_category.Category.CATEGORY_APP_GALLERY);
          intent.startActivity().catchError((e) => print(e));

        } else if (xTap < mediaWidth * 0.65) {
          // Middle button tapped: process dog inside [_savedRect] in [_savedImage]
           if (_showSnapshot) {
            // Stop showing snapshot if tapped while doing so
            _showSnapshot = false;
            return;
          } else {
            _pool.play(_soundId);
            imglib.Image convertedImage = _convertCameraImage(_savedImage);
            imglib.Image fullImage =
                imglib.copyResize(convertedImage, height: mediaHeight.round());
            imglib.Image croppedImage = fullImage;
            if (_savedRect != null) { // Skip if no yellow frame.
              double x, y, w, h;
              x = (_savedRect["x"] * convertedImage.width);
              y = (_savedRect["y"] * convertedImage.height);
              w = (_savedRect["w"] * convertedImage.width);
              h = (_savedRect["h"] * convertedImage.height);
              croppedImage = imglib.copyCrop(
                  convertedImage, x.round(), y.round(), w.round(), h.round());
              _topText = await _classifyDog(croppedImage);
              int marginToScreen = ((fullImage.width - mediaWidth) / 2).round();
              List breeds = _topText.split('\n');
              imglib.drawString(
                  fullImage, imglib.arial_24, marginToScreen, 20, breeds[0]);
              if (breeds.length > 1)
                imglib.drawString(
                    fullImage, imglib.arial_24, marginToScreen, 44, breeds[1]);
            }

            _snapShot = imglib.encodePng(fullImage);

            imglib.Image button = imglib.copyResizeCropSquare(croppedImage, 40);
            Uint8List buttonPng = imglib.encodePng(button);
            ui.Codec codec = await ui.instantiateImageCodec(buttonPng);
            ui.FrameInfo fi = await codec.getNextFrame();
            _buttonImage = fi.image;
            await ImageGallerySaver.saveImage(_snapShot);

            // Show the snapshot wit text for four seconds
            setState(() {
              _showSnapshot = true;
            });
            Future.delayed(const Duration(seconds: 4), () {
              setState(() {
                _showSnapshot = false;
              });
            });
          }
        } else {
          // Right button tapped: show Wikipedia info about the dog's breed.
          _showingWiki = true;
          String breed = _topText.split('(')[0];
          await Navigator.push(context,
              MaterialPageRoute(builder: (context) =>
                  BreedInfo(breed: breed)));
          _showingWiki = false;
        }
      },
      child: Container(
        child: _cameraInitialized
            ? OverflowBox(
                maxWidth: double.infinity,
                child: AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: _showSnapshot
                        ? Stack(fit: StackFit.expand, children: <Widget>[
                            _snapShot != null
                                ? Image.memory(
                                    _snapShot,
                                  )
                                : Text('wait'),
                            CustomPaint(painter: ButtonsPainter(_buttonImage)),
                          ])
                        : Stack(fit: StackFit.expand, children: <Widget>[
                            CameraPreview(_controller),
                            CustomPaint(painter: ButtonsPainter(_buttonImage)),
                            CustomPaint(painter: RectPainter(_savedRect))
                          ])))
            : Text(
                ' Waiting for camera initialization',
                style: TextStyle(fontSize: 20),
              ),
      ),
    ));
  }

  Future<Map> _findDog(CameraImage image) async {
    if (_tfliteBusy) return null;

    _tfliteBusy = true;
    List resultList = await Tflite.detectObjectOnFrame(
      bytesList: image.planes.map((plane) {
        return plane.bytes;
      }).toList(),
      model: "SSDMobileNet",
      imageHeight: image.height,
      imageWidth: image.width,
      imageMean: 127.5,
      imageStd: 127.5,
      threshold: 0.2, // Could be tweaked.
    );
    _tfliteBusy = false;

    List<String> possibleDog = ['dog', 'cat', 'bear', 'teddy bear', 'sheep'];
    Map biggestRect;
    double rectSize, rectMax = 0.0;
    for (int i = 0; i < resultList.length; i++) {
      if (possibleDog.contains(resultList[i]["detectedClass"])) {
        Map aRect = resultList[i]["rect"];
        rectSize = aRect["w"] * aRect["h"];
        if (rectSize > rectMax) {
          rectMax = rectSize;
          biggestRect = aRect;
        }
      }
    }
    return biggestRect;
  }

  static imglib.Image _convertCameraImage(CameraImage image) {
    int width = image.width;
    int height = image.height;
    var img = imglib.Image(width, height); // Create Image buffer
    const int hexFF = 0xFF000000;
    final int uvyButtonStride = image.planes[1].bytesPerRow;
    final int uvPixelStride = image.planes[1].bytesPerPixel;
    for (int x = 0; x < width; x++) {
      for (int y = 0; y < height; y++) {
        final int uvIndex =
            uvPixelStride * (x / 2).floor() + uvyButtonStride * (y / 2).floor();
        final int index = y * width + x;
        final yp = image.planes[0].bytes[index];
        final up = image.planes[1].bytes[uvIndex];
        final vp = image.planes[2].bytes[uvIndex];
        // Calculate pixel color
        int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
        int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91)
            .round()
            .clamp(0, 255);
        int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);
        // color: 0x FF  FF  FF  FF
        //           A   B   G   R
        img.data[index] = hexFF | (b << 16) | (g << 8) | r;
      }
    }
    // Rotate 90 degrees to upright
    var img1 = imglib.copyRotate(img, 90);
    return img1;
  }

  Future<String> _classifyDog(imglib.Image croppedImage) async {
    while (_tfliteBusy) await Future.delayed(Duration(milliseconds: 100));
    _tfliteBusy = true;

    Uint8List croppedPng = imglib.encodePng(croppedImage);
    try {
      File(_tempPath).deleteSync();
    } catch (e) {
      print(e);
    }
    File(_tempPath).writeAsBytesSync(croppedPng);

    await Tflite.loadModel(
      model: 'assets/model.tflite',
      labels: 'assets/dogs_labels.txt',
    );
    var resultList = await Tflite.runModelOnImage(
      path: _tempPath,
      numResults: 2,
      threshold: 0.05,
      imageMean: 127.5,
      imageStd: 127.5,
    );
    if (resultList.length == 0) return 'Cannot determine breed';

    String breed = resultList[0]["label"].replaceAll('\t', ' ').substring(10);
    breed = breed[0].toUpperCase() + breed.substring(1);
    String conf = (resultList[0]["confidence"] * 100).toStringAsFixed(0);
    String reply = breed + ' (' + conf + '%)';

    if (resultList.length > 1) {
      breed = resultList[1]["label"].replaceAll('\t', ' ').substring(10);
      breed = breed[0].toUpperCase() + breed.substring(1);
      conf = (resultList[1]["confidence"] * 100).toStringAsFixed(0);
      reply = reply + '\n' + breed + ' (' + conf + '%)';
    }

    await Tflite.loadModel(
        model: "assets/ssd_mobilenet.tflite",
        labels: "assets/ssd_mobilenet.txt");
    _tfliteBusy = false;

    return reply;
  }
}

class RectPainter extends CustomPainter {
  Map rect;
  RectPainter(this.rect);
  @override
  void paint(Canvas canvas, Size size) {
    if (rect != null) {
      final paint = Paint();
      paint.color = Colors.yellow;
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 2.0;
      double x, y, w, h;
      x = rect["x"] * size.width;
      y = rect["y"] * size.height;
      w = rect["w"] * size.width;
      h = rect["h"] * size.height;
      Rect rect1 = Offset(x, y) & Size(w, h);
      canvas.drawRect(rect1, paint);
    }
  }

  @override
  bool shouldRepaint(RectPainter oldDelegate) => oldDelegate.rect != rect;
}

class ButtonsPainter extends CustomPainter {
  ui.Image buttonImage;
  ButtonsPainter(this.buttonImage);

  @override
  void paint(Canvas canvas, Size size) {
    var paint = Paint();
    // First paint black field around buttons with low opacity
    paint.color = Colors.black.withOpacity(0.1);
    Rect rect =
        Offset(0.0, size.height * 0.8) & Size(size.width, size.height * 0.2);
    canvas.drawRect(rect, paint);

    // Draw buttons at 10% from the bottom
    final double yButton = size.height * 0.9;
    paint.style = PaintingStyle.fill;
    paint.color = Colors.grey;
    final double canvasWidth = size.width;
    double xButton;
    var icon;

    // Paint left button if no  buttonImage supplied
    if (buttonImage == null) {
      xButton = canvasWidth * 0.3;
      icon = Icons.photo_library;
      canvas.drawCircle(Offset(xButton, yButton), 22.0, paint);
      var builder = ui.ParagraphBuilder(ui.ParagraphStyle(
        fontFamily: icon.fontFamily,
        fontSize: 25.0,
      ))
        ..addText(String.fromCharCode(icon.codePoint));
      var para = builder.build();
      para.layout(const ui.ParagraphConstraints(width: 100.0));
      canvas.drawParagraph(para, Offset(xButton - 12.5, yButton - 12.5));
    }

    //Paint middle button.
    xButton = canvasWidth * 0.5;
    canvas.drawCircle(Offset(xButton, yButton), 32.0, paint);
    paint.color = Colors.white;
    canvas.drawCircle(Offset(xButton, yButton), 28.0, paint);

    // Paint right button.
    xButton = canvasWidth * 0.7;
    icon = Icons.info_outline;
    paint.color = Colors.grey;
    canvas.drawCircle(Offset(xButton, yButton), 22.0, paint);
    var builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: icon.fontFamily,
      fontSize: 25.0,
    ))
      ..addText(String.fromCharCode(icon.codePoint));
    var para = builder.build();
    para.layout(const ui.ParagraphConstraints(width: 100.0));
    canvas.drawParagraph(para, Offset(xButton - 12.5, yButton - 12.5));

    // Paint image on left button
    if (buttonImage != null) {
      xButton = canvasWidth * 0.3;
      // First set up a round clipping area.
      double radius = 22.0;
      double l, t, r, b;
      l = xButton - radius;
      r = xButton + radius;
      t = yButton - radius;
      b = yButton + radius;
      ui.Rect clippingRect = Rect.fromLTRB(l, t, r, b);
      RRect clippingArea =
          RRect.fromRectAndRadius(clippingRect, Radius.circular(radius));
      canvas.clipRRect(clippingArea);
      // Then draw the square button image over the round clipping area
      double x, y = 0.0;
      x = xButton - buttonImage.height / 2.0;
      y = yButton - buttonImage.width / 2.0;
      Offset buttonOffset = Offset(x, y);
      canvas.drawImage(buttonImage, buttonOffset, Paint());
    }
  }

  @override
  bool shouldRepaint(ButtonsPainter oldDelegate) =>
      oldDelegate.buttonImage != buttonImage;
}