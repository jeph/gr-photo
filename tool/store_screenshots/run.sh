#!/usr/bin/env bash
# Takes the raw screens of the App Store and Google Play screenshots on iOS
# simulators and an Android emulator, in the dark theme and in each language
# asked for, against a simulated camera whose card and looks look used
# (app/integration_test/store_screens_test.dart). compose.py turns them
# into the captioned screenshots.
#
#   tool/store_screenshots/run.sh <device>=<id> ... [locale ...]
#
# A device is `iphone`, `ipad` or `duo` with the simulator that stands for
# it, or `android` with the emulator's serial (`emulator-<port>`): the App
# Store takes 1320 x 2868 (iPhone 17 Pro Max), 2064 x 2752 (iPad Pro
# 13-inch) and 2853 x 2007 (iPhone Duo, open), and the Android screens go
# into a drawn phone at the size Google Play takes, so any phone-sized
# emulator does (a Pixel 9 takes 1080 x 2424). List simulators with
# `xcrun simctl list devices available` and emulators with `adb devices`.
# A locale is one of the app's (app/l10n.yaml); without any, the screens are
# taken in English. They go to build/store-screenshots/raw/<device>/<locale>.
#
# The app is built once for each platform, with the walk as its entry
# point, and each simulator or emulator is restarted in each language and
# runs it: GR Photo follows the phone's language, and so do the status bar
# and the Lock Screen.
#
# An iPhone Duo starts closed, and Xcode 27.1 has no command that opens it:
# each time the script says so, press Open on the simulator in Device Hub.
# The walk starts when the inner display comes on. Needs ImageMagick 7
# (`magick`) to see that it has.
#
# The emulator needs a system image without Google Play, whose adb can run
# as root: only root sets the system's language and clock. Its status bar
# is SystemUI's demo mode, and the run turns its lock screen on.
#
# The photos on the card are listed in photos.json: Unsplash photos under
# the Unsplash License, fetched on the first run and kept out of the
# repository.
#
# With --site (and only an iphone= device) the walk takes each screen once
# in each of the app's themes instead, in the light ones too, for the
# website: the screens it shows go to site/public/screens/<locale>/<theme>,
# as WebP 600 pixels wide: twice the widest phone on the page.
set -euo pipefail

devices=()
locales=()
site=false
for argument in "$@"; do
  case "$argument" in
  --site) site=true ;;
  iphone=* | ipad=* | duo=* | android=*) devices+=("$argument") ;;
  *) locales+=("$argument") ;;
  esac
done
if [[ ${#devices[@]} -eq 0 ]] || { $site && [[ "${devices[*]}" != iphone=* || ${#devices[@]} -gt 1 ]]; }; then
  echo "usage: $0 <iphone|ipad|duo|android>=<udid|serial> ... [locale ...]" >&2
  echo "       $0 --site iphone=<udid> [locale ...]" >&2
  exit 64
fi
[[ ${#locales[@]} -gt 0 ]] || locales=(en)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="$root/build/store-screenshots"
media="$work/media"
bundle=io.jeph.grphoto.dev
# Where the walk's folders are on an emulator, in the app's own files: the
# app can't read the Mac's file system there, so the host copies the photos
# in and looks for requests with run-as.
android_files="/data/user/0/$bundle/files"
# How long a walk may take before the run gives up on it: a walk for the
# site takes every screen five times.
walk_seconds=420
$site && walk_seconds=900
# The themes the site's screens are taken in (AppTheme's names; Auto is
# Light or Dark), and the screens site/src/pages shows.
site_themes='["light","dark","darkroom","paper","cyanotype"]'
site_screens=(library viewer-details viewer-map looks looks-load-confirm look-editor look-editor-colour remote live-view)

# Each scene in the three sizes a camera serves, and as a live view frame:
# the app drops frames over 1 MiB, which the views are. An upright photo is
# stored on its side, as a GR stores it; the card says how it was held.
fetch_media() {
  mkdir -p "$media"
  local scene portrait url base size width height
  while IFS=$'\t' read -r scene portrait url; do
    base="$media/s$(printf '%02d' "$scene")"
    for size in thumb:480 view:2400 full:3000 live:1280; do
      [[ -s "${base}_${size%%:*}.jpg" ]] && continue
      width="${size##*:}"
      height=$((width * 2 / 3))
      if [[ "$portrait" == true ]]; then
        curl -fsSL --max-time 120 -o "${base}_${size%%:*}.jpg" \
          "$url?w=$height&h=$width&fit=crop&q=88&fm=jpg"
        sips -r 270 "${base}_${size%%:*}.jpg" >/dev/null
      else
        curl -fsSL --max-time 120 -o "${base}_${size%%:*}.jpg" \
          "$url?w=$width&h=$height&fit=crop&q=88&fm=jpg"
      fi
    done
  done < <(jq -r '.[] | [.scene, .portrait, .url] | @tsv' "$here/photos.json")
  jq '[.[] | {scene, portrait}]' "$here/photos.json" >"$media/scenes.json"
}

# The language (a BCP 47 tag, which Android takes too) and region iOS is
# set to for a locale of the app.
system_language() {
  case "$1" in
  en) echo "en-US en_US" ;;
  pt) echo "pt-PT pt_PT" ;;
  da) echo "da-DK da_DK" ;;
  sv) echo "sv-SE sv_SE" ;;
  cs) echo "cs-CZ cs_CZ" ;;
  el) echo "el-GR el_GR" ;;
  ko) echo "ko-KR ko_KR" ;;
  ja) echo "ja-JP ja_JP" ;;
  zh) echo "zh-Hans-CN zh_CN" ;;
  zh_Hant) echo "zh-Hant-TW zh_TW" ;;
  fr | de | es | it | nl | fi | pl | hu | tr | ru | th)
    echo "$1-$(tr '[:lower:]' '[:upper:]' <<<"$1") $1_$(tr '[:lower:]' '[:upper:]' <<<"$1")"
    ;;
  *)
    echo "$1 is not a locale of the app" >&2
    return 1
    ;;
  esac
}

