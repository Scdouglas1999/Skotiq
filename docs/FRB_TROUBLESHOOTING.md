# Flutter Rust Bridge Troubleshooting Guide

This document captures known issues with flutter_rust_bridge code generation in the Skotiq project and their solutions.

## Environment
- Flutter: 3.44.1
- Dart: 3.12.1
- flutter_rust_bridge: 2.11.1
- ffigen: 11.0.0
- Platform: Windows

---

## Issue 1: `stdbool.h` Not Found (SEVERE)

### Symptom
When running `flutter_rust_bridge_codegen generate`, you see:
```
[SEVERE] : fatal error: 'stdbool.h' file not found [Lexical or Preprocessor Issue]
```

This causes ffigen to generate incorrect typedefs like:
```dart
typedef bool = ffi.NativeFunction<ffi.Int Function(ffi.Pointer<ffi.Int>)>;
```

Which shadows Dart's built-in `bool` type and causes errors like:
```
A value of type 'bool' can't be returned from the function ... because it has a return type of 'bool'
```

### Root Cause
ffigen uses libclang to parse C headers. On Windows, it cannot find the standard C library headers (like `stdbool.h`) because the LLVM/Clang installation doesn't include them or the include paths aren't configured.

### Solutions

#### Solution: Set CPATH Environment Variable (VERIFIED WORKING)

Before running `flutter_rust_bridge_codegen generate`, set the CPATH environment variable to include:
1. LLVM clang headers (for stdbool.h)
2. MSVC headers (for vcruntime.h)
3. Windows SDK UCRT headers (for stdlib.h, etc.)
4. Windows SDK shared/um headers

**PowerShell (run before code generation):**
```powershell
$env:CPATH = "C:\Program Files\LLVM\lib\clang\21\include;C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.43.34808\include;C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\ucrt;C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\um;C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\shared"
flutter_rust_bridge_codegen generate
```

**Bash/MSYS2:**
```bash
export CPATH="/c/Program Files/LLVM/lib/clang/21/include:/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC/14.43.34808/include:/c/Program Files (x86)/Windows Kits/10/Include/10.0.22621.0/ucrt:/c/Program Files (x86)/Windows Kits/10/Include/10.0.22621.0/um:/c/Program Files (x86)/Windows Kits/10/Include/10.0.22621.0/shared"
flutter_rust_bridge_codegen generate
```

**Note:** Adjust version numbers based on your installation:
- LLVM version: Check `ls "C:\Program Files\LLVM\lib\clang\"`
- MSVC version: Check `ls "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\"`
- Windows SDK version: Check `ls "C:\Program Files (x86)\Windows Kits\10\Include\"`

#### Alternative: Make it Permanent

Add the CPATH to your system environment variables or create a script wrapper for FRB codegen.

---

## Issue 2: `ffi.Pointer<ffi.Int>` Type Mismatch

### Symptom
Analysis errors like:
```
The argument type 'Pointer<Int32>' can't be assigned to the parameter type 'Pointer<Int>'
```

### Root Cause
**This issue is CAUSED BY Issue 1 (stdbool.h not found).**

When ffigen can't find the C standard headers, it generates incorrect/abstract FFI types like `ffi.Int` and `ffi.Pointer<ffi.Int>` instead of concrete types like `ffi.Int32` and `ffi.Pointer<ffi.Int32>`.

### Solution
**Fix Issue 1 first.** Once ffigen can find all required C headers (stdbool.h, stdlib.h, vcruntime.h, etc.), the generated code will use correct concrete types and this error goes away.

See Issue 1 above for the CPATH environment variable fix.

---

## Issue 3: `#[flutter_rust_bridge::frb(ignore)]` for Complex Types

### Symptom
FRB generates invalid code for complex Rust types like `Range<Self>` in trait methods.

### Root Cause
FRB doesn't correctly handle all generic type patterns, especially `Self` in trait contexts.

### Solution
Add `#[flutter_rust_bridge::frb(ignore)]` to exclude problematic code from FFI generation:

```rust
// In api.rs or relevant Rust file
#[flutter_rust_bridge::frb(ignore)]
pub mod internal_utils {
    // Code that shouldn't be exposed to Dart
    pub trait RandomRange: Sized {
        fn in_range(seed: u64, range: std::ops::Range<Self>) -> Self;
    }
}
```

Key points:
- Apply `ignore` to the entire module if multiple items are problematic
- Apply to individual traits, impls, structs, or functions as needed
- Regenerate FRB bindings after adding ignore attributes

---

## Issue 4: Duplicate Generated Files

### Symptom
Multiple `frb_generated.dart` files in different directories (e.g., `lib/src/` and `lib/src/gen/`).

### Root Cause
Old FRB output from previous configuration or version.

### Solution
1. Check `flutter_rust_bridge.yaml` for the correct `dart_output` path
2. Delete stale generated directories (e.g., `lib/src/gen/`)
3. Regenerate: `flutter_rust_bridge_codegen generate`

---

## Best Practices

### 1. Never Edit Generated Files
Files like `frb_generated.dart`, `frb_generated.io.dart` will be overwritten on regeneration. Always fix issues at the source:
- Rust code in `native/skotiq_native/bridge/src/`
- FRB config in `flutter_rust_bridge.yaml`
- ffigen config

### 2. Check Compatibility Before Upgrading
Before upgrading Flutter/Dart or FRB:
- Check FRB release notes for compatibility
- Test generation on a branch first

### 3. Use `cargo check` Before Generating
Ensure Rust code compiles before running FRB codegen:
```bash
cd native/skotiq_native
cargo check --package skotiq_bridge
```

### 4. Clean Regeneration
When issues persist:
```bash
# Clean Flutter
flutter clean

# Clean Dart generated files
rm -rf packages/skotiq_bridge/lib/src/*.dart
rm -rf packages/skotiq_bridge/lib/src/api/

# Regenerate
cd native/skotiq_native
flutter_rust_bridge_codegen generate
```

---

## Recommended Development Workflow

**Use the unified dev script to avoid hash mismatches and stale DLLs:**

```powershell
# Full rebuild (regenerate FRB + build Rust + copy DLLs + run Flutter)
melos run dev

# Or directly:
.\scripts\dev.ps1

# Quick rebuild (skip FRB if only implementation changed)
melos run dev:quick

# Rebuild without running
melos run dev:norun

# Clean everything and rebuild from scratch
melos run dev:clean
```

**Why this is needed:**
- Hash mismatches occur when Dart bindings and compiled Rust code are out of sync
- Multiple DLL copies exist in `apps/desktop/`, `apps/desktop/windows/`, and `target/release/`
- The dev script ensures all copies are updated and hashes match

---

## Useful Commands

```bash
# Check FRB version
flutter pub deps | grep flutter_rust_bridge

# Regenerate bindings
cd native/skotiq_native
flutter_rust_bridge_codegen generate

# Check for Rust compilation issues
cargo check --package skotiq_bridge

# Run Dart analysis
cd packages/skotiq_bridge
flutter analyze
```

---

## References
- FRB Documentation: https://cjycode.com/flutter_rust_bridge/
- FRB ffigen Troubleshooting: https://fzyzcjy.github.io/flutter_rust_bridge/manual/ffigen-troubleshooting
- FRB GitHub Issues: https://github.com/aspect-build/rules_flutter/issues
