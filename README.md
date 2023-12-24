# bf0

bf0 is a [Brainfuck](https://esolangs.org/wiki/Brainfuck) interpreter aiming for
correctness and speed.

## Features

- 8-bit wrapping cells
- Full 32-bit wrapping address space (4GB memory)
- Configurable input EOF behavior
- Optimization passes

## Implementation details

Brainfuck programs are parsed into an internal bytecode format (see
`src/Prog.zig`). The parse step implicitly applies a few basic "optimizations",
namely, adjacent adds and moves are condensed into single instructions. Then, if
enabled, further optimization passes are applied in `src/optimize.zig`.

Memory is implemented using a "paged" strategy which uses an array of 1MB lazily
allocated pages. Alternatively, if the underlying platform supports it, a
"mapped" strategy can be used which simply `mmap`s the entire 4GB memory at once
using `MAP_NORESERVE` to ensure the OS lazily allocates sections of the region
as needed.

## License

bf0 is distributed under the [Zero-Clause BSD
License](https://spdx.org/licenses/0BSD.html), which places no restrictions on
your use, modification, or distribution of the program. This license applies to
all files in the repository _except_ those under `programs/third-party`, which
are under their own licenses (see the notes in
`programs/third-party/README.md`).
