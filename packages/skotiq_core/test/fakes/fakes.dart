// Barrel for shared test fakes living under `packages/skotiq_core/test/`.
//
// Why: a single import path keeps test files insulated from how the fakes
// are organised on disk. New fakes (Drift in-memory wrappers, fake event
// streams, etc.) should be added here so they can be picked up uniformly.

export 'fake_network_client.dart';
