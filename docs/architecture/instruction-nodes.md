# Sequencer Instruction Nodes — Architecture & Migration Guide

This document describes the architecture of the Rust sequencer's node tree
after the core refactor and walks instruction authors through adding
a new instruction node.

## Why this exists

Pre-refactor, every new instruction touched five different sites in
`sequencer/src/node.rs`:

1. The 32-variant `NodeType` enum.
2. A ~780-line `match` arm in `RuntimeNode::execute`.
3. `calculate_totals` in `executor.rs`.
4. `build_execution_order` in `executor.rs`.
5. Checkpoint serialization.

The dispatch match was the largest single barrier to feature velocity. The
refactor replaces it with a trait-object registry while keeping the on-disk
sequence file format (and therefore the `NodeType` enum) unchanged.

## Module layout

```text
sequencer/src/
  node.rs                   module entry; re-exports public surface
  node/
    context.rs              ExecutionContext (now Clone-able)
    progress.rs             ProgressUpdate + ProgressDetail (structured)
    registry.rs             InstructionNode trait + static registry
    runtime.rs              RuntimeNode + Node trait + top-level dispatch
    instructions/           one file per instruction (29 leaf nodes)
      slew.rs
      center.rs
      expose.rs
      autofocus.rs
      ...
    logic/                  container / flow nodes
      target_header.rs
      loop_node.rs
      parallel.rs
      conditional.rs
      recovery.rs
      sequential.rs         shared execute_children_sequential helper
```

## The three traits / structs

### `Node` trait (`node/runtime.rs`)

The base trait every behaviour-tree node implements. Unchanged from
pre-refactor — `RuntimeNode` is the only concrete impl.

### `InstructionNode` trait (`node/registry.rs`)

Implemented by every leaf instruction. Zero-sized unit struct per
instruction. Dispatched through `InstructionRegistry::build(&NodeType)`,
which returns a `Box<dyn InstructionNode>`.

```rust
#[async_trait]
pub trait InstructionNode: Send + Sync {
    fn type_name(&self) -> &'static str;
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus;
}
```

Container / logic nodes (`TargetHeader`, `Loop`, `Parallel`, `Conditional`,
`Recovery`) are **NOT** in the registry — they need `&mut self.children`
access from `RuntimeNode`, so they live in `node/logic/` and are dispatched
via a small explicit match in `RuntimeNode::execute`.

### `ExecutionContext` (`node/context.rs`)

`#[derive(Clone)]` — wrapping `progress_callback` and
`polar_align_image_callback` in `Arc` makes the whole context cheaply
cloneable. The pre-refactor 22-field manual copy in `execute_parallel` is
now `let mut branch_context = context.clone();`.

## Structured progress

`ProgressUpdate` carries a typed `ProgressDetail`:

```rust
pub enum ProgressDetail {
    Generic(String),
    Exposure { frame: u32, total: u32, duration_secs: f64 },
    Filter { name: String, position: Option<i32> },
    Slew { target_ra_hours: Option<f64>, target_dec_degrees: Option<f64> },
    Center { attempt: u32, max_attempts: u32, last_separation_arcsec: Option<f64> },
    Autofocus { step: u32, total_steps: u32, current_hfr: Option<f64> },
    // ...
}
```

Instructions populate the structured fields directly; the executor's
progress callback reads them with no parsing. Backwards compatibility is
preserved via `ProgressUpdate::legacy_message()`, which renders the
pre-refactor `"Foo: detail (NN%)"` string for the FRB bridge surface.
**No FRB regen is required.**

## How to add a new instruction

1. **Add the config + enum variant** in `sequencer/src/lib.rs`:

   ```rust
   #[derive(Debug, Clone, Serialize, Deserialize, Default)]
   pub struct MyNewConfig { /* fields */ }

   pub enum NodeType {
       // ...
       MyNewThing(MyNewConfig),
   }
   ```

2. **Add the device-side worker** in `sequencer/src/instructions.rs`:

   ```rust
   pub async fn execute_my_new_thing(
       config: &MyNewConfig,
       ctx: &InstructionContext,
       progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
   ) -> InstructionResult { /* ... */ }
   ```

3. **Create the instruction node** in
   `sequencer/src/node/instructions/my_new_thing.rs`:

   ```rust
   use crate::instructions::execute_my_new_thing;
   use crate::node::context::ExecutionContext;
   use crate::node::progress::{ProgressDetail, ProgressUpdate};
   use crate::node::registry::InstructionNode;
   use crate::{NodeStatus, NodeType};
   use async_trait::async_trait;

   pub struct MyNewThingInstruction;

   #[async_trait]
   impl InstructionNode for MyNewThingInstruction {
       fn type_name(&self) -> &'static str { "My New Thing" }

       async fn execute(
           &self,
           node_id: &str,
           node_type: &NodeType,
           context: &mut ExecutionContext,
       ) -> NodeStatus {
           let NodeType::MyNewThing(config) = node_type else {
               tracing::error!("MyNewThingInstruction received wrong variant");
               return NodeStatus::Failure;
           };
           let ctx = context.to_instruction_context().await;
           let progress_cb = context.progress_callback.as_ref();
           let progress_fn = |progress: f64, detail: String| {
               if let Some(cb) = progress_cb {
                   cb(ProgressUpdate::instruction_progress(
                       node_id.to_string(),
                       "My New Thing",
                       progress,
                       ProgressDetail::Generic(detail),
                   ));
               }
           };
           execute_my_new_thing(config, &ctx, Some(&progress_fn))
               .await
               .log_and_get_status("My New Thing")
       }
   }
   ```

4. **Register the instruction** in two places in `node/registry.rs`:

   - `InstructionRegistry::new` — add a factory line:
     ```rust
     factories.insert("MyNewThing", || Box::new(i::my_new_thing::MyNewThingInstruction));
     ```
   - `node_type_discriminant` — add a match arm:
     ```rust
     NodeType::MyNewThing(_) => Some("MyNewThing"),
     ```

5. **Declare the submodule** in `node/instructions/mod.rs`:

   ```rust
   pub mod my_new_thing;
   ```

6. **(Optional)** If your instruction reports rich progress (exposure
   counters, slew coordinates, etc.), add a variant to `ProgressDetail`
   in `node/progress.rs` and a `detail_text()` arm. Otherwise
   `ProgressDetail::Generic(String)` works.

7. **(If the instruction is exposure-producing)** Add a `TakeExposure`-style
   branch to `executor.rs::calculate_totals` so the UI total counter is
   accurate.

The new instruction is **NOT** required to be touched in `RuntimeNode::execute`
— the registry resolves it automatically.

## Why not `inventory` for the registry?

`inventory` requires global linker tricks that don't play well with the
cdylib + staticlib combination used by `skotiq_bridge`. A hand-rolled
registry is explicit, debuggable, and easy to extend (one line per new
instruction). See `InstructionRegistry::new` in `node/registry.rs`.

## What about container / logic nodes?

`TargetHeader`, `Loop`, `Parallel`, `Conditional`, and `Recovery` need
`&mut self.children` and `&mut self.current_iteration` access on
`RuntimeNode`. Pushing them through a trait object would require splitting
RuntimeNode's state ownership — gold-plating that buys no feature velocity.
Each lives in its own `node/logic/<name>.rs` file with a free-standing
`pub async fn execute_<name>(node: &mut RuntimeNode, config, context)`
signature, and `RuntimeNode::execute` dispatches the five variants
explicitly. A future plugin that wants to add a *new* container node would
need to touch the dispatch match — that is the intentional cost of keeping
tree-walking state with the node that owns the children.
