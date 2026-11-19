# MacBook Pomodoro — requirements and behavior plan

First macOS build · 19 November 2026

Start focused work on a specific task, glance up to see how much time remains, and later see where the time went. The app lives at the MacBook notch. Its planner opens only when there is planning to do.

## Version 0.2 routines

The planner now uses a routine library. Each routine has a pastel category and icon, a focus duration, a break duration, named cycles, and a weekly run target or one-time setting. The compact notch shows a category icon and countdown on the left, with the task name and cycle fraction on the right. Its remaining-time line follows the sides and bottom. Hover opens the active task’s details, including the full cycle name. The compact break state reads **Break**.

A short cue marks each five minutes of active focus. Completing a cycle starts a break and plays the rest sound. At break expiry the second sound plays and the next queued item starts. A full routine contributes its successor after previously queued entries. An individual cycle can be queued on its own. A complete routine counts once toward the weekly target. The app uses local calendar weeks and can be used on any day.

The sections below document the original reference and first-release decisions from which the routine planner evolved.

## What the reference shows

| Recording | Observable behavior |
| --- | --- |
| 0:00–0:09 | The pointer moves to the notch. A black panel opens with a **To do** card and a **Journey Streak** grid. A separate **Tasks** planner appears directly beneath it. |
| 0:09–0:36 | The planner has a month calendar, **Day** and **Unscheduled** views, and a title and optional notes field. Saving adds the task to the planner and the notch list. |
| 0:36–0:48 | The new task has a 25-minute duration. A minutes-and-seconds control changes it to 30 minutes. Starting the task changes its blue Play button to a red Pause button. |
| 0:48–1:02 | Moving away collapses the panel to a compact countdown. Returning to the notch reveals the task list again while the countdown continues. |

