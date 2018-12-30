// Copyright 2014 The Rust Project Developers. See the COPYRIGHT
// file at the top-level directory of this distribution and at
// http://rust-lang.org/COPYRIGHT.
//
// Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
// <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
// option. This file may not be copied, modified, or distributed
// except according to those terms.

//! Unordered containers, implemented as hash-tables

#![no_std]
#![cfg_attr(
    not(feature = "disable"),
    feature(alloc, dropck_eyepatch, allocator_api, fused, ptr_internals, try_reserve, nonnull_cast)
)]
#![feature(alloc_layout_extra)]

#[cfg(not(feature = "disable"))]
extern crate alloc as alloc_crate;

#[cfg(not(feature = "disable"))]
mod alloc {
    pub use alloc_crate::alloc::{handle_alloc_error, Global};
    #[cfg(test)]
    pub use alloc_crate::vec::Vec;
    pub use core::alloc::*;
}

#[cfg(not(feature = "disable"))]
mod collections {
    pub use alloc_crate::collections::CollectionAllocErr;
}

#[cfg(not(feature = "disable"))]
pub mod fnv;
#[cfg(not(feature = "disable"))]
pub mod map;
#[cfg(not(feature = "disable"))]
pub mod set;
#[cfg(not(feature = "disable"))]
mod table;
#[cfg(not(feature = "disable"))]
#[cfg(not(feature = "disable"))]
trait Recover<Q: ?Sized> {
    type Key;

    fn get(&self, key: &Q) -> Option<&Self::Key>;
    fn take(&mut self, key: &Q) -> Option<Self::Key>;
    fn replace(&mut self, key: Self::Key) -> Option<Self::Key>;
}

#[cfg(not(feature = "disable"))]
pub use fnv::FnvHashMap;
#[cfg(not(feature = "disable"))]
pub use fnv::FnvHashSet;
#[cfg(not(feature = "disable"))]
pub use map::HashMap;
#[cfg(not(feature = "disable"))]
pub use set::HashSet;
