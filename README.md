# Notch Focus

A native macOS task timer for the MacBook camera notch. It runs as a menu-bar app and saves its history on this Mac.

## Use the notch

During focus, the category and countdown sit to the left of the camera. The task name and cycle count, such as **2/3**, sit to the right. Hover just below the camera to see details for the active task, including the full cycle name. During a break the compact notch reads **Break**. The remaining-time line follows the lower edge in the routine’s pastel category color. The menu-bar timer also opens the panel on another display.

## Create a routine

Choose **Add a task** at the notch or the **+** in the planner. Set a name, category, focus time per cycle, and break time. Time fields accept minutes or `m:ss`. Add, rename, and reorder cycles. Select **One time** or a target of one to seven complete runs per week. You can work toward the target on any day.

The **Study TypeScript** example fills in a three-cycle routine for recall, learning new methods, and explaining and drilling the concept. You can edit everything before saving.

## Run and queue

Press **Start focus** to begin. A short chime marks every five minutes of active focus within a cycle. Pausing also pauses the count toward the next chime. At the end of the cycle a descending chime starts the routine’s break. A rising chime ends it and starts the next queue entry. While running a full routine, each completed cycle adds the following cycle after the entries already in your queue. When the queue is empty, the timer returns to idle.

Use **Queue routine** for a whole run, or use the queue button beside a named cycle for just that cycle. Open **Play queue** to see upcoming entries, remove an item, or start the next one when idle or on break. The planner shows weekly runs and total focused time.

Switching tasks saves elapsed focus time. Pausing and resuming the same task keeps its remaining time. Tasks from the original version retain their timing rules until edited into a routine.

## Build and run locally

Open `Package.swift` in Xcode, or run these commands on macOS with Xcode command-line tools installed.

```sh
swift test
./scripts/build-app.sh
open ".build/Notch Focus.app"
```

The script creates a locally signed macOS application bundle. The timer and history are stored under `~/Library/Application Support/NotchFocus/`.
