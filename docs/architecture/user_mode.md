# ParanukOS User Mode — Milestone 4 Interface

[English] | [中文](user_mode_CN.md)

> **Status: interface proposed, implementation not started.**
>
> Prerequisites: M0–M3 are implemented and verified ([kernel_interface.md](kernel_interface.md),
> [memory_subsystem.md](memory_subsystem.md), [threads_and_scheduling.md](threads_and_scheduling.md)).
> This document defines M4: **the first user-space service — a minimal privilege switch with a syscall
> ABI, and no IPC semantics yet**.

## 1. Scope

### 1.1 What this document defines
* `BootInfo` **v1**: the appended user-image fields, and how the kernel stays compatible with v0 (§3)
* How the bootloader loads a second ELF and how the kernel maps it into a user address space (§4)
* The user address space: where user VAs live, why they start above the identity map, and how
  supervisor/user separation is expressed in the page tables (§5)
* The user code/data descriptors and the `TSS.rsp0` rule that makes a CPL 3 → CPL 0 transition land on
  a valid kernel stack (§6)
* The privilege switch: what a user thread's saved frame looks like, and who sets it up (§7)
* The syscall ABI (`int 0x40`): register convention, the M4 call table, and **pointer validation** —
  the first real security boundary in this project (§8)
* User-mode faults: how the kernel tells "the service crashed" from "the kernel crashed" (§9)
* The user program and its tiny library, with their own linker script (§10)
* Exit code 47, the M4a/M4b split, and falsifiable acceptance criteria (§11)

