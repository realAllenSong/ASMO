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

## License and contributor agreement

ASMO is offered under the [GNU AGPL v3](LICENSE) (with the attribution terms in [NOTICE](NOTICE)) and, separately, under
commercial licences. So that both stay possible, by opening a pull request you agree that:

- the contribution is your own original work, and you have the right to submit it;
- you assign the copyright in your contribution to realAllenSong. Where an assignment is not possible, you grant
  realAllenSong a perpetual, irrevocable, worldwide, royalty-free licence to use, modify, sublicense and relicense it,
  including under commercial terms.

Your contribution is released to everyone under the AGPL v3.

The full terms are in the [Contributor License Agreement](CLA.md). On your first pull request a bot asks you to sign it
with one comment; the pull request can be merged once you have.

## Questions

Open an issue on GitHub.
