#pragma once

#include <array>
#include <iostream>
#include <utility>
#include <vector>

namespace video {
  enum class client_display_gamut_e : int {
    unknown = 0,
    srgb = 1,
    display_p3 = 2,
    rec2020 = 3,
  };

  enum class client_display_transfer_e : int {
    unknown = 0,
    sdr = 1,
    pq = 2,
    hlg = 3,
  };
}

#define BOOST_LOG(level) std::clog
