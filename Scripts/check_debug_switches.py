#!/usr/bin/env python3
"""Verify that every DOCK_* environment-variable switch is registered in Core/Support/DebugSwitch.swift.

Usage: python3 Scripts/check_debug_switches.py

Three rules; violating any of them exits with code 1:
1. Source under App/ Core/ Platform/ (except the registry itself) must not contain "DOCK_..." string literals -- switches are always read through DebugSwitch;
2. Every DOCK_... name appearing in Tests/ Tools/ Scripts/ must be in the registry (prevents tests / scripts from referencing deleted switches);
3. Every case in the registry must be referenced as `DebugSwitch.<case>` somewhere in App/ Core/ Platform/ -- a switch nobody reads is a dead switch.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REGISTRY = ROOT / 'Core/Support/DebugSwitch.swift'
SRC_DIRS = ['App', 'Core', 'Platform']
AUX_DIRS = ['Tests', 'Tools', 'Scripts']

LITERAL = re.compile(r'"(DOCK_[A-Z0-9_]+)"')
CASE = re.compile(r'^\s*case\s+([A-Za-z0-9_]+)\s*=\s*"(DOCK_[A-Z0-9_]+)"', re.M)
NAME = re.compile(r'\bDOCK_[A-Z0-9_]+\b')


def swift_files(dirs):
    for d in dirs:
        yield from (ROOT / d).rglob('*.swift')


def main() -> int:
    text = REGISTRY.read_text()
    registered = {raw: case for case, raw in CASE.findall(text)}
    if not registered:
        print(f'❌ 登记表里没解析到任何 case：{REGISTRY}')
        return 1
    problems = []

    # 1. No literals allowed in the source
    for f in swift_files(SRC_DIRS):
        if f == REGISTRY:
            continue
        for i, line in enumerate(f.read_text().splitlines(), 1):
            for raw in LITERAL.findall(line):
                problems.append(f'{f.relative_to(ROOT)}:{i}: 直接用了 "{raw}" —— 改成 DebugSwitch.{registered.get(raw, "<先登记>")}')

    # 2. Names referenced by tests / tools / scripts must already be registered
    for d in AUX_DIRS:
        for f in (ROOT / d).rglob('*'):
            if not f.is_file() or f.suffix not in ('.swift', '.sh', '.py') or f.name == 'check_debug_switches.py':
                continue
            for i, line in enumerate(f.read_text(errors='ignore').splitlines(), 1):
                for raw in NAME.findall(line):
                    if raw not in registered:
                        problems.append(f'{f.relative_to(ROOT)}:{i}: {raw} 未登记（删掉的开关？）')

    # 3. Registered but nobody reads it = dead switch
    src = '\n'.join(f.read_text() for f in swift_files(SRC_DIRS) if f != REGISTRY)
    for raw, case in registered.items():
        if f'DebugSwitch.{case}' not in src:
            problems.append(f'登记表：{raw}（.{case}）没有任何调用点，删掉它')

    print(f'登记 {len(registered)} 个开关')
    if problems:
        print('\n'.join('❌ ' + p for p in problems))
        return 1
    print('✅ 全部对上')
    return 0


if __name__ == '__main__':
    sys.exit(main())
