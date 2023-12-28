const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("../Prog.zig");

pub const supported = builtin.cpu.arch == .x86_64 and
    // TODO: detect other OSes using the System V ABI
    builtin.os.tag == .linux;

/// Generates x86-64 machine code for a function with the following signature
/// which behaves according to the instructions in `prog`:
///
/// ```
/// fn (
///     /// Memory buffer (must be 2^32 bytes)
///     memory: [*]u8,
///     /// Input function, returns the input byte or a negative error code
///     input: *const fn (ctx: *anyopaque) callconv(.C) i32,
///     /// Context for input function
///     input_ctx: *anyopaque,
///     /// Output function, returns 0 or a negative error code
///     output: *const fn (ctx: *anyopaque, b: u8) callconv(.C) i32,
///     /// Context for output function
///     output_ctx: *anyopaque,
/// ) i32
/// ```
///
/// The return value of the function is 0 or a negative error code.
///
/// Note: at this time, only the System V ABI is supported.
pub fn generate(allocator: Allocator, prog: Prog) Allocator.Error![]align(mem.page_size) u8 {
    var code = std.ArrayListAligned(u8, mem.page_size).init(allocator);
    defer code.deinit();
    var pending_loop_starts = std.ArrayList(usize).init(allocator);
    defer pending_loop_starts.deinit();
    var pending_exit_jumps = std.ArrayList(usize).init(allocator);
    defer pending_exit_jumps.deinit();

    // Register usage:
    //
    // - eax: memory position
    // - rdi: pointer to memory
    // - rsi: input function
    // - rdx: input function context
    // - rcx: output function
    // - r8: output function context
    // - r10: temporary/scratch
    // - r11: temporary/scratch
    //
    // Note that these last five are the same registers that will contain the
    // arguments passed to the function according to the System V ABI.
    //
    // All of these are caller-saved registers.
    //
    // Note on eax usage: according to section 3.4.1.1 of volume 1 of the Intel
    // architecture manual, when a 32-bit register is modified in 64-bit mode,
    // the upper 32 bits of the corresponding 64-bit register are zeroed.

    const push_regs =
        // push rax
        "\x50" ++
        // push rdi
        "\x57" ++
        // push rsi
        "\x56" ++
        // push rdx
        "\x52" ++
        // push rcx
        "\x51" ++
        // push r8
        "\x41\x50";
    const pop_regs =
        // pop r8
        "\x41\x58" ++
        // pop rcx
        "\x59" ++
        // pop rdx
        "\x5A" ++
        // pop rsi
        "\x5E" ++
        // pop rdi
        "\x5F" ++
        // pop rax
        "\x58";

    try code.appendSlice("\x55"); // push rbp
    try code.appendSlice("\x48\x89\xE5"); // mov rbp, rsp

    try code.appendSlice("\x31\xC0"); // xor eax, eax

    // Unfortunately, we can't use `[rdi + eax + offset]` addressing directly
    // (at least in general), because the operation `eax + offset` needs to wrap
    // around within the range of a 32-bit integer before using it as an offset.
    // Hence, we actually add the offset to eax first and use `[rdi + eax]`.
    //
    // This variable tracks the difference between eax and the actual cursor
    // position.
    var current_offset: u32 = 0;

    for (
        prog.insts.items(.tag),
        prog.insts.items(.value),
        prog.insts.items(.offset),
        prog.insts.items(.extra),
    ) |tag, value, offset, extra| {
        switch (tag) {
            .halt => {
                // xor eax, eax
                try code.appendSlice("\x31\xC0");
                // jmp (exit)
                try code.appendSlice("\xE9");
                try pending_exit_jumps.append(code.items.len);
                try code.appendSlice("\x00\x00\x00\x00"); // placeholder
            },
            .breakpoint => {
                // int 3
                try code.appendSlice("\xCD\x03");
            },
            .set => {
                if (offset != current_offset) {
                    // add eax, (offset - current_offset)
                    try code.appendSlice("\x05");
                    try code.writer().writeInt(u32, offset -% current_offset, .little);
                    current_offset = offset;
                }
                // mov byte [rdi + rax], (value)
                try code.appendSlice("\xC6\x04\x07");
                try code.append(value);
            },
            .add => {
                if (offset != current_offset) {
                    // add eax, (offset - current_offset)
                    try code.appendSlice("\x05");
                    try code.writer().writeInt(u32, offset -% current_offset, .little);
                    current_offset = offset;
                }
                // add byte [rdi + rax], (value)
                try code.appendSlice("\x80\x04\x07");
                try code.append(value);
            },
            .add_mul => {
                // TODO: optimize power of 2 multiplications and other optimizable patterns
                if (offset != current_offset) {
                    // add eax, (offset - current_offset)
                    try code.appendSlice("\x05");
                    try code.writer().writeInt(u32, offset -% current_offset, .little);
                    current_offset = offset;
                }
                // mov r10b, [rdi + rax]
                try code.appendSlice("\x44\x8A\x14\x07");
                // add eax, (extra)
                try code.appendSlice("\x05");
                try code.writer().writeInt(u32, extra, .little);
                // mov r11b, [rdi + rax]
                try code.appendSlice("\x44\x8A\x1C\x07");
                // sub eax, (extra)
                try code.appendSlice("\x2D");
                try code.writer().writeInt(u32, extra, .little);
                // imul r10w, r11w, (value)
                try code.appendSlice("\x66\x45\x6B\xD3");
                try code.append(value);
                // add [rdi + rax], r10b
                try code.appendSlice("\x44\x00\x14\x07");
            },
            .move => {
                // add eax, (extra - current_offset)
                try code.appendSlice("\x05");
                try code.writer().writeInt(u32, extra -% current_offset, .little);
                current_offset = 0;
            },
            .seek => {
                if (offset != current_offset) {
                    // add eax, (offset - current_offset)
                    try code.appendSlice("\x05");
                    try code.writer().writeInt(u32, offset -% current_offset, .little);
                }
                // lea r10, [rdi + rax]
                try code.appendSlice("\x4C\x8D\x14\x07");
                // cmp byte [r10], (value)
                try code.appendSlice("\x41\x80\x3A");
                try code.append(value);
                // je $$ + 9
                try code.appendSlice("\x74\x09");
                // add r10, (extra)
                try code.appendSlice("\x49\x81\xC2");
                try code.writer().writeInt(u32, extra, .little);
                // jmp $$ - 18
                try code.appendSlice("\xEB\xF1");
                // sub r10, rdi
                try code.appendSlice("\x49\x29\xFA");
                // mov rax, r10
                try code.appendSlice("\x4C\x89\xD0");
                current_offset = 0;
            },
            .in => {
                try code.appendSlice(push_regs);
                // mov rdi, rdx
                try code.appendSlice("\x48\x89\xD7");
                // call rsi
                try code.appendSlice("\xFF\xD6");
                // cmp eax, 0
                try code.appendSlice("\x83\xF8\x00");
                // jb (end)
                try code.appendSlice("\x0F\x82");
                try pending_exit_jumps.append(code.items.len);
                try code.appendSlice("\x00\x00\x00\x00"); // placeholder
                // mov r10b, al
                try code.appendSlice("\x41\x88\xC2");
                try code.appendSlice(pop_regs);
                if (offset != current_offset) {
                    // add eax, (offset - current_offset)
                    try code.appendSlice("\x05");
                    try code.writer().writeInt(u32, offset -% current_offset, .little);
                    current_offset = offset;
                }
                // mov [rdi + rax], al
                try code.appendSlice("\x88\x04\x07");
            },
            .out => {
                if (offset != current_offset) {
                    // add eax, (offset - current_offset)
                    try code.appendSlice("\x05");
                    try code.writer().writeInt(u32, offset -% current_offset, .little);
                    current_offset = offset;
                }
                try code.appendSlice(push_regs);
                // mov sil, [rdi + rax]
                try code.appendSlice("\x40\x8A\x34\x07");
                // mov rdi, r8
                try code.appendSlice("\x4C\x89\xC7");
                // call rcx
                try code.appendSlice("\xFF\xD1");
                // cmp eax, 0
                try code.appendSlice("\x83\xF8\x00");
                // jb (end)
                try code.appendSlice("\x0F\x82");
                try pending_exit_jumps.append(code.items.len);
                try code.appendSlice("\x00\x00\x00\x00"); // placeholder
                try code.appendSlice(pop_regs);
            },
            .out_value => {
                try code.appendSlice(push_regs);
                // mov sil, (value)
                try code.appendSlice("\x40\xB6");
                try code.append(value);
                // mov rdi, r8
                try code.appendSlice("\x4C\x89\xC7");
                // call rcx
                try code.appendSlice("\xFF\xD1");
                // cmp eax, 0
                try code.appendSlice("\x83\xF8\x00");
                // jb (end)
                try code.appendSlice("\x0F\x82");
                try pending_exit_jumps.append(code.items.len);
                try code.appendSlice("\x00\x00\x00\x00"); // placeholder
                try code.appendSlice(pop_regs);
            },
            .loop_start => {
                if (current_offset != 0) {
                    // sub eax, current_offset
                    try code.appendSlice("\x2D");
                    try code.writer().writeInt(u32, current_offset, .little);
                    current_offset = 0;
                }
                // cmp byte [rdi + rax], 0
                try code.appendSlice("\x80\x3C\x07\x00");
                // je (after loop end)
                try code.appendSlice("\x0F\x84");
                try pending_loop_starts.append(code.items.len);
                try code.appendSlice("\x00\x00\x00\x00"); // placeholder
            },
            .loop_end => {
                if (current_offset != 0) {
                    // sub eax, current_offset
                    try code.appendSlice("\x2D");
                    try code.writer().writeInt(u32, current_offset, .little);
                    current_offset = 0;
                }
                const loop_start_placeholder = pending_loop_starts.pop();
                // cmp byte [rdi + rax], 0
                try code.appendSlice("\x80\x3C\x07\x00");
                // jne (after loop start)
                try code.appendSlice("\x0F\x85");
                // The jmp offset for the loop start instruction (the negative
                // of this is the offset for the loop end instruction)
                const jmp_offset: u32 = @intCast(code.items.len - loop_start_placeholder);
                try code.writer().writeInt(u32, -%jmp_offset, .little);
                mem.writeInt(u32, code.items[loop_start_placeholder..][0..4], jmp_offset, .little);
            },
        }
    }

    for (pending_exit_jumps.items) |pending_exit_jump| {
        const jmp_offset: u32 = @intCast(code.items.len - pending_exit_jump - 4);
        mem.writeInt(u32, code.items[pending_exit_jump..][0..4], jmp_offset, .little);
    }

    try code.appendSlice("\x48\x89\xEC"); // mov rsp, rbp
    try code.appendSlice("\x5D"); // pop rbp
    try code.appendSlice("\xC3"); // ret

    return try code.toOwnedSlice();
}
