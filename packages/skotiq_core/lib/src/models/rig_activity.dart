/// The activities that drive the camera or the mount, one owner at a time.
enum RigActivity {
  flats('flat capture', 'A flat capture is using the camera'),
  flip('meridian flip', 'A meridian flip is using the mount'),
  sequence('sequence', 'The sequencer is using the camera'),
  manualCapture('manual capture', 'A manual capture is using the camera');

  const RigActivity(this.operation, this.busy);

  /// The activity in a few words ("flat capture").
  final String operation;

  /// Why another activity cannot start while this one runs.
  final String busy;
}
