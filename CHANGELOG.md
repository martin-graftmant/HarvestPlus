# Changelog

All notable changes to HarvestPlus will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] - 2026-06-16

### Fixed

- **Automatic updates could not install.** The app is sandboxed, and Sparkle
  needs two extra entitlements to hand a downloaded update to its installer.
  Without them, updates downloaded but failed with "an error occurred while
  running the updater." Added the required entitlements so updates install
  cleanly. Because earlier builds were missing them, this version must be
  installed manually once; after that, updates apply automatically again.

## [1.0.1] - 2026-06-07

### Fixed

- **Overtime indicator overflowed the progress bar.** When you logged past
  your daily target, the overtime marker extended past the end of the bar. It
  now stays within the bar, shown as a red cap on the right end.
- **Newly added Harvest projects were missing from the meeting entry picker.**
  The project list now refreshes each time you log a meeting, so projects added
  in Harvest show up right away instead of only after an app restart.

## [1.0.0] - 2026-06-01

Initial public release.

### Added

- Menu-bar popover showing today's entries and the running timer at a glance.
- Dashboards: daily, weekly, monthly, and yearly views with summary cards for
  hours logged, target, overtime, and break usage. Always current, no reload.
- PDF and CSV report export for any range, in two clicks.
- Overtime calculator: per-weekday hour targets, a lunch window, and your own
  custom non-working days, rolled up into real overtime and undertime.
- Smart banners (optional): a reminder when a timer is left running, when you
  go idle, or when a calendar meeting ends without a logged entry, plus
  end-of-day and end-of-week summaries.
- macOS Calendar integration: meetings appear alongside your time entries, and
  any meeting can be logged as a Harvest entry in two clicks.
- Silent automatic updates via [Sparkle](https://sparkle-project.org).
- In-app feedback form (Settings, Feedback).