The two supplied stills establish the visual baseline. The timer sits on the left, the task label on the right, and a thin blue progress line follows the two sides and bottom. In the expanded view the task card stays on the left and the blue activity grid on the right. The recording does not reach the end of a session or explain how a streak is earned. [Vinz’s recording](https://x.com/hivinz_/status/2093297980749283354/video/1)

## Three views for the first release

| View | Proposed behavior |
| --- | --- |
| **Compact notch** | At rest, show the ordinary notch silhouette. While focusing, show remaining time as `mm:ss`, the active task title and a blue line that shortens toward zero. A paused timer freezes and displays a pause symbol. During a break, the label reads **Break**. Truncate long titles here and show the full title in the planner. |
| **Expanded notch** | Hover or click to open. Show today's open tasks, with the current task visible even if it belongs to another date. Each row has a completion circle, title, optional note and a separate Play/Pause control. Scroll the list when it grows. **Add a task** opens the planner with the title field focused. The expand button opens the planner for browsing. |
| **Task planner** | Anchor it beneath the notch panel. Selecting a date shows that day's tasks. **Today** returns to the current date. **Unscheduled** holds tasks without a date. A new task inherits the selected date or the unscheduled state. Require a nonblank title. Support editing notes, assigning or clearing a date, changing the duration, completing, reopening and deleting a task. Show each task's accumulated focus time in its details. |

Treat the notch and planner as one interaction area. Crossing the gap keeps both open. Leaving a hover-opened notch collapses it after a short delay. An open planner stays put while typing. Escape closes the current layer, retaining an unfinished draft. Glancing at the notch keeps keyboard focus in the app where the user is working.

## Timer and tracking rules

Starting a different task closes the previous Pomodoro and preserves the time already worked. Pausing and resuming the same task preserves its countdown. Finishing a full Pomodoro starts the break automatically. The agreed break lengths are five minutes and fifteen minutes after every fourth completed interval. The next focus interval starts manually.

| Event | Result |
| --- | --- |
| Press Play or Pause on the current task | Play starts the task's configured duration, initially **25:00**. Pause freezes the countdown and saves the time earned. Play on that same task resumes the remainder if no other task has started. Only one clock runs. Duration edits apply to the next fresh interval. |
| Start a different task | Starting B closes A's running or paused interval and keeps its worked time. B starts at its own full duration. Returning to A later starts a fresh interval at A's configured duration. Incomplete intervals add focus time only. Browsing or editing another task leaves the current timer alone. |
| Finish a task early | The completion circle marks the task done and ends its interval. Keep the minutes earned. An unfinished interval earns zero completed Pomodoros. Reopening the task restores its history. |
| Focus reaches zero | Save one completed Pomodoro, leave the task open and immediately start the break countdown in the notch. Use **5:00** after a regular interval and **15:00** after every fourth completed interval. |
| Break ends | Return to idle and wait for the user to start the next focus interval. **End break** returns to idle early. Pressing Play on a task during a break starts a fresh focus interval immediately. Break time earns zero task minutes. |
| Lock, sleep or quit | Pause focus and save the remaining time. Unlocking, waking or reopening presents **Resume**. A running break may expire while away. After an unexpected exit, restore focus paused at the last saved checkpoint. |

**An accounting example.** Starting with zero completed intervals, work eight minutes on A, switch to B for four minutes, then switch back to A. The planner already shows **8 minutes on A** and **4 minutes on B**. The notch starts A at **25:00**. Finish that fresh interval and the notch immediately shows **Break**. The planner now shows **33 minutes on A**, **4 minutes on B**, and **one completed Pomodoro**. Both tasks remain open. When the break ends, the clock returns to idle and the day's focus total is still **37 minutes**.

**Journey Streak.** Give each cell one local calendar day. Match the 4 × 12 layout in the stills, with the oldest day at the upper left and today at the lower right. Shade for zero, under 25, 25–49, or 50+ focused minutes. Hover or keyboard focus reveals the date, exact total and completed intervals. A day with at least one completed interval extends the streak. Keep yesterday's streak visible while today is still in progress. Split actual minutes at local midnight and credit a completed interval to the day it finishes.

**Local history.** Store tasks, intervals and their worked segments on the Mac. Compute task totals and grid cells from the same segments. Renaming, rescheduling or deleting a task preserves the time already recorded on the day it was worked. Use a saved deadline for an active clock and checkpoint earnings for recovery. Handle expiry once even if the panel opens at the same moment.

## Development sequence and acceptance

**Verified on the MacBook, version 0.1.1.** Felipe confirmed that hovering just below the camera opens the task panel without clicking, and moving the pointer away collapses it.

| Milestone | Deliverable and acceptance check |
| --- | --- |
| **1. Validate the notch on this MacBook** | Build a small native SwiftUI/AppKit panel with sample rows. Test compact → expanded → planner at the actual display scale. The camera clears the timer and title, adjacent menu items remain clickable, and hovering while typing in another app leaves the insertion point there. Verify Reduce Motion and keyboard access. |
| **2. Implement the focus clock and local history** | Run the 37-minute example with a controllable clock. Pause A after eight minutes and resume it at 17:00. Repeat with a switch to B while A is paused and verify A starts at 25:00 on return. Exercise rapid double-clicks, sleep, quit/relaunch and an interval ending at midnight. Both views show the same timer and each completed interval is saved once. |
| **3. Connect the planner** | Reproduce the clip on the MacBook. Create a task with notes, change 25:00 to 30:00, press Play, move away and reopen the notch. The active row and compact title identify that same task. Assign an unscheduled task to tomorrow and verify both lists update. |
| **4. Finish breaks, streaks and Mac testing** | Verify focus expiry automatically starts exactly one break, including the long break on the fourth completion. Verify an early task completion preserves partial time and goes idle, and break expiry waits for Play. Compare the grid against known session history. Check Spaces, full-screen apps, a disconnected monitor and lid-closed use. A menu-bar entry opens the same tasks and timer on an external display. |

The current setup has a built-in display with a camera inset and two external displays. Use the display's reported safe area to position the controls. Our proposed full-screen default is to keep the overlay quiet and make the timer reachable through the menu bar when revealed. Actual placement and focus handling are the first hardware acceptance checks. [Apple’s screen safe areas](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets) · [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
