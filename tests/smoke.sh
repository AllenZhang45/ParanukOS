#!/usr/bin/env bash
#
# ParanukOS QEMU 冒烟测试（Milestone 0）。
#
# 引导器在 `--features qemu-exit` 下通过 QEMU 的 isa-debug-exit 设备报告结果，
# 内核也通过 `BootInfo.exit_port` 用同一机制报告自检结果，因此这里断言**精确退出码**：
#
#   33  引导器装载完成（M0 起正常路径不再使用：成功会直接跳入内核）
#   35  内核镜像装载失败（缺少镜像 / 非 ELF / 段布局非法 / 入口不可执行）
#   37  内核自检通过（BootInfo 有效 + 内存图可用 + RSDP 存在 + 自建页表 + 页帧分配器 + 内核堆）
#   39  内核自检失败（magic/version 不匹配等）
#   41  内核发生未处理异常或 panic（意外崩溃）
#   43  内核内存初始化失败（页表构建/安装、页帧分配器、内核堆）
#   45  内核调度自检失败（GDT/TSS/IST、时钟中断、线程、锁）
#   47  用户态服务故障（CPL 3 的异常，或被拒绝的系统调用参数）
#   124 超时：应用没有主动退出（判失败）
#
# 退出码常量与 crates/boot-info 保持一致。
#
# 用法: bash tests/smoke.sh
# 环境变量:
#   BOOT_TIMEOUT  单个用例超时秒数（默认 60）
#   LOG_DIR       串口日志目录（默认 target/smoke-logs，CI 失败时上传）

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UEFI_TARGET="x86_64-unknown-uefi"
BARE_TARGET="x86_64-unknown-none"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
LOG_DIR="${LOG_DIR:-${ROOT}/target/smoke-logs}"
mkdir -p "$LOG_DIR"

EXIT_LOAD_FAILURE=35
EXIT_KERNEL_OK=37
EXIT_KERNEL_FAILURE=39
EXIT_KERNEL_FAULT=41
EXIT_KERNEL_MEMORY_FAILURE=43
EXIT_KERNEL_SCHED_FAILURE=45
EXIT_USER_FAILURE=47

WORK="$(mktemp -d)"
ESP_DIR="$(mktemp -d)/esp"

cleanup() {
    rm -rf "$WORK"
    rm -rf "$(dirname "$ESP_DIR")"
}
trap cleanup EXIT

pass=0
fail=0
ok() {
    printf '  ✅ %s\n' "$1"
    pass=$((pass + 1))
}
bad() {
    printf '  ❌ %s\n' "$1"
    fail=$((fail + 1))
}
show_log() {
    echo "    --- $1 串口输出（尾部） ---"
    sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$1" | tail -20 | sed 's/^/    /'
}

# --- 依赖检查 ---
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "[-] 未安装 qemu-system-x86_64，无法运行冒烟测试。" >&2
    echo "    Ubuntu/Debian: sudo apt install qemu-system-x86 ovmf" >&2
    echo "    Fedora/RHEL:   sudo dnf install qemu-system-x86 edk2-ovmf" >&2
    exit 1
fi
if ! command -v rustc >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
    echo "[-] 未找到 rustc/cargo。" >&2
    exit 1
fi

echo "==> 1/6 构建用户态服务（$BARE_TARGET）"
if ! cargo build -p user --target "$BARE_TARGET"; then
    echo "[-] 用户态服务构建失败。" >&2
    exit 1
fi
cp "target/${BARE_TARGET}/debug/user" "$WORK/USER.ELF"

echo "==> 1/5 构建内核（$BARE_TARGET）"
if ! cargo build -p kernel --target "$BARE_TARGET"; then
    echo "[-] 内核构建失败。" >&2
    exit 1
fi
cp "target/${BARE_TARGET}/debug/kernel" "$WORK/KERNEL.ELF"

echo "==> 1.5/5 静态校验内核 ELF（验收标准 §8.4 第 1 条）"
if ! python3 tests/check_kernel_elf.py "$WORK/KERNEL.ELF"; then
    echo "[-] 内核 ELF 未通过静态校验。" >&2
    exit 1
fi

echo "==> 2/5 构建引导器（$UEFI_TARGET，启用 qemu-exit）"
if ! cargo build --target "$UEFI_TARGET" --features qemu-exit; then
    echo "[-] 引导器构建失败。" >&2
    exit 1
