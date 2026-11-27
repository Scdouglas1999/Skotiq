/// Where this process's imaging host is, read from its backend.
enum HostPlace {
  /// The rig is this machine: its devices, files and database are in this
  /// process, so paths are local paths and device work happens here.
  rigHere,

  /// A client of an imaging host on another machine, reached over the link.
  linked,

  /// No imaging host at all: a client that is not linked, or whose link was
  /// given up. Every host call fails; screens show what to connect instead.
  none,

  /// The phone's demo rig: simulated equipment inside this app and no
  /// imaging computer. Device calls are answered; host-only features stay
  /// closed, because the demo rig is not a rig.
  demo;

  /// Linked to an imaging host on another machine.
  bool get isLinked => this == linked;

  /// The rig is this machine.
  bool get rigIsHere => this == rigHere;

  /// Not linked to an imaging host and offering the link: no host, or the
  /// demo rig standing in for one.
  bool get offersLink => this == none || this == demo;
}
