/**
 * @file src/platform/macos/misc.h
 * @brief Miscellaneous declarations for macOS platform.
 */
#pragma once

// standard includes
#include <vector>

// platform includes
#include <CoreGraphics/CoreGraphics.h>

namespace platf {
  void prepare_app_bundle_environment();
  bool is_screen_capture_allowed();
  void arm_display_wake_watchdog();
  bool isolate_virtual_display(CGDirectDisplayID virtual_display_id);
  void restore_virtual_display_isolation();
  void focus_virtual_display_workspace(CGDirectDisplayID virtual_display_id);
  void log_private_display_control_availability();
  bool sleep_physical_displays();
  bool wake_physical_displays();
}

namespace dyn {
  typedef void (*apiproc)();

  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict = true);
  void *handle(const std::vector<const char *> &libs);

}  // namespace dyn