fi
cp "target/${UEFI_TARGET}/debug/paranukos.efi" "$WORK/loader.efi"

echo "==> 3/5 构建「注入错误 magic」的引导器（验证内核自检失败路径）"
if ! cargo build --target "$UEFI_TARGET" --features qemu-exit,inject-bad-magic; then
    echo "[-] 注入版引导器构建失败。" >&2
    exit 1
fi
cp "target/${UEFI_TARGET}/debug/paranukos.efi" "$WORK/loader-bad-magic.efi"

echo "==> 4/5 准备用例数据"
# 非 ELF 内容，且必须 >= 64 字节：否则会先命中「镜像过小」而不是 magic 校验
head -c 128 /dev/zero >"$WORK/not-elf.bin"
echo "    内核: $WORK/KERNEL.ELF ($(wc -c <"$WORK/KERNEL.ELF") 字节)"

# 启动一次并断言精确退出码。
# 用法: boot_case <efi> <kernel_elf|-> <日志> <期望退出码> <描述>
boot_case() {
    local efi="$1" kernel="$2" log="$3" want="$4" desc="$5"
    local user="${6:-$WORK/USER.ELF}"
    if [ "$kernel" = "-" ]; then
        export KERNEL_ELF=""   # 显式禁用自动投放 → ESP 中没有 KERNEL.ELF
    else
        export KERNEL_ELF="$kernel"
    fi
    if [ "$user" = "-" ]; then
        export USER_ELF=""     # 显式禁用自动投放 → ESP 中没有 USER.ELF
    else
        export USER_ELF="$user"
    fi
    : >"$log"
    timeout "$BOOT_TIMEOUT" env ESP_DIR="$ESP_DIR" ./run-qemu.sh "$efi" >"$log" 2>&1
    local got=$?
    if [ "$got" -eq "$want" ]; then
        ok "$desc（退出码 $got）"
        return 0
    fi
    if [ "$got" -eq 124 ]; then
        bad "$desc：超时 ${BOOT_TIMEOUT}s 仍未退出"
    else
        bad "$desc：退出码 $got，期望 $want"
    fi
    show_log "$log"
    return 1
}

grep_log() { # <日志> <正则> <描述>
    if grep -qE "$2" "$1"; then
        ok "$3"
    else
        bad "$3"
        show_log "$1"
    fi
}

echo "==> 5/5 引导用例"

# --- A. 正向：合法内核 → 内核自检通过（37） ---
boot_case "$WORK/loader.efi" "$WORK/KERNEL.ELF" "$LOG_DIR/m0-positive.log" "$EXIT_KERNEL_OK" \
    "合法内核：引导器装载并跳转，内核自检通过"
grep_log "$LOG_DIR/m0-positive.log" '个 PT_LOAD 段' "引导器按段解析 ELF"
grep_log "$LOG_DIR/m0-positive.log" '交接准备就绪' "引导器完成交接准备"
if grep -qE '\[\+ SUCCESS\] 用户镜像已装载: base=0x[0-9A-F]+ size=[0-9]+ entry=0x[0-9A-F]+ vaddr_delta=[0-9]+ 段数=1' "$LOG_DIR/m0-positive.log"; then
    ok "引导器装载了用户态服务镜像（M4：v1 BootInfo 字段）"
else
    bad "用户镜像装载日志缺失或形状不符"
    show_log "$LOG_DIR/m0-positive.log"
fi
grep_log "$LOG_DIR/m0-positive.log" '\[kernel\] ParanukOS kernel alive' "内核真的开始执行"
grep_log "$LOG_DIR/m0-positive.log" 'IDT 已安装' "内核安装了 IDT（M1）"
grep_log "$LOG_DIR/m0-positive.log" 'self-check OK' "内核自检通过"
# 内存图条目数必须 > 0（形如 "memory map: 127 项"）
if grep -qE 'memory map: [1-9][0-9]* 项' "$LOG_DIR/m0-positive.log"; then
    ok "内核读到非空内存图"
else
    bad "内存图条目数不是 > 0"
    show_log "$LOG_DIR/m0-positive.log"
fi
# RSDP 必须非零
if grep -qE 'rsdp=0x0*[1-9a-fA-F]' "$LOG_DIR/m0-positive.log"; then
    ok "内核读到非零 ACPI RSDP"
