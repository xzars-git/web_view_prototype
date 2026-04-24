# web_view_prototype

Hybrid WebView app: normal pages are loaded in WebView, while payment pages are opened in Custom Tabs based on config rules.
Environment selection can be changed directly from in-app switcher (DEV/PROD).

## Run

Default (dev URL):

```bash
flutter run
```

Explicit dev:

```bash
flutter run --dart-define=APP_ENV=dev
```

Production URL profile:

```bash
flutter run --dart-define=APP_ENV=prod
```

Override URL directly (highest priority):

```bash
flutter run --dart-define=TARGET_URL=https://example.com
```

You can combine them, but `TARGET_URL` always wins.
If `APP_ENV` is not `dev` or `prod`, app will fallback to `dev`.

## Environment Switcher

- Use the switcher in app (`Use PROD`) to change between DEV and PROD.
- `TARGET_URL` is still highest priority and will override switcher selection.

## Changelog & Improvements

### [24 April 2026] - Smart Payment Bridge & UX Fixes
- **Improved Navigation Stack:** Added `LaunchMode.externalNonBrowserApplication` to prioritize opening native payment apps (DANA, ShopeePay, etc.) directly. This ensures the system "Back" button returns to the Flutter app instead of Chrome.
- **Zombie Tab Prevention:** Integrated `ChromeSafariBrowser` (InAppWebView) to replace standard `url_launcher` for Custom Tabs. The app now forcibly closes the browser tab upon receiving the `paymentCompleted` deep link.
- **Package Visibility Compliance:** Verified `<queries>` in `AndroidManifest.xml` to ensure compatibility with Android 11+ and Google Play Store policies.
- **Dynamic Fallback:** Implementation automatically falls back to Custom Tabs if a native application is not installed on the device.
