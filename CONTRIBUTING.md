# Contributing to ASMO

Thanks for your interest in improving ASMO. Bug reports, feature suggestions, code, docs and translations are all
welcome.

## Getting started

You need a Mac with Apple silicon, macOS 15 or later, and Xcode 26.

```bash
git clone https://github.com/realAllenSong/ASMO.git
cd ASMO
swift test                   # the date, parsing and planning rules
script/run_test_store.sh     # a Debug build on a separate test store
asmo ping --test             # the command, pointed at that test store
```

Test against the test store (`--test`), not your real data.

## Pull requests

- Open an issue first to discuss larger changes before writing code.
- Keep pull requests focused and small when possible.
- Follow the existing code style (Swift, SwiftUI; comments say why, not what).
- Include a short description of what the change does and why, and how you checked it.

## License

By contributing you agree that your changes will be released under the same [MIT License](LICENSE) that covers the
project. You retain copyright to your contribution.

## Questions

Open an issue on GitHub.