else
    bad "RSDP 为零"
    show_log "$LOG_DIR/m0-positive.log"
fi

# --- M2a：内核自建的恒等映射页表（memory_subsystem.md §8.3） ---
grep_log "$LOG_DIR/m0-positive.log" 'paging: 恒等映射' "内核建立并安装了恒等映射页表"
if grep -qE 'paging: 上限 0x[0-9A-F]+，页表 7 页，CR3=0x[0-9A-F]+' "$LOG_DIR/m0-positive.log"; then
    ok "页表占用符合预算（7 页 = 28 KiB）"
else
    bad "页表页数不是预算内的 7 页"
    show_log "$LOG_DIR/m0-positive.log"
fi
grep_log "$LOG_DIR/m0-positive.log" '切换 CR3 后 BootInfo 仍可读' \
    "恒等映射确实覆盖了交接结构（切换 CR3 后可重新校验 BootInfo）"
# --- M2b：页帧分配器与内核堆（memory_subsystem.md §8.4） ---
if grep -qE 'frames: 管理 [0-9]+ 帧（[0-9]+ MiB），堆取走后空闲 [1-9][0-9]* 帧' "$LOG_DIR/m0-positive.log"; then
    ok "页帧分配器初始化且仍有空闲页帧"
else
    bad "页帧统计行缺失或空闲页帧为 0"
    show_log "$LOG_DIR/m0-positive.log"
fi
if grep -qE 'heap: 0x[0-9A-F]+\.\.0x[0-9A-F]+（1024 KiB，占用 256 个连续页帧）' "$LOG_DIR/m0-positive.log"; then
    ok "内核堆取自 256 个连续页帧（1 MiB）"
else
    bad "堆区间日志不符（应当恰好 256 个连续页帧）"
    show_log "$LOG_DIR/m0-positive.log"
fi
# 自检结束时堆必须回到"单个空闲块"，且字节数恰好是堆大小减去一个块头（24 字节）。
if grep -qE 'heap: 自检 OK（全部释放后空闲 1048552 字节 / 1 个块）' "$LOG_DIR/m0-positive.log"; then
    ok "内核堆自检通过：写读回、不重叠、全部合并回单块"
else
    bad "堆自检未回到单个空闲块（可能有泄漏或未合并）"
    show_log "$LOG_DIR/m0-positive.log"
fi

# --- M3a：描述符表、中断基础设施与调度器（threads_and_scheduling.md §11.3） ---
if grep -qE 'gdt: GDT/TSS 已装载（CS=0x8 SS=0x10，TSS=0x[0-9A-F]+，IST1=0x[0-9A-F]+，IST2=0x[0-9A-F]+）' "$LOG_DIR/m0-positive.log"; then
    ok "GDT/TSS 已装载，选择子仍为 0x08/0x10，两个 IST 栈非零"
else
    bad "GDT/TSS 日志不符（选择子被改坏或 IST 未填）"
    show_log "$LOG_DIR/m0-positive.log"
fi
grep_log "$LOG_DIR/m0-positive.log" 'pic: 8259 已重映射到 0x20..0x2F，PIT 分频 11932（100 Hz），只放行 IRQ0' \
    "PIC 已重映射，PIT 100 Hz（分频四舍五入到 11932）"
grep_log "$LOG_DIR/m0-positive.log" 'sched: 1 个线程就绪，PIT 100 Hz，GDT/TSS 已装载' \
    "调度器已登记引导上下文"
if grep -qE 'timer: 观察到 [3-9][0-9]* 次 tick（[0-9]+ 次调度决策）' "$LOG_DIR/m0-positive.log"; then
    ok "中断开启后时钟真的在推进（≥ 3 次 tick）"
else
    bad "tick 数不足 3：PIT/IRQ0 未生效"
    show_log "$LOG_DIR/m0-positive.log"
fi

# --- M3b：线程、抢占与调度自检（threads_and_scheduling.md §10/§15） ---
if grep -qE 'sched: 空闲线程 = 线程 1' "$LOG_DIR/m0-positive.log"; then
    ok "空闲线程已创建（线程 1）"
else
    bad "空闲线程日志缺失"
    show_log "$LOG_DIR/m0-positive.log"