### 1.2 What this document does not define
IPC and capability tokens (M5), more than one address space or more than one user thread, demand
paging, ELF relocation/dynamic linking, a file-system program loader, `syscall`/`sysret`,
signals, process trees, and shared memory between services. The kernel stays at its current low,
identity-mapped link address: **the higher-half migration is explicitly not part of M4** [decision #41].

### 1.3 Terminology

| Term | Meaning |
|---|---|
| CPL | current privilege level (0 = kernel, 3 = user) |
| user address space | a PML4 whose low half is the kernel's identity map (supervisor-only) and whose user region is user-accessible |
| user region | the VA range `[USER_BASE, …)` where user code/data live |
| syscall | a CPL 3 → CPL 0 transition through `int 0x40` |
| service | the single user-space program M4 runs |
| `TSS.rsp0` | the kernel stack the CPU switches to on a CPL 3 → CPL 0 transition |

## 2. Baseline and prerequisites

M4 builds on M3's threads, GDT/TSS/IST, interrupt infrastructure and scheduler. What it must not
break:

* the M0–M3 exit codes keep their meanings (33/35/37/39/41/43/45); **47** is new;
* kernel threads keep working exactly as before: M4 adds a *kind* of thread, it does not replace the
  scheduler — the same round-robin queue, the same switch path, the same six-step self-check;
* the IDT keeps its vectors: 0x20 timer, 0x30 yield, 0x31 exit, and M4 adds **0x40 syscall**;
* `BootInfo` v0 readers keep working (a v1 struct is a superset).

## 3. `BootInfo` v1 (append-only, per `kernel_interface.md` §5.5)

Four fields are appended; `version` becomes 1 and `size` becomes **120** (v0's 88 + 32). Nothing is
removed, moved, or reinterpreted.

```rust
#[repr(C)]
pub struct BootInfo {
    /* v0 fields, unchanged: 0..88 */
    pub user_phys: u64,   // 88: physical base of the loaded user image
    pub user_size: u64,   // 96: its size in bytes (page-aligned span)
    pub user_vaddr: u64,  // 104: the VA that corresponds to user_phys
    pub user_entry: u64,  // 112: the user entry point (a VA inside the image)
    // size = 120, version = 1
}
```

* `validate()` accepts **both** versions: it requires `magic` to match and `size` to be at least 88;
  the user fields are only read when `version >= 1 && size >= 120` [decision #42]. A v0 `BootInfo`
  means "no user payload", and the kernel then skips the M4 part of the self-check and reports 47 with
  a specific message rather than booting something half-initialised.
* `user_vaddr` is what lets the kernel map the image without parsing ELF: the loader takes the first
  `PT_LOAD` segment's `(p_paddr, p_vaddr)` delta, so the whole page-aligned physical span maps to
  `[user_vaddr, user_vaddr + user_size)` — identity in shape, but at the user region [decision #43].
* the loader loads `\EFI\PARANUKO\USER.ELF` with **the same** rules as the kernel image
  (`crates/kernel-image`: ELF64, little-endian, `ET_EXEC`, non-overlapping segments, entry inside an
  executable segment). A missing or invalid user image is a **load failure → 35**, exactly like the
  missing kernel image, because M4 has no meaningful "kernel without a service" mode.

## 4. The user program's image

* it is a separate crate (`crates/user`) built for `x86_64-unknown-none`, linked **at `USER_BASE`**;
* its linker script places `.text`/`.rodata`/`.data`/`.bss` at the user VAs and gives each segment an
  explicit physical load address with `AT(…)`, so `p_vaddr` is a user VA while `p_paddr` stays below
  4 GiB (the loader still loads at `p_paddr`, `kernel_interface.md` §3.2) [decision #44];
* it is **static, non-PIE** (`-C relocation-model=static`), like the kernel; no relocation processing;
* `crates/user-lib` holds the syscall wrappers (`write`, `exit`, …) so the program's source stays
  readable and the ABI has exactly one definition shared by both sides;
* the program's entry is `_start` (the kernel does not use `e_entry` blindly: it puts `user_entry`
  into the initial user frame's `rip`).

## 5. The user address space

### 5.1 Layout

| Range | Contents | Permissions |
|---|---|---|
| `[0, 4 GiB)` | the kernel's existing identity map (kernel image, heap, frames, stack, BootInfo) | supervisor (`U/S = 0`) |
| `[USER_BASE, …)` where `USER_BASE = 0x1_0000_0000` (4 GiB) | the user image, its stack, later its heap | user (`U/S = 1`), no execute disabled yet |

`USER_BASE` is deliberately exactly where the kernel's identity map ends
(`memory_subsystem.md` §3.4, `MAX_IDENTITY_BYTES = 4 GiB`) [decision #45]. Placing user VAs *inside*
the identity-mapped range would have to overwrite identity entries for physical RAM the kernel itself
may be using — the kernel would lose access to its own frames. Starting above the map makes the two
roles disjoint by construction, and the kernel can still read user memory **by its physical address**
(identity) when it validates or copies on the service's behalf.

### 5.2 Page tables

* M4 has **one** address space, and it is the *current* one: the user region's tables are built in the
  **same arena** as the kernel's tables (`USER_BASE = 4 GiB` lands in `PDPT[4]`, which the kernel's own
  PDPT has free), so **M4 never writes `CR3`** [decision #54];
* consequence: there is no per-thread address space to switch and no TLB management either. What keeps
  the service out of kernel memory is the `U/S` bit, not a separate table — and the negative cases in
  §10 are what make that claim testable;
* the alternative (a fresh PML4 per address space) was rejected for M4 because with `USER_BASE = 4 GiB`
  its PML4 index is 0: sharing entry 0 would have made the *separate* address space map exactly the
  same addresses as the kernel's, i.e. the abstraction would have been fiction. Real separation needs
  either a `USER_BASE` at 512 GiB or more (its own PML4 entry) or a whole per-process layout — both
  belong to the milestone that introduces multiple address spaces;
* user pages are **4 KiB** (the user region is mapped with a PT, not a 2 MiB block), because M4 needs
  per-page `U/S` control and because `.text` and `.data` must eventually differ in permissions;
* **every level of the page-table chain must carry `U/S = 1`**, not just the leaf [decision #55]. The
  CPU reports a missing intermediate bit as a protection violation *on the leaf's address* (`#PF` with
  `error_code` bits 0 and 2 set), which is how this was found on real hardware. Setting the
  intermediate bits does **not** widen what is reachable: a supervisor leaf under a user-accessible
  intermediate is still unreachable at CPL 3, which is exactly why the kernel's 2 MiB identity blocks
  stay private;
* the kernel never derives a user pointer from a page-table walk at run time beyond the checks in §8:
  it validates a user pointer by looking it up in the current address space's user region;
* the builder lives in `crates/kernel-memory` (host-tested) and takes the storage from the kernel, as
  every other table builder in this project does.

### 5.3 What the service can and cannot do
* it can read/write/execute its own region only; any access to `[0, 4 GiB)` faults (`#PF`, `U/S`
  violation) even though those addresses are present in its page table;
* it cannot disable interrupts, install descriptors or reach a device: no I/O port instructions
  (CPL 3 `in`/`out` raise `#GP`), and no MMIO is mapped user-accessible;
* it cannot allocate: M4 has no memory syscall; the image's `.bss` plus a fixed user stack is all it
  gets [decision #47]. A memory syscall wants a proper ownership model and belongs with M5's
  capability work.

## 6. Descriptors and the kernel stack for interrupts

* M3's GDT already reserves three slots for M4; M4 fills two of them: **user code `0x28`** and **user
  data `0x30`**, both `DPL = 3`, both flat, long mode, with `L = 1` for code;
* user frames use `cs = 0x28 | 3 = 0x2B` and `ss = 0x30 | 3 = 0x33` (RPL 3 — the CPU requires the RPL
  of the frame's selectors to match CPL on `iretq`);
* **`TSS.rsp0` must point at the *current user thread's* kernel stack top before any CPL 3 code
  runs**, and must be refreshed on every switch into a user thread [decision #48]. Otherwise a timer
  interrupt taken in user mode pushes its frame onto whatever stack `rsp0` still holds — which is how
  kernels corrupt themselves in a way that only shows up later. `switch_to` therefore sets `rsp0` when
  the incoming thread is a user thread (and can leave it alone for kernel threads).

## 7. The privilege switch

Nothing new is needed in the switch path: a user thread is an ordinary M3 thread whose saved frame
happens to have CPL 3 selectors [decision #49].

* the initial frame for the service is built like a kernel thread's (§14.5 of the M3 annex) with:
  * `rip = BootInfo.user_entry`, `rsp = user_stack_top` (a user VA in the user region),
  * `cs = 0x2B`, `ss = 0x33`,
  * `rflags = 0x202` (`IF = 1`, and bit 1 set),
  * `rdi`/`rsi` = a small argument block the program may ignore in M4;
* `iretq` performs the CPL 0 → CPL 3 transition and loads the user `rsp` from the frame — which is why
  the frame must carry a *user* stack pointer, unlike a kernel thread's frame;
* the user stack is one to four pages taken from the frame allocator at `USER_BASE + offset`, mapped
  user-writable, with the usual M3 canary at its lowest word;
* when the timer preempts user code, the CPU switches to `TSS.rsp0` (the thread's kernel stack), builds
  the frame there, and the existing ISR path saves it — the scheduler then treats the thread like any
  other. `Context.rsp` therefore always points at an `IrqFrame`, in user and kernel mode alike.

## 8. Syscall ABI (`int 0x40`)

* vector **0x40**, an **interrupt gate with `DPL = 3`** so CPL 3 may execute `int 0x40`; the handler
  reuses the M3 `irq_common` path (same frame, same return protocol). No MSR is touched: `syscall`/
  `sysret` is a later optimisation [decision #50];
* registers: `rax` = call number, `rdi`, `rsi`, `rdx`, `r10`, `r8` = arguments, `rax` = return value
  (and, when the kernel also has the M3 frame, the frame is what carries them back — the handler
  writes the frame's `rax` slot, so no separate convention is invented);
* M4 call table (deliberately tiny):

| # | Call | Arguments | Returns |
|---|---|---|---|
| 0 | `exit` | `rdi` = status | never returns; the thread is marked `Exited` |
| 1 | `write` | `rdi` = user pointer, `rsi` = length | bytes written, or `-1` |
| 2 | `yield` | — | 0 |

* **pointer validation** (the first real security boundary in this project, [decision #51]): `write`
  must (a) reject `length > WRITE_MAX` (a fixed bound), (b) check `ptr` and `ptr + length` for overflow,
  and (c) verify that **every page** the range touches is present and user-accessible *in the current
  address space*, using the page tables — never by trusting the pointer. Because user VAs are disjoint
  from the identity map (§5.1), "is this VA in the user region" is a cheap first check;
* a violation **kills the service** (its thread is marked `Exited`, the kernel logs the reason) and is
  reported as a user-mode failure (47), not as a kernel panic: a buggy service must not be able to
  take the kernel down [decision #52];
* syscalls run with interrupts disabled (the interrupt gate cleared `IF`) and must not block; the M3
  rule "no allocation in an interrupt handler" applies to the syscall path as well;
* the syscall handler is a *kernel* path that may touch user memory; it does so through the identity
  map after validating the range, which is exactly the same physical memory.

## 9. User-mode faults vs kernel faults

The exception handler already receives the interrupted `cs`; if its RPL is 3, the fault came from the
service [decision #53]:

* log it with the same detail as a kernel fault (`rip`, `error_code`, and `cr2` for `#PF`), plus the
  thread id;
* mark the service's thread `Exited` and report **47** at the end of the M4 self-check;
* a fault at CPL 0 still means "the kernel crashed" → **41**. The distinction is what keeps the log
  honest, and it is the reason the two codes exist.

## 10. The user program (M4's evidence)

The program is intentionally trivial but exercises everything: it writes a fixed line through the
`write` syscall, calls `yield` once (proving that the CPL 3 thread is scheduled like any other), and
then calls `exit(0)`. The kernel's self-check observes:

1. the service reached CPL 3 (the syscall path was taken at least once, from `cs = 0x2B`);
2. its `write` output appeared on the serial log, byte for byte;
3. it was preempted at least once (the M3 tick counter advanced while it ran);
4. it exited, its stack was reaped, and the frame count returned to its pre-service value;
5. an injected bad pointer (a VA inside the identity map, e.g. `0x100000`) is **rejected**, the service
   is killed, and the kernel reports 47 — the negative case that proves validation is real.

Two test-only features make the negative cases reachable:

| Feature | Effect | Expected |
|---|---|---|
| `inject-user-bad-pointer` | the program calls `write` with a kernel VA | the kernel rejects it, kills the service → **47** |
| `inject-user-fault` | the program dereferences an unmapped user VA | `#PF` at CPL 3 → the handler names it a user fault → **47** |

## 11. Delivery, deliverables and acceptance criteria

### 11.1 Split

| Part | Content | Why |
|---|---|---|
| **M4a** | `BootInfo` v1 + loader loading `USER.ELF` + the user crate/linker script + `AddressSpace` + the user thread + the privilege switch (the program runs and faults/exits; no syscalls) | everything here is a prerequisite for a syscall being *interesting*, and a mistake in the page tables or `rsp0` shows up as a triple fault or a silent corruption |
| **M4b** | `int 0x40` + the call table + pointer validation + user-fault reporting + the self-check and the two injections + smoke cases | builds on a proven CPL 3 transition; the ABI is small enough to review as a unit |

### 11.2 Deliverables
`crates/kernel-memory` (address-space builder + host tests), `crates/boot-info` (v1 + tests),
`crates/kernel-image` (unchanged, reused for the user image), `crates/user` + `crates/user-lib`,
`crates/kernel/src/user.rs` (privilege switch, syscall table, validation), `crates/kernel/src/gdt.rs`
(user descriptors), `crates/kernel/src/sched.rs` (`rsp0` on switch), `crates/kernel/src/idt.rs`
(vector 0x40 + CPL filter), `src/bootloader/` (load the second ELF), `tests/smoke.sh`, both languages
of this document, `kernel_interface.md` (§5.5 note, §7.2 exit codes, §9), READMEs.

### 11.3 Acceptance criteria — machine-checkable (M4a met except where noted; M4b not started)
- [x] `BootInfo` v1 is 120 bytes with the v0 prefix byte-identical (a unit test pins every offset);
- [x] the loader reports the user image's physical span, VA base and entry, and rejects a missing or
      non-ELF `USER.ELF` with **35**;
- [x] the kernel logs the mapped user region with its page count and entry, and `rsp0` is set on the
      switch into the service (the old wording asked for details that changed in implementation): `user: 0x…→0x… (N 页, U/S=1)，入口 0x…` and `rsp0` on switch;
- [x] the service runs at CPL 3 — the kernel logs the `cs=0x2B` the **CPU** reported when the sentinel
      syscall arrived (its `write` output is M4b, which has no call table yet) (the kernel logs `cs=0x2B` at least once) and its `write` output
      appears on the serial log;
- [x] it is preempted in **user mode** (136 ticks elapsed while it spun) and its exit reaps its stack
      (the only live threads are the boot context and the idle thread) and its exit reaps its stack (frame count back to baseline);
- [ ] `inject-user-bad-pointer` → **47** with a log line naming the rejected VA;
- [ ] `inject-user-fault` → **47** with `cr2` naming the faulting VA, *not* 41;
- [x] `inject-user-fault` → **47** with `cr2` naming the faulting VA, **not** 41. The injection is an
      inline-asm null read rather than `read_volatile`: the latter pulls in an absolute `.rodata`
      reference, and since the image links at 4 GiB the default small code model can only emit a
      ±2 GiB 32-bit absolute relocation, which the linker rejects. **41** (the M1/M2/M3 negative cases do not regress);
- [ ] `cargo test -p kernel-memory -p boot-info …` passes; clippy/fmt clean in every configuration;
- [ ] `check_kernel_elf.py` still passes and the kernel image stays under `MAX_KERNEL_PAGES`.

### 11.4 Known pitfalls, most likely first

| # | Pitfall | Mitigation |
|---|---|---|
| 1 | `TSS.rsp0` not updated per thread → interrupts in user mode push onto a stale stack | set it in `switch_to` whenever the incoming thread is a user thread (§6), and assert it in the self-check |
| 2 | User pages mapped `U/S = 0` (forgotten bit) → the service dies on its first instruction fetch | the address-space builder sets `USER` on every user leaf; the self-check's first log line comes from CPL 3 code |
| 3 | Kernel pages left `U/S = 1` → user code can read kernel memory | the kernel's identity map is built with `U/S = 0` (M2) and shared, never copied; the bad-pointer injection proves rejection |
| 4 | Frame selectors with RPL ≠ 3 → `iretq` raises `#GP` at CPL 0 | `cs = 0x2B`, `ss = 0x33`, asserted in a unit test over the frame builder |
| 5 | Trusting a user pointer | §8's three checks, plus the negative injection |
| 6 | The user program's segments loaded at `p_paddr` but mapped at `p_vaddr` with a wrong delta | the loader computes `user_vaddr` from the first segment and the kernel maps the whole span with one delta (§3) |
| 7 | `.bss` of the user image not zeroed | the loader zeroes it exactly as for the kernel image (`kernel_interface.md` §3.2 step 3.4) |
| 8 | A user fault reported as a kernel crash | §9's CPL check |

## 12. Decision record

| # | Decision | Outcome | Rationale | Reversibility |
|---|---|---|---|---|
| 41 | The kernel keeps its low, identity-mapped link address in M4; user VAs live above the identity map | no linker/bootloader/loader change for the kernel itself | the higher-half migration touches the linker script, the load rules, every raw address in the kernel and 49 smoke assertions; M4's goal is the privilege switch, not a memory-layout overhaul | medium (the higher-half move stays available: load at `p_paddr`, map at `p_vaddr`) |
| 42 | `BootInfo` v1 with four appended `u64`s; `validate()` accepts v0 and v1 | size 120, version 1 | the documented append-only evolution, exercised for real; a v0 boot means "no service", which the kernel reports instead of half-booting | high |
| 43 | The loader tells the kernel the image's physical span **and** its VA base, so the kernel needs no ELF parser | one delta for the whole span | keeps ELF knowledge in exactly one place (`kernel-image`, used by the loader) and the kernel's mapping arithmetic trivial | high |
| 44 | The user program links at `USER_BASE` with `AT(…)` physical addresses | `p_vaddr` high, `p_paddr` low | the loader loads at `p_paddr`; the kernel maps physical→user VA — both sides keep working unchanged | medium |
| 45 | `USER_BASE = 0x1_0000_0000` (4 GiB, exactly where the identity map ends) | disjoint VA space by construction | user VAs inside the identity range would overwrite mappings for physical RAM the kernel itself uses | high |
| 46 | One `AddressSpace` in M4; its PML4 shares the kernel's lower PDPT | several address spaces later | per-thread address spaces are an M5-shaped problem (ownership, sharing), and sharing entry 0 means kernel mappings can never drift between spaces | high |
| 47 | No memory syscall in M4 | the service gets image + a fixed stack | allocation without an ownership/capability model would have to be redesigned in M5 anyway | high |
| 48 | `TSS.rsp0` is refreshed on every switch into a user thread | one write in `switch_to` | a stale `rsp0` means an interrupt in user mode corrupts whatever stack it points at | high |
| 49 | A user thread is an ordinary M3 thread with CPL 3 selectors in its frame | no new switch path at all | the existing frame-based switch already carries `cs`/`ss`; adding a second mechanism would be the M3 "two shapes" mistake again | high |
| 50 | Syscalls enter through `int 0x40` | DPL 3 interrupt gate, reusing `irq_common` | no MSR setup, one code path with everything else; `syscall`/`sysret` is a measurable later optimisation | high |
| 51 | The kernel validates every user pointer against the address space before touching it | three checks in §8 | it is the first real trust boundary; "the user passed a pointer" must never mean "the kernel dereferences it" | high |
| 52 | A bad syscall argument or a user fault kills the service and reports 47 | service dies, kernel survives | a service bug must not be able to take the kernel down, and the log must not call it a kernel crash | medium (47 is frozen once released) |
| 53 | The exception handler filters on the frame's CPL to choose 47 vs 41 | same diagnostics, two exit codes | keeps "who crashed" answerable from the exit code alone | high |
| 54 | M4 builds the user region in the **same** page-table arena as the kernel and never switches `CR3` | a single address space; isolation is entirely the `U/S` bit | with `USER_BASE = 4 GiB` the PML4 index is 0, so a separate PML4 sharing entry 0 would have mapped exactly the same addresses — a fiction. Multiple address spaces (and therefore `CR3` switching) belong to the milestone that introduces them | high |
| 55 | Every level of a user mapping carries `U/S = 1`; only the leaf decides reachability | one extra flag per table entry | the CPU needs the bit at every level or the access faults (found on hardware as `#PF` `error_code=0x15`); a supervisor leaf still keeps the kernel unreachable | high |
| 56 | The user image is linked at `USER_BASE` plus one page (so the `FILEHDR`-mapped headers start exactly at `USER_BASE`) with a uniform `AT(ADDR(section) - USER_DELTA)` | one `PT_LOAD` delta for the whole image | the loader maps the image with a single delta (`BootInfo.user_vaddr`), so the two must agree; folding the headers into `.text` avoids a second `PT_LOAD` whose `p_paddr` would equal its user VA | medium |

## 13. Interface change process
1. `BootInfo` v1 follows `kernel_interface.md` §11: append only, `version`+1, larger `size`; both
   languages and both sides of the ABI are updated in the same change.
2. The syscall ABI (§8) is an ABI: changing it means changing `crates/user-lib`, the kernel's dispatch
   table and this document together.
3. `crates/kernel-memory`'s address-space builder is host-tested; changes need tests.
4. Bilingual docs: every change must update both this file and [user_mode_CN.md](user_mode_CN.md).
5. Implementation status: after each part, update §11 and the M4 row of `kernel_interface.md` §9.
