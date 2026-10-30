import 'package:flutter/material.dart';

/// Fixed colors encode imagery and measurements, never selected controls.
abstract final class ImageOverlayColors {
  static const foreground = Color(0xFFFFFFFF);
  static const secondary = Color(0xB3FFFFFF);
  static const muted = Color(0x99FFFFFF);
  static const faint = Color(0x8AFFFFFF);
  static const disabled = Color(0x61FFFFFF);
  static const divider = Color(0x3DFFFFFF);
  static const scrim = Color(0x8A000000);
  static const shadow = Color(0xFF000000);
  static const labelBackground = Color(0xAA000000);
  static const labelBorder = Color(0x55FFFFFF);
  static const coordinateGrid = Color(0x40008888);
  static const coordinateLabel = Color(0xA0CCDDDD);
  static const coordinateLabelBackground = Color(0x60000000);
  static const skyBackground = Color(0xFF0A0A1A);
  static const catalogMarker = Color(0xFFFFE082);
  static const catalogStar = Color(0xFFB3E5FC);
  static const finderGrid = Color(0x80FFFFFF);
  static const finderConstellation = Color(0x90CCCCCC);
  static const finderEcliptic = Color(0x80FFD700);
  static const finderGalacticPlane = Color(0x8000CED1);
  static const finderHorizon = Color(0xA0FF6633);
  static const north = Color(0xFFFF4444);
  static const east = Color(0xFF44AAFF);
}

abstract final class SciencePlotColors {
  static const temperatureCool = Color(0xFF4F8BFF);
  static const temperatureMid = Color(0xFFB9A26A);
  static const temperatureWarm = Color(0xFFFF8A3D);
  static const surfaceLow = Color(0xFF1D4ED8);
  static const surfaceHigh = Color(0xFFDC2626);
  static const psfTight = Color(0xFF0B6E4F);
  static const psfBloated = Color(0xFFC0392B);
  static const noMeasurement = Color(0xFF4A5568);
  static const residualShaft = Color(0xFFF1C40F);
  static const residualHead = Color(0xFFF39C12);
  static const uniformityFlat = Color(0xFF0B3D91);
  static const uniformityStrong = Color(0xFFFF8C42);
  static const lowConfidence = Color(0xFFF59E0B);
  static const highConfidence = Color(0xFF22C55E);
  static const clipLow = Color(0xFF3B82F6);
  static const clipHigh = Color(0xFFEF4444);
}

abstract final class FieldOfViewColors {
  static const green = Color(0xFF00E676);
  static const greenTint = Color(0x1A00E676);
  static const blue = Color(0xFF42A5F5);
  static const amber = Color(0xFFFFB300);
  static const red = Color(0xFFFF5252);
  static const violet = Color(0xFFAB47BC);
  static const cyan = Color(0xFF26C6DA);
}

abstract final class EquipmentProfileColors {
  static const defaultProfile = Color(0xFF5B9EC4);
  static const sky = Color(0xFF3A9BC4);
  static const pink = Color(0xFFEC4899);
  static const orange = Color(0xFFF97316);
  static const yellow = Color(0xFFEAB308);
  static const cyan = Color(0xFF06B6D4);
  static const blue = Color(0xFF4A7FB8);
}

/// Fixed sky-map identities and observing-condition plot bands.
abstract final class SkyPlotColors {
  static const good = Color(0xFF4CAF50);
  static const caution = Color(0xFFFFC107);
  static const poor = Color(0xFFF44336);
  static const horizon = Color(0xFFFF9800);
  static const target = Color(0xFF2196F3);
  static const measurement = Color(0xFFFF5722);
  static const schematic = Color(0xFF7DD3FC);
  static const annotationBackground = Color(0xCC0B1622);
  static const skyTop = Color(0xFF15151F);
  static const skyBottom = Color(0xFF0A0A12);
  static const nebulaGlow = Color(0xFFFF4081);
  static const galaxy = Color(0xFFBD8EC4);
  static const nebula = Color(0xFFE86A6A);
  static const openCluster = Color(0xFF6B95B8);
  static const globularCluster = Color(0xFFCB8847);
  static const planetaryNebula = Color(0xFF4FC3C8);
  static const star = Color(0xFFC4A055);
  static const unknown = Color(0xFF8E97A4);
}
