//! `state_part!` declares one part of the trigger state.
//!
//! A part lists its fields in two blocks. A field under `persisted` is written
//! to the session checkpoint and restored from it; a field under `transient`
//! is not. The macro generates the part, its checkpoint form (a serde struct
//! with exactly the persisted fields, each tolerant of being absent from an
//! older file) and the copy in each direction, so checkpointing a new field is
//! one line in the right block.

macro_rules! state_part {
    (
        $(#[$meta:meta])*
        pub struct $name:ident, checkpointed as $snapshot:ident {
            persisted {
                $(
                    $(#[$pmeta:meta])*
                    pub $pfield:ident : $pty:ty $(= $pdefault:expr)?
                ),* $(,)?
            }
            transient {
                $(
                    $(#[$tmeta:meta])*
                    pub $tfield:ident : $tty:ty $(= $tdefault:expr)?
                ),* $(,)?
            }
        }
    ) => {
        $(#[$meta])*
        #[derive(Debug, Clone)]
        pub struct $name {
            $( $(#[$pmeta])* pub $pfield: $pty, )*
            $( $(#[$tmeta])* pub $tfield: $tty, )*
        }

        impl Default for $name {
            fn default() -> Self {
                Self {
                    $( $pfield: state_part!(@default $($pdefault)?), )*
                    $( $tfield: state_part!(@default $($tdefault)?), )*
                }
            }
        }

        #[doc = concat!("The checkpointed fields of [`", stringify!($name), "`].")]
        #[derive(Debug, Clone, PartialEq, Default, serde::Serialize, serde::Deserialize)]
        #[serde(default)]
        pub struct $snapshot {
            $( pub $pfield: $pty, )*
        }

        impl $name {
            pub fn snapshot(&self) -> $snapshot {
                $snapshot {
                    $( $pfield: self.$pfield.clone(), )*
                }
            }

            /// Take the checkpointed fields from `snapshot`; the rest keep
            /// their live values.
            pub fn restore(&mut self, snapshot: &$snapshot) {
                $( self.$pfield = snapshot.$pfield.clone(); )*
            }
        }
    };
    (@default) => { ::core::default::Default::default() };
    (@default $default:expr) => { $default };
}

pub(super) use state_part;
