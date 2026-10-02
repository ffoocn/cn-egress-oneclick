# Third-party software

The standalone installer contains the project's Bash sources. At installation
time it downloads the following upstream components over HTTPS and checks their
SHA-256 digests before use. Go and AmneziaWG builds take place in private manager
or node staging directories; no Python program or AmneziaWG kernel module is
installed.

| Component | Pinned version / source | License |
| --- | --- | --- |
| wstunnel | [v11.0.0 official release](https://github.com/erebe/wstunnel/releases/tag/v11.0.0), Linux amd64 / arm64 | [BSD 3-Clause at v11.0.0](https://github.com/erebe/wstunnel/blob/v11.0.0/LICENSE), reproduced below |
| amneziawg-go | [v0.2.16 source commit `730d6c39d0c4e348a3d080bebe496664215e5c99`](https://github.com/amnezia-vpn/amneziawg-go/tree/730d6c39d0c4e348a3d080bebe496664215e5c99), built with `CGO_ENABLED=0` for Linux amd64 / arm64 | [MIT at the pinned commit](https://github.com/amnezia-vpn/amneziawg-go/blob/730d6c39d0c4e348a3d080bebe496664215e5c99/LICENSE) |
| amneziawg-tools | [v1.0.20260223 source commit `5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079`](https://github.com/amnezia-vpn/amneziawg-tools/tree/5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079), compiled natively on the HK node | [GPLv2 at the pinned commit](https://github.com/amnezia-vpn/amneziawg-tools/blob/5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079/COPYING); individual source files carry their own SPDX notices |
| Go toolchain | [Go 1.24.4 official archives and checksums](https://go.dev/dl/#go1.24.4), Linux amd64 / arm64 manager | [BSD 3-Clause at Go 1.24.4](https://github.com/golang/go/blob/go1.24.4/LICENSE) |

The tools source archive, including its `COPYING` file, is transferred with the
HK installation payload. The Go engine's dependency versions and hashes are
recorded in its pinned [go.mod](https://github.com/amnezia-vpn/amneziawg-go/blob/730d6c39d0c4e348a3d080bebe496664215e5c99/go.mod)
and [go.sum](https://github.com/amnezia-vpn/amneziawg-go/blob/730d6c39d0c4e348a3d080bebe496664215e5c99/go.sum).
Dependency license notices remain in the corresponding upstream module sources.
These license references describe the selected commits, rather than later
upstream releases.

## AmneziaWG Go license notice

The pinned source identifies its main implementation as:

```text
Copyright (C) 2017-2025 WireGuard LLC. All Rights Reserved.
SPDX-License-Identifier: MIT

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## wstunnel license notice

The installer downloads official wstunnel v11.0.0 Linux amd64 or arm64 release archives and verifies their SHA-256 checksums.

- Upstream: [erebe/wstunnel](https://github.com/erebe/wstunnel)
- Release: [v11.0.0](https://github.com/erebe/wstunnel/releases/tag/v11.0.0)
- License: BSD 3-Clause, reproduced below from the official release archive.
- The original archive also includes its LICENSE and README.

```text
BSD 3-Clause License

Copyright (c) 2016-2024, Erèbe - Romain Gerard

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

```
