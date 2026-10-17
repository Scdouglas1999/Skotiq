# Sequence Import Formats (NINA / SGP)

Skotiq can import sequences from two third-party tools:

- **NINA** — *Nighttime Imaging 'N' Astronomy*, exported as JSON (`.json`).
- **SGP** — *Sequence Generator Pro*, exported as JSON-shaped `.sgf`.

The import pipeline is a two-stage transform:

1. A format-specific parser (`NinaSequenceParser`, `SgpSequenceParser`) reads
   the source file and produces a `CanonicalSequenceNode` tree. The canonical
   tree is format-neutral: every supported instruction has a `CanonicalKind`
   enum value (`exposure`, `slew`, `autofocus`, …).
2. `CanonicalNodeMapper` translates that tree into Skotiq's
   `Sequence` / `SequenceNode` model.

The UI entry point lives at *Sequencer ▸ toolbar ▸ Import from NINA / SGP*.
Internally everything funnels through `SequenceImporter.importFromPath`.

## NINA `$type` discriminator mapping

NINA uses Newtonsoft.Json `$type` discriminators like
`"NINA.Sequencer.SequenceItem.Imaging.TakeExposure, NINA"`. The parser strips
the assembly suffix and matches on the short class name.

| NINA `$type` short name | Canonical kind | Skotiq node |
|---|---|---|
| `SequenceRootContainer`, `Container`, `SimpleContainer`, `TemplatedSequenceContainer`, `StartAreaContainer`, `TargetAreaContainer`, `EndAreaContainer`, `ImagingTargetContainer`, `AreaContainer` | `sequential` | `InstructionSetNode` |
| `SequentialContainer` | `sequential` | `InstructionSetNode` |
| `ParallelContainer` | `parallel` | `ParallelNode` |
| `LoopContainer`, `WhileContainer` | `loop` | `LoopNode` |
| `DeepSkyObjectContainer` | `targetHeader` | `TargetHeaderNode` |
| `TakeExposure`, `TakeManyExposures`, `TakeSubframeExposure` | `exposure` | `ExposureNode` |
| `SlewScopeToCoordinates`, `SlewScopeToRaDec`, `SlewTelescopeToCoordinates` | `slew` | `SlewNode` |
| `Center`, `CenterAfterDrift`, `SlewAndCenter`, `CenterAndRotate` | `center` | `CenterNode` |
| `RunAutofocus`, `Autofocus`, `AutoFocus` | `autofocus` | `AutofocusNode` |
| `SwitchFilter`, `ChangeFilter` | `filterChange` | `FilterChangeNode` |
| `WaitForTime`, `WaitUntilTime`, `WaitForAltitude`, `WaitForTimeSpan` | `waitForTime` | `WaitTimeNode` |
| `Delay`, `Wait`, `WaitForTimeSpanDelay` | `delay` | `DelayNode` |
| `Dither`, `DitherAfterExposures`, `DitherAfter` | `dither` | `DitherNode` |
| `StartGuiding`, `StartPHD2Guiding` | `startGuiding` | `StartGuidingNode` |
| `StopGuiding`, `StopPHD2Guiding` | `stopGuiding` | `StopGuidingNode` |
| `MeridianFlip`, `MeridianFlipTrigger` | `meridianFlip` | `MeridianFlipNode` |
| `ParkScope`, `ParkMount`, `Park` | `park` | `ParkNode` |
| `UnparkScope`, `UnparkMount`, `Unpark` | `unpark` | `UnparkNode` |
| `CoolCamera`, `CoolDownCamera` | `coolCamera` | `CoolCameraNode` |
| `WarmCamera`, `WarmUpCamera` | `warmCamera` | `WarmCameraNode` |
| `MoveRotator`, `RotateMechanical`, `Solve` | `rotator` | `RotatorNode` |
| `Annotation`, `Comment`, `Note` | `annotation` | *dropped* |
| *(unknown type with children)* | `sequential` | `InstructionSetNode` |
| *(unknown type, leaf)* | `unsupported` | *aborts or dropped (force-import)* |

NINA `Conditions[]` on a container are folded into the parent: a
`LoopCondition`/`CountCondition`/`IterationsCondition` sets the loop's
iteration count; `LoopForeverCondition`/`WhileCondition` flips the loop to
forever; `TimeCondition`/`TimeSpanCondition` sets an "until ISO time"
attribute. `Triggers[]` (e.g. `MeridianFlipTrigger`) are appended to the
container's child list so they execute alongside the body.

## SGP `.sgf` key mapping

SGP files describe a flat `TargetSet[]` of targets, each with a `Reference`
block (coordinates) and an `Events[]` list (per-filter exposure plan). The
parser composes each target into a target-header subtree.

| SGP key | Canonical sub-tree | Skotiq nodes |
|---|---|---|
| `SequenceTitle` / `Name` | root container name | sequence name |
| `TargetSet[].Target` | `targetHeader` | `TargetHeaderNode` |
| `Target.TargetName` | header `name` / `targetName` attribute | `targetName` |
| `Target.Reference.RAHours`, `Dec`, `Rotation` | target attributes | `raHours`, `decDegrees`, `rotation` |
| `Target.AutoCenter == true` (with coords) | `center` child | `CenterNode` |
| `Target.Events[]` | exposures inside a `loop` container | `LoopNode` + interleaved `FilterChangeNode` + `ExposureNode` |
| `Event.Filter` | preceding filter-change | `FilterChangeNode` |
| `Event.ExposureTime` | exposure attribute | `ExposureNode.durationSecs` |
| `Event.NumExposures` / `Repeat` / `Count` | exposure attribute | `ExposureNode.count` |
| `Event.Binning`, `Gain`, `Offset`, `ImageType` | exposure attributes | matching `ExposureNode` fields |
| `Event.Enabled == false` | `annotation` (decorative drop) | *dropped* |

