#!/usr/bin/env python3
"""Check that the localization keys match Localizable.xcstrings one to one, and count how much Chinese is still untranslated.

Usage: python3 Scripts/check_localization.py [--remaining]

A missing entry = non-English users suddenly see English at that spot, with no compile-time error at all.
Every language needs a value: LANGUAGES, `AppLanguageOption.localizationIdentifier` and
`knownRegions` must be kept in sync in three places; when adding a language, change all three together.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / 'Resources/Localizable.xcstrings'
INFOPLIST_CATALOG = ROOT / 'Resources/InfoPlist.xcstrings'
DIRS = ['App', 'Core', 'Platform', 'UI']
# English also needs an explicit value: when the source-language block is missing, the String Catalog doesn't generate en.lproj/Localizable.strings,
# and the per-app language column in System Settings is greyed out (rules in .claude/rules/localization.md).
LANGUAGES = ['en', 'zh-Hans', 'zh-Hant', 'ja', 'de', 'fr', 'es', 'es-419', 'pt-BR', 'pt-PT', 'it', 'ko', 'ru', 'tr', 'hi', 'vi']

STR = r'"((?:[^"\\]|\\.)*)"'
# Match against the whole text (allowing a newline after the constructor), and use match.start() to recover the line number
RE_LOCALIZED = re.compile(r'String\(\s*localized:\s*(?!""")' + STR)
RE_SWIFTUI = re.compile(r'\b(?:Text|Button|Toggle|Label|Picker|TextField)\(\s*' + STR)
# User-visible Chinese literals (used to count the remaining work)
RE_CHINESE = re.compile(STR)

SKIP_FILES = {'App/Scenes/ContentView.swift'}   # Unwired debug console, deliberately not translated per the plan


def unescape(s):
    return s.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')


def strip_comments(text):
    """Blank out whole comment lines while keeping the line count (so line numbers stay accurate)."""
    out = []
    in_block = False
    for line in text.splitlines():
        s = line.strip()
        if in_block:
            out.append('')
            if '*/' in line:
                in_block = False
            continue
        if s.startswith('/*'):
            out.append('')
            if '*/' not in line:
                in_block = True
            continue
        if s.startswith('//'):
            out.append('')
            continue
        out.append(line)
    return '\n'.join(out)


def lineno_of(text, pos):
    return text.count('\n', 0, pos) + 1


def eval_multiline(block_lines, closing_indent):
    out = []
    for line in block_lines:
        line = line[closing_indent:] if len(line) >= closing_indent else line.lstrip()
        out.append(line)
    text = '\n'.join(out)
    # Line-continuation at end of line: backslash + newline -> join directly
    text = re.sub(r'\\\n', '', text)
    return text


def extract_multiline(path):
    lines = pathlib.Path(path).read_text(encoding='utf-8').splitlines()
    keys = []
    i = 0
    while i < len(lines):
        if re.search(r'String\(localized:\s*"""\s*$', lines[i]):
            body = []
            j = i + 1
            while j < len(lines) and lines[j].strip() != '"""' and not lines[j].strip().startswith('""")'):
                body.append(lines[j])
                j += 1
            closing = len(lines[j]) - len(lines[j].lstrip()) if j < len(lines) else 0
            keys.append(eval_multiline(body, closing))
            i = j
        i += 1
    return keys


def scan():
    used, chinese = {}, []
    for d in DIRS:
        for f in sorted((ROOT / d).rglob('*.swift')):
            rel = str(f.relative_to(ROOT))
            if rel in SKIP_FILES:
                continue
            text = strip_comments(f.read_text(encoding='utf-8'))
            for rx in (RE_LOCALIZED, RE_SWIFTUI):
                for m in rx.finditer(text):
                    key = unescape(m.group(1))
                    if rx is RE_SWIFTUI and re.fullmatch(r'[a-z0-9]+(?:\.[a-z0-9]+)+', key):
                        continue   # SF Symbol name, e.g. folder.badge.plus
                    used.setdefault(key, []).append(f'{rel}:{lineno_of(text, m.start())}')
            for key in extract_multiline(f):
                used.setdefault(key, []).append(rel)
            for m in RE_CHINESE.finditer(text):
                if re.search(r'[一-龥]', m.group(1)):
                    chinese.append((f'{rel}:{lineno_of(text, m.start())}', m.group(1)))
    return used, chinese


