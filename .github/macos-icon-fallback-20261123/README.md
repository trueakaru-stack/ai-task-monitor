# Isolated CI icon fallback

`AppIcon.icns` is copied without modification from the published [v0.3.7-alpha macOS image](https://github.com/trueakaru-stack/ai-task-monitor/releases/tag/v0.3.7-alpha), which points to commit `c034eef660922c9a06ee601e6ab9f8eac22b7889`. The image's published SHA-256 is `0f5c8684af5f660ee8ba02f970038526784794d31bd2966d2ff826a11596c920`; the extracted icon's SHA-256 is `ec9ba4d716b1988dfad213127d9d2dffbb37e188199f8c7576d4325774e78e67`. The signed bundle's resource manifest records that same icon hash. The seven PNGs used by `build-app.sh` and its iconset construction are unchanged between that commit and the candidate.

Decoded RGBA pixels of all PNG-backed representations and the 32 px ARGB representation in the published icon match the corresponding source PNGs. In the 16 px ARGB representation, one blue channel of one pixel differs from the PNG by 1 out of 255; the fallback preserves the previously published ICNS byte for byte.

This directory is only for the disposable hosted CI build. The ordinary `macos/scripts/build-app.sh` remains unchanged. `iconutil-ci.sh` accepts only the exact iconutil invocation of that script, validates the runner, paths, source and staged inputs, and tries the system tool first. Only if that tool fails does it copy this checked ICNS. Its test mode is restricted to a separately created synthetic directory within the hosted runner's temporary tree. The CI checks the fallback hash in the signed app and again in the mounted DMG.

The complete SHA-256 input values are:

```text
26a0c117876b90172a4d2c6dfd0ce90f8775a02505f2117d308c9b9b942fa336  icon-16.png
e544079c37c58fe7b048f6c864565eba81f90f342f4ef5fe4d4a1d1e959600ec  icon-32.png
b415afb520d28d8cc8ba68d45a83c5c0c65852058871ea952daeaad0319016f2  icon-64.png
7e4659d724e69ca3ae7e40acb101ff72714f602bfe35765f209343ae1ed21505  icon-128.png
c4f1f3b288b41079799b4f8b8134df47d1a3dd17274813fab7f1fad587e901d6  icon-256.png
79d37b5a4e4db2af0c3d7c15c374bd5415d7ea1c2288fe2f9a33f9c29927003b  icon-512.png
41c12eba042d3a6184aa10ff296597d2f28d4fab700a7adea9714638b5def3e0  icon-1024.png
ec9ba4d716b1988dfad213127d9d2dffbb37e188199f8c7576d4325774e78e67  AppIcon.icns
```

`icon-48.png` is not an input to the iconset constructed by `build-app.sh`.
