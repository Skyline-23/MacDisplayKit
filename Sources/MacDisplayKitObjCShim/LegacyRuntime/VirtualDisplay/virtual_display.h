#pragma once

#include <cstdint>
#include <string>

namespace VDISPLAY {
  struct chromaticity_point_t {
    double x;
    double y;
  };

  struct color_profile_t {
    chromaticity_point_t red;
    chromaticity_point_t green;
    chromaticity_point_t blue;
    chromaticity_point_t white;
    bool display_p3;
    bool hdr_capable;
  };

  enum class DRIVER_STATUS {
    UNKNOWN = 1,
    OK = 0,
    FAILED = -1,
  };

  DRIVER_STATUS openVDisplayDevice();
  void closeVDisplayDevice();
  color_profile_t probeHostDisplayColorProfile(bool hdr_enabled, int client_display_gamut = 0, int client_display_transfer = 0);

  std::string createVirtualDisplay(
    const char *client_uid,
    const char *client_name,
    std::uint32_t logical_width,
    std::uint32_t logical_height,
    std::uint32_t fps_millihz,
    int scale_factor,
    bool hi_dpi,
    bool hdr_enabled,
    int client_display_gamut,
    int client_display_transfer
  );

  bool updateVirtualDisplayMode(
    const std::string &client_uid,
    std::uint32_t logical_width,
    std::uint32_t logical_height,
    std::uint32_t fps_millihz,
    int client_display_transfer
  );

  bool removeVirtualDisplay(const std::string &client_uid);
}