def value_of(entry, lang):
    return entry.get('localizations', {}).get(lang, {}).get('stringUnit', {}).get('value')


RE_PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:@|d|lld|ld|u|f|s|%)')


def placeholder_mismatches(catalog):
    """Every language's placeholders must match the English in count and order -- one extra %@ is a runtime crash, one fewer is lost information."""
    out = []
    for key, entry in catalog.items():
        expected = RE_PLACEHOLDER.findall(value_of(entry, 'en') or key)
        for lang in LANGUAGES:
            value = value_of(entry, lang)
            if value is None:
                continue
            actual = RE_PLACEHOLDER.findall(value)
            if actual != expected:
                out.append((key, lang, expected, actual))
    return out


def main():
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))['strings']
    used, chinese = scan()

    missing = {k: v for k, v in used.items() if k not in catalog}
    unused = [k for k in catalog if k not in used]
    untranslated = {lang: [k for k, v in catalog.items() if not value_of(v, lang)] for lang in LANGUAGES}
    infoplist = json.loads(INFOPLIST_CATALOG.read_text(encoding='utf-8'))['strings']
    infoplist_untranslated = {lang: [k for k, v in infoplist.items() if not value_of(v, lang)] for lang in LANGUAGES}
    placeholder_drift = placeholder_mismatches(catalog)
    chinese_key = [k for k in used if re.search(r'[一-龥]', k)]

    print(f'代码引用 {len(used)} 个 key ｜ catalog {len(catalog)} 条 × {len(LANGUAGES)} 种语言 ｜ 源码剩余中文字面量 {len(chinese)} 处\n')

    ok = True
    if missing:
        ok = False
        print(f'❌ catalog 缺 {len(missing)} 条（非英文用户会看到英文）：')
        for k, locs in sorted(missing.items()):
            print(f'   {k[:70]!r}  ← {locs[0]}')
    for lang, keys in untranslated.items():
        if keys:
            ok = False
            print(f'\n❌ {len(keys)} 条没有 {lang} 翻译：')
            for k in keys:
                print(f'   {k[:70]!r}')
    for lang, keys in infoplist_untranslated.items():
        if keys:
            ok = False
            print(f'\n❌ InfoPlist.xcstrings 里 {len(keys)} 条没有 {lang} 值：{keys}')
    if placeholder_drift:
        ok = False
        print(f'\n❌ {len(placeholder_drift)} 处译文的占位符与英文不一致（运行时 String(format:) 会崩或串位）：')
        for k, lang, expected, actual in placeholder_drift:
            print(f'   [{lang}] {k[:60]!r}  en={expected}  {lang}={actual}')
    if chinese_key:
        ok = False
        print(f'\n❌ {len(chinese_key)} 个 key 本身是中文（源语言应为英文）：')
        for k in chinese_key:
            print(f'   {k[:70]!r}  ← {used[k][0]}')
    if unused:
        ok = False
        print(f'\n❌ catalog 里 {len(unused)} 条没被引用（死条目或扫描盲区，两种都要查）：')
        for k in unused:
            print(f'   {k[:70]!r}')

    if '--remaining' in sys.argv and chinese:
        print(f'\n--- 剩余中文字面量 {len(chinese)} 处 ---')
        for loc, s in chinese:
            print(f'   {loc}  {s[:60]}')

    print()
    print('✅ 全部对上' if ok else '⛔ 有问题，见上')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