fi
if grep -qE 'sched: 自检 OK（tick [0-9]+, 切换 [1-9][0-9]*, 存活线程 2）' "$LOG_DIR/m0-positive.log"; then
    ok "六步调度自检通过：发生过真实切换，且结束时只剩引导上下文与空闲线程"
else
    bad "调度自检未通过（切换次数为 0 或线程泄漏）"
    show_log "$LOG_DIR/m0-positive.log"
fi
grep_log "$LOG_DIR/m0-positive.log" 'timer: 中断已按退出协议关闭' "报告前按退出协议关闭中断"

# --- M4a：第一个用户态服务（user_mode.md §11.3） ---
if grep -qE 'user: 镜像 0x[0-9A-F]+→0x[0-9A-F]+（[0-9]+ 页，U/S=1），栈 0x[0-9A-F]+，入口 0x[0-9A-F]+，页表 [0-9]+ 页' "$LOG_DIR/m0-positive.log"; then
    ok "用户区已映射（U/S=1），入口与用户栈就位"
else
    bad "用户区映射日志缺失"
    show_log "$LOG_DIR/m0-positive.log"
fi
# cs=0x2B 是 CPU 报的：证明服务**确实**在 CPL 3 上执行过，而不是内核自说自话
if grep -qE 'user: 服务确实运行在 CPL 3（cs=0x2B，调用号 0xDEAD' "$LOG_DIR/m0-positive.log"; then
    ok "服务在 CPL 3 上运行（cs=0x2B，哨兵调用号 0xDEAD）"
else
    bad "没有观察到来自 CPL 3 的系统调用"
    show_log "$LOG_DIR/m0-positive.log"
fi
if grep -qE 'user: 自检 OK（cs=0x2B，运行期间 [1-9][0-9]* 次 tick，rsp0=0x[0-9A-F]+）' "$LOG_DIR/m0-positive.log"; then
    ok "服务在用户态被时钟抢占过（tick 推进），且 rsp0 已按线程设置"
else
    bad "服务运行期间没有 tick 推进或 rsp0 未设置"
    show_log "$LOG_DIR/m0-positive.log"
fi

# 映射规模必须覆盖测试虚拟机的主要内存（QEMU 默认 128 MiB，这里放宽到 64 MiB）
mapped_mib="$(sed -n 's/.*个 2 MiB 大块（\([0-9]*\) MiB.*/\1/p' "$LOG_DIR/m0-positive.log" | head -1)"
if [ -n "$mapped_mib" ] && [ "$mapped_mib" -ge 64 ]; then
    ok "恒等映射规模 ${mapped_mib} MiB（≥ 64 MiB）"
else
    bad "恒等映射规模不足或无法解析（读到 '${mapped_mib:-空}'）"
    show_log "$LOG_DIR/m0-positive.log"
fi

# --- B. 反向 1：ESP 中没有内核镜像 → 装载失败（35） ---
boot_case "$WORK/loader.efi" "-" "$LOG_DIR/m0-no-kernel.log" "$EXIT_LOAD_FAILURE" \
    "缺少内核镜像：以 35 失败"
grep_log "$LOG_DIR/m0-no-kernel.log" '内核装载失败' "报告了失败原因"

# --- B2. 反向：ESP 中没有用户镜像 → 装载失败（35） ---
boot_case "$WORK/loader.efi" "$WORK/KERNEL.ELF" "$LOG_DIR/m4-no-user.log" "$EXIT_LOAD_FAILURE" \
    "缺少用户镜像：以 35 失败" "-"
grep_log "$LOG_DIR/m4-no-user.log" '用户镜像装载失败' "报告了用户镜像的失败原因"

# --- C. 反向 2：内核镜像存在但不是合法 ELF → 装载失败（35） ---
boot_case "$WORK/loader.efi" "$WORK/not-elf.bin" "$LOG_DIR/m0-bad-elf.log" "$EXIT_LOAD_FAILURE" \
    "非 ELF 镜像：以 35 失败"
grep_log "$LOG_DIR/m0-bad-elf.log" '缺少 ELF magic' "报错指明了具体原因（缺少 ELF magic）"
if grep -q '\[kernel\]' "$LOG_DIR/m0-bad-elf.log"; then
    bad "非法镜像却仍跳入了内核"
else
    ok "非法镜像未跳入内核"
fi

