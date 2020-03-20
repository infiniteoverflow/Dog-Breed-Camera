
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class BreedInfo extends StatelessWidget {
  final String breed;
  BreedInfo({Key key, @required this.breed});

  @override
  Widget build(BuildContext context) {
    String url = 'https://en.wikipedia.org/wiki/' + breed;
    return Scaffold(
      appBar: AppBar(
          backgroundColor: Colors.black,
          title: Text('Wikipedia about ...')),
      body:WebView(
          key: UniqueKey(),
          javascriptMode: JavascriptMode.disabled,
          initialUrl: url),
    );
  }
}