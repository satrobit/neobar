#!/usr/bin/env python3
"""Look in the build log for warnings of the "conformance is only available on a newer macOS" kind, and fail if any are found.

Usage: python3 Scripts/check_availability_warnings.py <build log> [more logs...]

Why this gate is needed (added 2026-09-08, after three consecutive releases shipped broken):
The new SDK marks the `Hashable` and `Codable` conformances of `CGRect` / `CGPoint` / `CGSize` / `CGVector` as
macOS 15+, while this project's minimum deployment target is macOS 12. Code like `Set<CGRect>` **only produces a warning at compile time**
(it is an error only in Swift 6 language mode), so the build still succeeds and unit tests still pass on the new system,
but on macOS 14 and earlier machines the witness table can't be found at runtime -> a segfault at launch.
0.11.0 / 0.11.1 / 0.11.2 all failed to open on older systems exactly this way.

The log must come from a **full** compile (clean build or a fresh checkout): files an incremental build doesn't recompile won't print their warnings again.
"""
import pathlib
import re
import sys

# The compiler's own wording: conformance of 'CGRect' to 'Hashable' is only available in macOS 15.0 or newer
PATTERN = re.compile(r'is only available in macOS')
# Only our own source paths count: similar warnings in the SDK / dependency packages shouldn't block a release.
OURS = re.compile(r'/(App|Core|Platform|Tests|UI)/[^ ]*\.swift')


def main() -> int:
    logs = [pathlib.Path(a) for a in sys.argv[1:]]
    if not logs:
        print(__doc__)
        return 2

    hits = []
    for log in logs:
        if not log.exists():
            print(f'❌ 构建日志不存在：{log}')
            return 1
        for line in log.read_text(errors='replace').splitlines():
            if PATTERN.search(line) and OURS.search(line):
                hits.append(line.strip())

    if hits:
        print('❌ 构建日志里有「一致性 / API 只在更高版本 macOS 上可用」的警告。')
        print('   这类警告不拦构建，但在最低支持的系统上是运行时崩溃，必须改掉：')
        for line in dict.fromkeys(hits):
            print(f'   {line}')
        return 1

    print(f'✅ 未发现跨版本一致性警告（扫了 {len(logs)} 份构建日志）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
