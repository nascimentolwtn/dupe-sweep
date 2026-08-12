# Installation Guide for DupeSweep

Since Flutter is not yet installed on your system, follow these steps to get started.

## 1. Install Flutter

### On Windows

1. **Download Flutter SDK**
   - Go to https://flutter.dev/docs/get-started/install/windows
   - Download the Flutter SDK (stable release, latest 3.0+)
   - Extract it to a location like `C:\src\flutter` (avoid paths with spaces)

2. **Add Flutter to PATH**
   - Open Environment Variables (Windows Settings → Search "Environment Variables")
   - Click "Edit the system environment variables"
   - Under "System variables", click "New"
   - Variable name: `FLUTTER_HOME` or just add to existing PATH
   - Variable value: `C:\src\flutter\bin` (or wherever you extracted Flutter)
   - Click OK and close the dialog

3. **Verify Installation**
   ```bash
   flutter --version
   flutter doctor
   ```
   The `flutter doctor` command will show you what else you need to set up (Android SDK, etc.).

### Android Setup

1. **Install Android SDK** (if not already present)
   - Download Android Studio from https://developer.android.com/studio
   - Install and open it
   - Go to SDK Manager (bottom-right corner of welcome screen)
   - Install:
     - Android SDK Platform 33 or higher (for `READ_MEDIA_IMAGES` support)
     - Android SDK Build-Tools (latest)
     - Android Emulator (optional, but helpful for testing)

2. **Set ANDROID_HOME Environment Variable**
   - Add a system environment variable:
     - Variable name: `ANDROID_HOME`
     - Variable value: Path to your Android SDK (usually `C:\Users\YourUsername\AppData\Local\Android\sdk`)

3. **Accept Licenses**
   ```bash
   flutter doctor --android-licenses
   ```
   Type `y` for each license prompt.

## 2. Clone or Navigate to Project

Navigate to the `dupesweep` project directory in PowerShell or Command Prompt:

```bash
cd e:\dev\similar-cleanup
```

## 3. Install Dependencies

```bash
flutter pub get
```

This downloads all the packages listed in `pubspec.yaml`.

## 4. Connect Android Device

1. **Enable USB Debugging on Your Phone**
   - Go to Settings → Developer Options (or Settings → About Phone, tap Build Number 7 times)
   - Enable "USB Debugging"

2. **Connect via USB**
   - Plug your phone into your computer with a USB cable
   - Accept the "Allow USB debugging?" prompt on your phone

3. **Verify Connection**
   ```bash
   flutter devices
   ```
   Your phone should appear in the list.

## 5. Run the App

```bash
flutter run
```

This compiles the app and installs it on your connected device. The app will launch automatically.

## 6. Running Tests

```bash
flutter test
```

This runs the unit tests in `test/similarity_service_test.dart`.

## Troubleshooting

**"flutter: command not found"**
- Make sure Flutter's `bin` folder is in your PATH and you've restarted your terminal/IDE.

**"Android SDK not found"**
- Run `flutter doctor` to see what's missing.
- Install Android Studio if you haven't already.
- Set `ANDROID_HOME` environment variable (see step 2).

**"No connected devices"**
- Check that USB Debugging is enabled on your phone.
- Try a different USB cable.
- Restart adb: `adb kill-server` then `adb start-server`

**App crashes on startup**
- Check logcat: `flutter logs`
- Make sure your device is Android 13 or higher.

## Next Steps

Once the app is running on your phone:

1. Grant photo library permission when prompted.
2. Wait for the scan to complete (this may take a moment on large photo libraries).
3. Review grouped photos and select any to delete.
4. Tap "Delete Selected" to confirm.

Happy deduping!