# --- D. 反向 3：BootInfo.magic 被注入错误 → 内核自检失败（39） ---
boot_case "$WORK/loader-bad-magic.efi" "$WORK/KERNEL.ELF" "$LOG_DIR/m0-bad-magic.log" "$EXIT_KERNEL_FAILURE" \
    "错误的 BootInfo.magic：内核自检失败并以 39 退出"
grep_log "$LOG_DIR/m0-bad-magic.log" 'self-check FAILED' "内核报告了自检失败"
grep_log "$LOG_DIR/m0-bad-magic.log" 'magic 不匹配' "失败原因指明是 magic 不匹配"

# --- E. 故障注入：内核执行 ud2 → 异常处理器报告并以 41 退出 ---
echo "==> 附加用例：异常处理器（故障注入）"
if ! cargo build -p kernel --target "$BARE_TARGET" --features inject-fault; then
    echo "[-] 注入故障的内核构建失败。" >&2
    exit 1
fi
cp "target/${BARE_TARGET}/debug/kernel" "$WORK/KERNEL-fault.ELF"
boot_case "$WORK/loader.efi" "$WORK/KERNEL-fault.ELF" "$LOG_DIR/m1-fault.log" "$EXIT_KERNEL_FAULT" \
    "内核触发 #UD：异常处理器报告并以 41 退出"
grep_log "$LOG_DIR/m1-fault.log" '未处理的 CPU 异常' "打印了异常诊断"
grep_log "$LOG_DIR/m1-fault.log" '#UD' "指认了向量（#UD 非法指令）"
grep_log "$LOG_DIR/m1-fault.log" 'rip=0x' "打印了出错指令地址"

# --- F. 故障注入：内核页表生效后解引用空指针 → #PF → 41（M2a） ---
#
# 页 0 按策略永不映射（memory_subsystem.md §3.4）。固件的恒等映射通常会把页 0 也映射，
# 所以"读地址 0 会 #PF"正是"生效的是内核自己的页表"的直接证据。
echo "==> 附加用例：内核自建页表（故障注入）"
if ! cargo build -p kernel --target "$BARE_TARGET" --features inject-null-deref; then
    echo "[-] 注入空指针访问的内核构建失败。" >&2
    exit 1
fi
cp "target/${BARE_TARGET}/debug/kernel" "$WORK/KERNEL-null.ELF"
boot_case "$WORK/loader.efi" "$WORK/KERNEL-null.ELF" "$LOG_DIR/m2a-null-deref.log" "$EXIT_KERNEL_FAULT" \
    "读取未映射的页 0：内核自己的页表生效并以 41 退出"
grep_log "$LOG_DIR/m2a-null-deref.log" 'paging: 恒等映射' "崩溃前已完成页表安装"
grep_log "$LOG_DIR/m2a-null-deref.log" '#PF 页错误' "指认了向量（#PF 页错误）"
grep_log "$LOG_DIR/m2a-null-deref.log" 'cr2=0x0 ' "CR2 指出出错地址正是页 0"

# 只在注入版里出现的提示，用来确认我们确实走到了那条路径，而不是别的原因导致的 #PF
grep_log "$LOG_DIR/m2a-null-deref.log" '\[inject\] 故意读取未映射的页 0' "命中注入路径"

# --- G. 故障注入：页帧分配器重复发出同一个页帧 → 内存自检以 43 退出（M2b） ---
#
# "两次分配返回了同一个页帧"是页帧分配器最危险的 bug 类型：两个使用者会拿到同一块内存。
echo "==> 附加用例：页帧重复分配（故障注入）"
if ! cargo build -p kernel --target "$BARE_TARGET" --features inject-memory-fault; then
    echo "[-] 注入页帧重复分配的内核构建失败。" >&2
    exit 1
fi
cp "target/${BARE_TARGET}/debug/kernel" "$WORK/KERNEL-double.ELF"
boot_case "$WORK/loader.efi" "$WORK/KERNEL-double.ELF" "$LOG_DIR/m2b-double-alloc.log" "$EXIT_KERNEL_MEMORY_FAILURE" \
    "页帧重复分配：内存自检发现并以 43 退出"
grep_log "$LOG_DIR/m2b-double-alloc.log" 'memory self-check FAILED' "打印了自检失败"
grep_log "$LOG_DIR/m2b-double-alloc.log" '两次分配返回了同一个页帧' "失败原因指明是重复分配"