For each target the parser emits roughly:

```
TargetHeader(name=..., ra=..., dec=...)
  ├─ Slew(ra, dec)           # always, when coords known
  ├─ Center(ra, dec)         # only if AutoCenter == true
  └─ Loop("Exposures", iterations: 1)
       ├─ FilterChange("Lum")
       ├─ Exposure(Lum, 60s × 30)
       ├─ FilterChange("Red")
       └─ Exposure(Red, 120s × 15)
```

The outer `LoopNode` exists so per-filter exposure plans can be re-run by
wrapping them in another Skotiq loop later, without restructuring the
imported tree.

## What gets dropped (silent)

Drops are recorded in `ImportResult.droppedNodes` and shown in the import
summary dialog, but they do not abort the import.

- **NINA**: any node whose short type matches `Annotation`, `Comment`, or
  `Note`.
- **NINA**: any node with `"Enabled": false` (or `"IsEnabled": false`). The
  drop is reported with `DropReason.disabled`.
- **SGP**: any `Event` with `"Enabled": false` becomes a decorative annotation
  and is dropped.
- **Force-import only**: nodes whose source type is recognized as belonging
  to NINA/SGP but for which Skotiq has no equivalent. These show up in
  `unsupportedNodes` *and* `droppedNodes` (with `DropReason.unsupported`).

## What's unsupported (aborts strict import)

If the importer sees any of the following, it raises `UnsupportedNodeError`
and the dialog offers a "force-import (drop unsupported)" toggle:

- **NINA**: any leaf node whose short type does not appear in the table above
  (typical examples: vendor-specific plug-in nodes like
  `SequenceItem.Voodoo.CustomScriptNode`, decorative third-party widgets,
  `SmartExposure` (composite), `SafetyMonitor` triggers).
- **NINA**: a recognized filter-change with no resolvable filter name. The
  mapper rejects it because Skotiq requires a `filterName` to act on.
- **SGP**: SGP exports have no concept of arbitrary unsupported nodes — every
  event/target is mapped. (If we later see SGP variants with custom action
  blocks, those should be classified `unsupported` here.)

The mapping table in the summary dialog always shows the exact source-type ↔
Skotiq-type pairing for both supported and dropped nodes, so users can
see which entries from their source file became which Skotiq nodes.

## Examples

### NINA: M31 imaging run → Skotiq tree

Source fragment (NINA JSON):

```json
{
  "$type": "NINA.Sequencer.Container.SequenceRootContainer, NINA.Sequencer",
  "Items": [{
    "$type": "NINA.Sequencer.Container.DeepSkyObjectContainer, NINA.Sequencer",
    "Name": "M31",
    "Target": {
      "TargetName": "M31 Andromeda Galaxy",
      "InputCoordinates": {"RAHours": 0.7122, "Dec": 41.2688}
    },
    "Items": [{
      "$type": "NINA.Sequencer.Container.LoopContainer, NINA.Sequencer",
      "Conditions": [{"$type": "...LoopCondition...", "Iterations": 20}],
      "Items": [{
        "$type": "NINA.Sequencer.SequenceItem.Imaging.TakeExposure, NINA.Sequencer",
        "ExposureTime": 120.0, "Gain": 100, "Filter": {"_name": "Lum"}
      }]
    }]
  }]
}
```

Resulting Skotiq tree:

```
InstructionSet("Imaging Run — M31")
  └─ TargetHeader("M31 Andromeda Galaxy", ra=0.7122, dec=41.27)
       └─ Loop(count=20)
            └─ Exposure(120 s × 1, filter="Lum", gain=100, type=light)
```

### SGP: Two-target night → Skotiq tree

Source fragment (SGP):

```json
{
  "SequenceTitle": "Two-target night",
  "TargetSet": [{
    "Target": {
      "TargetName": "M42 Orion Nebula",
      "AutoCenter": true,
      "Reference": {"RAHours": 5.5882, "Dec": -5.391, "Rotation": 90.0},
      "Events": [
        {"Enabled": true, "Filter": "Lum", "ExposureTime": 60, "NumExposures": 30},
        {"Enabled": true, "Filter": "Red", "ExposureTime": 120, "NumExposures": 15}
      ]
    }
  }]
}
```

Resulting Skotiq tree:

```
InstructionSet("Two-target night")
  └─ TargetHeader("M42 Orion Nebula", ra=5.5882, dec=-5.391, rotation=90°)
       ├─ Slew(5.5882, -5.391)
       ├─ Center(5.5882, -5.391)
       └─ Loop("Exposures", count=1)
            ├─ FilterChange("Lum")
            ├─ Exposure(60 s × 30, type=light, gain/offset/binning preserved)
            ├─ FilterChange("Red")
            └─ Exposure(120 s × 15, type=light)
```

## Assumed wire shapes

The bundled fixtures (`packages/skotiq_core/test/services/import/fixtures/`)
were authored from public NINA / SGP documentation and reverse-engineered from
typical exports rather than dumped verbatim from an installation. If your
file uses an unusual `$type` discriminator (vendor plugins, sequencer
extensions) the parser will surface the node as **unsupported** and the
import will abort in strict mode — letting you decide whether to drop the
node and continue. Please file an issue with a redacted sample so the
canonical mapper can be extended.

**Follow-up:** verify the fixtures against real NINA exports from an
installation that uses the modern *Advanced Sequencer*; the current shapes
assume Newtonsoft's `$type` discriminator format. SGP `.sgf` shapes match
the documented format up to and including SGP 4.2.
