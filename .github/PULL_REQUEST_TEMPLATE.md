## 📝 Summary

<!-- What does this PR change, and why? -->

## ✅ Checklist

- [ ] I read [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] Local-only transcription is preserved (no new network calls for audio/text)
- [ ] Tested on an Apple Silicon or Intel Mac running macOS 14+
- [ ] Ran the pre-PR checks:
  ```bash
  ./scripts/check.sh
  swift run -c debug --package-path swift Parakey --self-test all
  ./scripts/build-app.sh ./dist/SuperDictate.app
  ```
- [ ] If this changes the release version, `swift/Info.plist` and `install.sh` match

## 🔗 Related issues

<!-- Closes #... -->