# --- H. 故障注入：真正的双重故障 → #DF 落在 IST1 栈上 → 41（M3a） ---
#
# 把 #PF/#GP 的门改坏再访问未映射地址：交付 #PF 失败 → 交付 #GP 也失败 → 真正的 #DF。
# 如果 IST 没配好，这里会是三重故障重启（即超时 124），而不是一条完整诊断。
echo "==> 附加用例：双重故障与 IST（故障注入）"
if ! cargo build -p kernel --target "$BARE_TARGET" --features inject-double-fault; then
    echo "[-] 注入双重故障的内核构建失败。" >&2
    exit 1
fi
cp "target/${BARE_TARGET}/debug/kernel" "$WORK/KERNEL-df.ELF"
boot_case "$WORK/loader.efi" "$WORK/KERNEL-df.ELF" "$LOG_DIR/m3a-double-fault.log" "$EXIT_KERNEL_FAULT" \
    "真正的双重故障：#DF 落在 IST1 栈上并以 41 退出"
grep_log "$LOG_DIR/m3a-double-fault.log" '#DF 双重故障' "指认了向量（#DF 双重故障）"
grep_log "$LOG_DIR/m3a-double-fault.log" '实际运行栈：IST1 栈' "直接证明异常换到了 IST1 栈（而不是三重故障）"
grep_log "$LOG_DIR/m3a-double-fault.log" 'error_code=0x0' "帧格式完整（真正的 #DF 带错误码）"

# --- J. 故障注入：服务在 CPL 3 解引用空指针 → 用户态故障 47（M4a） ---
#
# 区分的关键：CPL 3 的异常是"服务崩了"（47），CPL 0 的异常才是"内核崩了"（41）。
# 注入用内联汇编读空指针，避免把 .rodata 绝对引用拉进来（镜像链接在 4 GiB，small 代码模型
# 只能用 ±2 GiB 的 32 位绝对重定位，链接器会拒绝）。
echo "==> 附加用例：用户态故障（故障注入）"
if ! cargo build -p user --target "$BARE_TARGET" --features inject-user-fault; then
    echo "[-] 注入用户态故障的服务构建失败。" >&2
    exit 1
fi
cp "target/${BARE_TARGET}/debug/user" "$WORK/USER-fault.ELF"
boot_case "$WORK/loader.efi" "$WORK/KERNEL.ELF" "$LOG_DIR/m4a-user-fault.log" "$EXIT_USER_FAILURE" \
    "服务在 CPL 3 上触发 #PF：以 47（用户态故障）退出，而不是 41" "$WORK/USER-fault.ELF"
grep_log "$LOG_DIR/m4a-user-fault.log" '服务在 CPL 3 上发生异常' "报告了用户态故障而不是内核崩溃"
grep_log "$LOG_DIR/m4a-user-fault.log" 'cr2=0x0' "CR2 指出故障地址正是服务解引用的空指针"

# --- I. 故障注入：抢占被关闭 → 自旋线程拿不到标志 → 45（M3b） ---
#
# 时钟照常计 tick，但调度器永不切换到别的线程。自旋线程的 tick 预算耗尽后自检必须干净地
# 以 45 结束——这正是"有界预算"设计的价值：否则整机只会挂到超时（124）。
echo "==> 附加用例：抢占被关闭（故障注入）"
if ! cargo build -p kernel --target "$BARE_TARGET" --features inject-no-preempt; then
    echo "[-] 注入"关闭抢占"的内核构建失败。" >&2
    exit 1
fi
cp "target/${BARE_TARGET}/debug/kernel" "$WORK/KERNEL-nopreempt.ELF"
boot_case "$WORK/loader.efi" "$WORK/KERNEL-nopreempt.ELF" "$LOG_DIR/m3b-no-preempt.log" "$EXIT_KERNEL_SCHED_FAILURE" \
    "抢占被关闭：自检以 45 退出而不是挂死"
grep_log "$LOG_DIR/m3b-no-preempt.log" '调度自检第 3 步失败' "指明是抢占那一步失败"
grep_log "$LOG_DIR/m3b-no-preempt.log" '抢占测试没有结束' "失败原因指明抢占测试没有结束"

echo
echo "结果: ${pass} 项通过, ${fail} 项失败"
if [ "$fail" -ne 0 ]; then
    exit 1
fi
exit 0
