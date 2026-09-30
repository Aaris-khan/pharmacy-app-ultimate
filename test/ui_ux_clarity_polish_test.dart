import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('idle form controls keep a visible neutral boundary', () {
    final design = File('lib/ui/design.dart').readAsStringSync();
    final search = File('lib/ui/search_screen.dart').readAsStringSync();
    final editor = File('lib/ui/editor_screen.dart').readAsStringSync();

    expect(design, contains('const controlOutline = Color(0xFF8194AC);'));
    expect(
      design,
      contains('borderSide: const BorderSide(color: controlOutline)'),
    );
    expect(search, contains('BorderSide(color: controlOutline)'));
    expect(editor, contains('_editorBorder(color: controlOutline)'));

    expect(
      search,
      isNot(contains('color: primary.withValues(alpha: .08)')),
      reason: 'The idle search outline should not disappear into the glass face.',
    );
  });

  test('navigation motion keeps a stable icon footprint and restrained lift', () {
    final source = File('lib/app.dart').readAsStringSync();
    final start = source.indexOf('class _AnimatedNavigationIcon');
    expect(start, greaterThanOrEqualTo(0));
    final navigation = source.substring(start);

    expect(navigation, contains('SizedBox.square('));
    expect(navigation, contains('dimension: 32'));
    expect(navigation, contains('scale: selected && !reduceMotion ? 1.035 : 1'));
    expect(navigation, contains("? const Offset(0, -.04)"));
    expect(navigation, contains('final duration = reduceMotion'));
    expect(navigation, contains('? Duration.zero'));
  });

  test('secondary controls stay visible and navigation owns one surface', () {
    final design = File('lib/ui/design.dart').readAsStringSync();

    expect(
      design,
      contains('side: const BorderSide(color: controlOutline)'),
      reason: 'Outlined actions and chips should not fade into white surfaces.',
    );

    final start = design.indexOf(
      'navigationBarTheme: NavigationBarThemeData(',
    );
    final end = design.indexOf('class Surface', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final navigationTheme = design.substring(start, end);

    expect(navigationTheme, contains('backgroundColor: Colors.transparent'));
    expect(navigationTheme, contains('elevation: 0'));
    expect(navigationTheme, contains('shadowColor: Colors.transparent'));
    expect(
      navigationTheme,
      isNot(contains('Colors.white.withValues(alpha: .92)')),
      reason: 'The outer GlassPanel should be the only navigation surface.',
    );
  });

}
