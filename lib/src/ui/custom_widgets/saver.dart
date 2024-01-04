import 'package:flutter/material.dart';

class Saver extends StatelessWidget {
  const Saver({
    required this.onPressed,
    required this.child,
    super.key,
    this.alignment = Alignment.bottomRight,
  });

  final Widget child;
  final void Function() onPressed;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: GestureDetector(
        onTap: onPressed,
        child: child,
      ),
    );
  }
}

class SaverConfig {
  const SaverConfig({
    required this.child,
    this.alignment = Alignment.bottomRight,
  });

  final Widget child;
  final Alignment alignment;
}