# Sets the language of a simulator that is shut down.
set_language() {
  local udid="$1" language region
  read -r language region <<<"$(system_language "$2")"
  local preferences="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/Preferences/.GlobalPreferences.plist"
  plutil -replace AppleLanguages -json "[\"$language\"]" "$preferences"
  plutil -replace AppleLocale -string "$region" "$preferences"
  # The Lock Screen shows the status bar's time only with a 24-hour clock or
  # in English: with the 12-hour clock of Greek, Korean and Taiwan it shows
  # the real time (iOS 26.5).
  if [[ "$2" == en ]]; then
    plutil -remove AppleICUForce24HourTime "$preferences" 2>/dev/null || true
  else
    plutil -replace AppleICUForce24HourTime -bool true "$preferences"
  fi
}

# Records that the user allowed the app's Live Activities both times iOS
# asks, under the first one (Allow) and under a later one (Always Allow):
# simctl has no grant for them. The daemon that keeps the record reads it
# when it starts.
allow_live_activities() {
  local udid="$1" daemon=com.apple.liveactivitiesd key
  xcrun simctl spawn "$udid" defaults write "$daemon" \
    AppAuthorizationRecords -dict "$bundle" -bool true
  for key in FirstResponseRecords SecondResponseRecords; do
    xcrun simctl spawn "$udid" defaults write "$daemon" "$key" -array "$bundle"
  done
  xcrun simctl spawn "$udid" launchctl stop "$daemon"
}

# Runs a shell command on an emulator as the app, which can read and write
# the walk's folders.
as_app() {
  local serial="$1"
  shift
  adb -s "$serial" shell run-as "$bundle" "$@"
}

# Takes a screenshot. An iPhone Duo has two displays, and which of them
# simctl takes by itself changes with the pose: 3 is the inner one.
screenshot() {
  local device="$1" id="$2" file="$3"
  case "$device" in
  android) adb -s "$id" exec-out screencap -p >"$file" ;;
  duo) xcrun simctl io "$id" screenshot --display=3 "$file" >/dev/null 2>&1 ;;
  *) xcrun simctl io "$id" screenshot "$file" >/dev/null 2>&1 ;;
  esac
}

