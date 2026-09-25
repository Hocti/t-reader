import 'package:flutter/material.dart';

import 'library.dart';

class LibraryScope extends InheritedNotifier<LibraryController> {
  const LibraryScope({
    required LibraryController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static LibraryController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LibraryScope>();
    assert(scope != null, 'LibraryScope is missing');
    return scope!.notifier!;
  }
}
