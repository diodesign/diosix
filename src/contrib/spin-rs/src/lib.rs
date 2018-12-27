#![crate_type = "lib"]
#![warn(missing_docs)]
#![feature(core_intrinsics)]

//! Synchronization primitives based on spinning

#![no_std]

pub use mutex::*;
pub use once::*;

mod mutex;
mod once;
mod atomic;