# The names of the requests the walk has written and the host has not yet
# taken.
requests() {
  local device="$1" id="$2" shots="$3" request
  if [[ "$device" == android ]]; then
    as_app "$id" ls files/store-shots | tr -d '\r' | sed -n 's/\.request$//p'
    return
  fi
  for request in "$shots"/*.request; do
    [[ -e "$request" ]] && basename "$request" .request
  done
}

forget_request() {
  local device="$1" id="$2" shots="$3" name="$4"
  if [[ "$device" == android ]]; then
    as_app "$id" rm -f "files/store-shots/$name.request"
  else
    rm -f "$shots/$name.request"
  fi
}

# Locks the device and takes its Lock Screen. The emulator's lock screen
# shows the real time, unlike its status bar, so its clock is set to the
# status bar's time first.
take_lock_screen() {
  local device="$1" id="$2" shots="$3"
  if [[ "$device" == android ]]; then
    # The emulator keeps the Mac's time zone.
    adb -s "$id" shell date "$(date +%m%d0941%Y.00)" >/dev/null
    adb -s "$id" shell input keyevent KEYCODE_SLEEP
    sleep 2
    adb -s "$id" shell input keyevent KEYCODE_WAKEUP
    sleep 4
  else
    xcrun simctl spawn "$id" "$work/lock_button"
    sleep 4
    xcrun simctl spawn "$id" "$work/lock_button"
    sleep 4
  fi
  screenshot "$device" "$id" "$shots/lock-screen.png"
}

# Waits for an iPhone Duo to be opened: its inner display is black while it
# is closed.
wait_open() {
  local udid="$1" shots="$2" told=false
  until screenshot duo "$udid" "$shots/open.png" &&
    [[ "$(magick "$shots/open.png" -alpha off -format '%[fx:mean>0.01]' info:)" == 1 ]]; do
    $told || echo "duo: press Open on the simulator in Device Hub" >&2
    told=true
    sleep 2
  done
  rm -f "$shots/open.png"
}

# Takes a screenshot for each <name>.request the walk writes into its
# folder. `failure` is the walk giving up, and cmd-lock its end: it locks
# the device and takes the Lock Screen.
watch_requests() {
  local device="$1" id="$2" shots="$3" name
  while true; do
    for name in $(requests "$device" "$id" "$shots"); do
      case "$name" in
      cmd-lock)
        take_lock_screen "$device" "$id" "$shots"
        touch "$shots/done"
        return
        ;;
      failure)
        screenshot "$device" "$id" "$shots/failure.png"
        touch "$shots/failed"
        return
        ;;
      *)
        screenshot "$device" "$id" "$shots/$name.png"
        ;;
      esac
      forget_request "$device" "$id" "$shots" "$name"
    done
    sleep 0.3
  done
}

# Waits for the walk on a device to end, and stops [watcher] and [app].
wait_walk() {
  local shots="$1" watcher="$2" app="$3" waited=0
  until [[ -e "$shots/done" || -e "$shots/failed" || $waited -ge $walk_seconds ]]; do
    sleep 1
    waited=$((waited + 1))
  done
  kill "$watcher" "$app" 2>/dev/null || true
  wait "$watcher" "$app" 2>/dev/null || true
}

# Restarts a simulator in a language, ready for the walk.
start_simulator() {
  local device="$1" udid="$2" locale="$3" shots="$4" data zone

  # Restarted, for the language and because a simulator left running may
  # still show what an earlier walk left on it, such as a permission prompt
  # nothing answered.
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  set_language "$udid" "$locale"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" >/dev/null
  [[ "$device" != duo ]] || wait_open "$udid" "$shots"
  # The date as well as the time: a time alone puts the Lock Screen on
  # 1 January. simctl takes an ISO date only with milliseconds and a colon
  # in the time zone, and the simulator (iOS 26.5) keeps its day and month
  # only in English: in the other languages the Lock Screen shows 1 January
  # whatever the date.
  zone="$(date +%z)"
  xcrun simctl status_bar "$udid" override \
    --time "$(date +%Y-%m-%d)T09:41:00.000${zone:0:3}:${zone:3}" \
    --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 \
    --dataNetwork wifi --operatorName ""
  xcrun simctl ui "$udid" appearance dark
  # Praça do Comércio, Lisbon: where the newest photos of the card are from.
  xcrun simctl location "$udid" set 38.7075,-9.1364
  # A fresh install, so every walk starts from the same state. iOS would
  # ask for the location over the screens and whether to allow Live
  # Activities under the first one, where nothing can answer.
  xcrun simctl uninstall "$udid" "$bundle" 2>/dev/null || true
  xcrun simctl install "$udid" "$root/app/build/ios/iphonesimulator/Runner.app"
  xcrun simctl privacy "$udid" grant location-always "$bundle"
  allow_live_activities "$udid"
  # Where the walk finds its folders: an app started on a simulator gets
  # nothing from the host's environment.
  data="$(xcrun simctl get_app_container "$udid" "$bundle" data)/Library/Application Support"
  mkdir -p "$data"
  jq -n --arg shots "$shots" --arg media "$media" \
    --argjson themes "$($site && echo "$site_themes" || echo '[]')" \
    '{$shots, $media, $themes}' >"$data/store-screenshots.json"
}

# Waits for an emulator to finish booting and has its adb run as root.
wait_boot() {
  local serial="$1"
  adb -s "$serial" wait-for-device
  until [[ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; do
    sleep 1
  done
  adb -s "$serial" root >/dev/null
  adb -s "$serial" wait-for-device
}

# Sends a command to SystemUI's demo mode, which draws the status bar.
demo() {
  local serial="$1"
  shift
  adb -s "$serial" shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null
}

# Restarts an emulator in a language, ready for the walk.
start_emulator() {
  local serial="$1" locale="$2" language key nothing=$'\xe2\x80\x8b'
  read -r language _ <<<"$(system_language "$locale")"
  adb -s "$serial" root >/dev/null
  adb -s "$serial" wait-for-device
  # Settings SystemUI reads when it starts, so they come before the
  # restart. The lock screen the walk ends on, which an emulator has none of
  # by default, shows the app's notifications whole, as a phone set up to
  # show them does: they are silent ones, which Android 17 leaves out of the
  # lock screen by default and draws as icons alone. No user switcher or
  # carrier name: the carrier's name is a zero-width space, which hides it
  # where an empty one is ignored. A clock the run can set for the lock
  # screen, and the dark theme. Demo mode can't set the emulator's mobile
  # signal (Android 17), which shows one bar and 3G, so the status bar shows
  # Wi-Fi alone.
  adb -s "$serial" shell "setprop persist.sys.locale $language &&
    locksettings set-disabled false &&
    settings put secure lock_screen_show_silent_notifications 1 &&
    settings put secure lock_screen_notification_minimalism 0 &&
    settings put global user_switcher_enabled 0 &&
    cmd phone cc set-value -s 0 -p carrier_name_override_bool true &&
    cmd phone cc set-value -s 0 -p carrier_name_string '$nothing' &&
    settings put global auto_time 0 && cmd uimode night yes &&
    settings put global sysui_demo_allowed 1 &&
    settings put secure icon_blacklist mobile" >/dev/null
  adb -s "$serial" reboot
  adb -s "$serial" wait-for-disconnect
  wait_boot "$serial"

  # The clock a few minutes before the lock screen's, so the notifications
  # the app posts on the way are a few minutes old there. The emulator
  # keeps the Mac's time zone.
  adb -s "$serial" shell "input keyevent KEYCODE_WAKEUP && wm dismiss-keyguard &&
    date $(date +%m%d0938%Y.00)" >/dev/null
  # Demo mode entered before the status bar shows the emulator's Wi-Fi,
  # which it does once the network is validated, leaves that Wi-Fi's icon
  # beside its own.
  until adb -s "$serial" shell dumpsys connectivity |
    grep 'ni{WIFI CONNECTED' | grep IS_VALIDATED >/dev/null; do
    sleep 1
  done
  # The emulator's own notices, such as that its serial console is on.
  for key in $(adb -s "$serial" shell cmd notification list | tr -d '\r' | grep '^[-0-9]*|android|'); do
    adb -s "$serial" shell cmd notification snooze --for 86400000 "'$key'" >/dev/null
  done
  demo "$serial" enter
  demo "$serial" clock -e hhmm 0941
  demo "$serial" battery -e level 100 -e plugged false -e powersave false
  demo "$serial" network -e wifi show -e level 4 -e fully true
  demo "$serial" notifications -e visible false
  demo "$serial" status -e volume hide -e bluetooth hide -e location hide \
    -e alarm hide -e sync hide -e mute hide -e speakerphone hide
  # Praça do Comércio, Lisbon: where the newest photos of the card are from.
  adb -s "$serial" emu geo fix -9.1364 38.7075 >/dev/null

  # A fresh install with every permission, so every walk starts from the
  # same state with nothing asking over the screens. Out of battery
  # optimisation, as the app asks to be for downloads and geotagging.
  adb -s "$serial" uninstall "$bundle" >/dev/null 2>&1 || true
  adb -s "$serial" install -g \
    "$root/app/build/app/outputs/flutter-apk/app-dev-debug.apk" >/dev/null
  adb -s "$serial" shell dumpsys deviceidle whitelist "+$bundle" >/dev/null
  COPYFILE_DISABLE=1 tar -cf - -C "$media" . |
    adb -s "$serial" exec-in "run-as $bundle sh -c 'mkdir -p files/store-media files/store-shots && tar -xf - -C files/store-media'"
  jq -n --arg shots "$android_files/store-shots" \
    --arg media "$android_files/store-media" '{$shots, $media}' |
    adb -s "$serial" exec-in "run-as $bundle sh -c 'cat > files/store-screenshots.json'"
}

# Walks the app on one device in one language.
take() {
  local device="$1" id="$2" locale="$3"
  local shots="$work/raw/$device/$locale" watcher app
  $site && shots="$work/raw/site/$locale"
  mkdir -p "$shots"
  rm -f "$shots"/*

  if [[ "$device" == android ]]; then
    start_emulator "$id" "$locale"
    adb -s "$id" logcat -c
    watch_requests "$device" "$id" "$shots" &
    watcher=$!
    adb -s "$id" logcat -v brief flutter:V '*:S' >"$shots/app.log" 2>&1 &
    app=$!
    adb -s "$id" shell am start -n "$bundle/io.jeph.grphoto.MainActivity" >/dev/null
    wait_walk "$shots" "$watcher" "$app"
    [[ -e "$shots/done" ]] ||
      as_app "$id" cat files/store-shots/failure.txt >"$shots/failure.txt" 2>/dev/null || true
    demo "$id" exit
    adb -s "$id" shell settings put global auto_time 1
  else
    start_simulator "$device" "$id" "$locale" "$shots"
    watch_requests "$device" "$id" "$shots" &
    watcher=$!
    xcrun simctl launch --console "$id" "$bundle" >"$shots/app.log" 2>&1 &
    app=$!
    # The locked app no longer runs the walk, so it ends with the Lock
    # Screen rather than with the app.
    wait_walk "$shots" "$watcher" "$app"
    xcrun simctl status_bar "$id" clear
    xcrun simctl shutdown "$id"
    rm -f "$shots"/*.request
  fi
  if [[ ! -e "$shots/done" ]]; then
    echo "$device $locale: the walk ended before its last screen; see $shots/failure.txt" >&2
    return 1
  fi
  rm -f "$shots/done"
  $site && export_site "$shots" "$locale"
  echo "$device $locale"
}

# Copies the screens the site shows from a walk for it into the site.
export_site() {
  local shots="$1" locale="$2" theme name out
  for theme in $(jq -r '.[]' <<<"$site_themes"); do
    out="$root/site/public/screens/$locale/$theme"
    mkdir -p "$out"
    for name in "${site_screens[@]}"; do
      magick "$shots/$name.$theme.png" -resize 600x -quality 75 "$out/$name.webp"
    done
  done
}

# Every language on one device, which is left in English.
take_all() {
  local device="$1" id="$2" locale failed=0
  for locale in "${locales[@]}"; do
    take "$device" "$id" "$locale" || failed=1
  done
  if [[ "$device" == android ]]; then
    adb -s "$id" shell setprop persist.sys.locale en-US
  else
    set_language "$id" en
  fi
  return $failed
}

for locale in "${locales[@]}"; do
  system_language "$locale" >/dev/null
done
fetch_media
if [[ " ${devices[*]}" =~ \ (iphone|ipad|duo)= ]]; then
  xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator \
    "$here/lock_button.c" -o "$work/lock_button" -framework CoreFoundation
  (cd "$root/app" && flutter build ios --simulator --debug --flavor dev \
    --target integration_test/store_screens_test.dart)
fi
if [[ " ${devices[*]}" == *" android="* ]]; then
  (cd "$root/app" && flutter build apk --debug --flavor dev \
    --target integration_test/store_screens_test.dart)
fi

running=()
for device in "${devices[@]}"; do
  take_all "${device%%=*}" "${device#*=}" &
  running+=($!)
done
trap 'kill "${running[@]}" 2>/dev/null || true' INT TERM
status=0
for job in "${running[@]}"; do
  wait "$job" || status=1
done
exit $status
