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

## Config

Edit [lib/config/custom_tabs_config.dart](lib/config/custom_tabs_config.dart):

- `_devUrl`
- `_prodUrl`
- `APP_ENV` (`dev` or `prod`)
- `TARGET_URL` (runtime override)
