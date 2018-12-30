hashmap_core
=========

[![Build Status](https://travis-ci.org/Amanieu/hashmap_core.svg?branch=master)](https://travis-ci.org/Amanieu/hashmap_core) [![Crates.io](https://img.shields.io/crates/v/hashmap_core.svg)](https://crates.io/crates/hashmap_core)

This crate provides an implementation of `HashMap` and `HashSet` which do not depend on the standard library and are suitable for `no_std` environments.

This crate uses the FNV instead of SipHash for the default hasher, because the latter requires a source of random numbers which may not be available in `no_std` environments.

This crate is nightly-only for now since it uses the `alloc` crate, which is unstable.

### Documentation

[https://docs.rs/hashmap_core](https://docs.rs/hashmap_core)

## License

Licensed under either of

 * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
 * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any
additional terms or conditions.
