# NeoBar

A taskbar for macOS. NeoBar runs along the bottom of each screen, edge to edge, and shows your open windows and apps as cards you can click, drag, and reorder.

## Requirements

- macOS 12 or later to run. The Liquid Glass look needs macOS 26 or later; older versions get a frosted-glass bar.
- Xcode 26 or later to build.

## Build and run

```bash
xcodebuild -project NeoBar.xcodeproj -scheme NeoBar -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/NeoBar.app
```

Or open `NeoBar.xcodeproj` in Xcode and press ⌘R.

To run the tests:

```bash
xcodebuild test -project NeoBar.xcodeproj -scheme NeoBar -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

Debug builds are signed ad hoc. macOS may treat each rebuild as a new app and drop NeoBar's Accessibility permission. If the bar stops responding after a rebuild, remove NeoBar from System Settings → Privacy & Security → Accessibility and add it again.

## Permissions

- **Accessibility.** Required. NeoBar uses it to list, focus, minimize, and move windows.
- **Automation (Finder).** Optional. Used for the folder previews and the Trash.

## Credits

NeoBar is a fork of [Tungsten Edge](https://github.com/moonbai-studio/tungsten-edge) by Moonbai Studio, and more modifications are planned. Most of the window tracking, the drag and drop, the stack popups, and the rest of the core taskbar work comes from that project. Thanks to its authors for releasing it as open source.

## License

Tungsten Edge is licensed under the [GNU General Public License v3.0 or later](https://www.gnu.org/licenses/gpl-3.0.html). As a derivative work, NeoBar is distributed under the same license; see [LICENSE](LICENSE).
