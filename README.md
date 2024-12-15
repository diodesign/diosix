## Welcome guide

1. [About this project](#intro)
1. [Contact, contributions, security, and code of conduct](#contact)
1. [Copyright, distribution, and license](#copyright)

## About this project <a name="intro"></a>

Diosix strives to be a lightweight, fast, and secure multi-core bare-metal hypervisor written [in Zig](https://ziglang.org/) for 64-bit [RISC-V](https://riscv.org/) computers. It is aimed at systems that may be small, or even large, yet have a need to run multiple hardware-isolated operating systems at the same time.

This is very much a work-in-progress as it is essentially a restart of the Rust-written project using Zig to iterate and innovate faster while maintaining a focus on safety, security, and reliability.

## Contact, contributions, security issue reporting, and code of conduct <a name="contact"></a>

Email [hello@diosix.org](mailto:hello@diosix.org) if you have any questions or issues to raise, wish to get involved, or have source to contribute. If you have found a security flaw, please follow [these steps](docs/security.md) to report the bug. You can also submit pull requests or raise issues via GitHub, though please consider disclosing security-related matters privately. You are more than welcome to use the [discussion boards](https://github.com/diodesign/diosix/discussions/) to ask questions and suggest features.

Please observe the project's [code of conduct](docs/conduct.md) when participating.

## Copyright, distribution, and license <a name="copyright"></a>

Copyright &copy; Chris Williams, 2024. See [LICENSE](LICENSE) for distribution and use of source code, binaries, and documentation.

The diosix.org [illustration](docs/logo.png) is a combination of artwork kindly provided by [Katerina Limpitsouni](https://undraw.co/license) and [RISC-V International](https://riscv.org/about/risc-v-branding-guidelines/).
