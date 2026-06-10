# Licensing of Diosix

Unless otherwise stated, the following license applies to the Diosix source code:

## MIT License (MIT)

Copyright (c) 2024-2026 Diosix contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Compiled binary license notice

This hypervisor integrates the [Unicorn Engine](https://www.unicorn-engine.org/), which contains parts of QEMU's JIT compiler (TCG). Because Unicorn is licensed under the GNU General Public License version 2 (GPLv2), any compiled binary images of Diosix that link with the Unicorn Engine are defined as derivative works under [GPLv2 rules](https://github.com/unicorn-engine/unicorn/blob/master/COPYING).

Consequently, while the individual source files of Diosix remain under the permissive MIT license, compiled binary distributions containing the emulation layer must be distributed under the GPLv2.

