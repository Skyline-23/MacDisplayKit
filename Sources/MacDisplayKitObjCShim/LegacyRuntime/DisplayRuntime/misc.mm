/**
 * @file src/platform/macos/misc.mm
 * @brief Miscellaneous definitions for macOS platform.
 */

// Required for IPV6_PKTINFO with Darwin headers
#ifndef __APPLE_USE_RFC_3542  // NOLINT(bugprone-reserved-identifier)
  #define __APPLE_USE_RFC_3542 1
#endif

// standard includes
#include <fcntl.h>
#include <ifaddrs.h>

// platform includes
#include <AppKit/AppKit.h>
#include <ApplicationServices/ApplicationServices.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <net/if_dl.h>
#include <spawn.h>
#include <pwd.h>
#include <unistd.h>

extern char **environ;

// lib includes
#include <boost/asio/ip/address.hpp>
#include <boost/asio/ip/host_name.hpp>
#include <boost/process/v1.hpp>

// local includes
#include "misc.h"
#include "src/config.h"
#include "src/entry_handler.h"
#include "src/logging.h"
#include "src/platform/common.h"

using namespace std::literals;
namespace fs = std::filesystem;
namespace bp = boost::process::v1;

namespace platf {

// Even though the following two functions are available starting in macOS 10.15, they weren't
// actually in the Mac SDK until Xcode 12.2, the first to include the SDK for macOS 11
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 110000  // __MAC_11_0
  // If they're not in the SDK then we can use our own function definitions.
  // Need to use weak import so that this will link in macOS 10.14 and earlier
  extern "C" bool CGPreflightScreenCaptureAccess(void) __attribute__((weak_import));
#endif

  namespace {
    auto screen_capture_allowed = std::atomic<bool> {false};
    auto screen_capture_warning_logged = std::atomic<bool> {false};
    struct display_layout_entry_t {
      CGDirectDisplayID display_id;
      CGPoint origin;
      CGDirectDisplayID mirror_master;
    };

    std::mutex virtual_display_layout_mutex;
    std::vector<display_layout_entry_t> virtual_display_layout_snapshot;
    bool virtual_display_layout_active = false;
    bool private_display_set_active = false;
    int private_display_set_previous = 0;
    std::atomic<bool> accessibility_prompt_requested = false;
    std::once_flag private_display_control_log_once;
    constexpr int32_t kVirtualIsolationParkOriginX = -32768;
    constexpr int32_t kVirtualIsolationParkOriginY = 0;
    constexpr int32_t kVirtualIsolationParkSpacingY = 4096;

    struct private_display_control_api_t {
      void *handle = nullptr;
      dyn::apiproc cgx_current_display_set = nullptr;
      dyn::apiproc cgx_select_display_set = nullptr;
      dyn::apiproc cgx_set_display_set = nullptr;
      dyn::apiproc coredisplay_display_is_main = nullptr;
      dyn::apiproc ws_canonical_mirror_master_for_display_device = nullptr;
      dyn::apiproc ws_display_is_canonical_mirror_master = nullptr;
      dyn::apiproc cgx_vfb_select_online_state = nullptr;
    };

    dyn::apiproc load_private_symbol(void *handle, const char *symbol_name) {
      if (handle == nullptr || symbol_name == nullptr || symbol_name[0] == '\0') {
        return nullptr;
      }

      if (auto *symbol = reinterpret_cast<dyn::apiproc>(dlsym(handle, symbol_name)); symbol != nullptr) {
        return symbol;
      }

      if (symbol_name[0] == '_') {
        if (auto *symbol = reinterpret_cast<dyn::apiproc>(dlsym(handle, symbol_name + 1)); symbol != nullptr) {
          return symbol;
        }
      }

      std::string underscored_name = "_";
      underscored_name += symbol_name;
      return reinterpret_cast<dyn::apiproc>(dlsym(handle, underscored_name.c_str()));
    }

    private_display_control_api_t load_private_display_control_api() {
      private_display_control_api_t api;
      api.handle = dyn::handle({
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
      });
      if (!api.handle) {
        return api;
      }

      api.cgx_current_display_set = load_private_symbol(api.handle, "CGXCurrentDisplaySet");
      api.cgx_select_display_set = load_private_symbol(api.handle, "CGXSelectDisplaySet");
      api.cgx_set_display_set = load_private_symbol(api.handle, "CGXSetDisplaySet");
      api.coredisplay_display_is_main = load_private_symbol(api.handle, "CoreDisplay_Display_IsMain");
      api.ws_canonical_mirror_master_for_display_device = load_private_symbol(api.handle, "WSCanonicalMirrorMasterForDisplayDevice");
      api.ws_display_is_canonical_mirror_master = load_private_symbol(api.handle, "WSDisplayIsCanonicalMirrorMaster");
      api.cgx_vfb_select_online_state = load_private_symbol(api.handle, "CGXVFBSelectOnlineState");
      return api;
    }

    using cgx_current_display_set_t = int (*)();
    using cgx_select_display_set_t = int (*)(int);
    using cgx_set_display_set_t = int (*)(int);
    using cgx_vfb_select_online_state_t = int (*)(int);

    bool apply_private_virtual_display_set(int requested_set, bool include_vfb_online_state = false) {
      const auto api = load_private_display_control_api();
      if (!api.handle) {
        return false;
      }

      int previous_set = requested_set;
      if (api.cgx_current_display_set != nullptr) {
        previous_set = reinterpret_cast<cgx_current_display_set_t>(api.cgx_current_display_set)();
      }

      bool any_call_succeeded = false;
      if (api.cgx_select_display_set != nullptr) {
        const auto rc = reinterpret_cast<cgx_select_display_set_t>(api.cgx_select_display_set)(requested_set);
        BOOST_LOG(info) << "macOS private display set select requested="sv << requested_set << " previous="sv << previous_set << " rc="sv << rc;
        any_call_succeeded = true;
      } else if (api.cgx_set_display_set != nullptr) {
        const auto rc = reinterpret_cast<cgx_set_display_set_t>(api.cgx_set_display_set)(requested_set);
        BOOST_LOG(info) << "macOS private display set apply requested="sv << requested_set << " previous="sv << previous_set << " rc="sv << rc;
        any_call_succeeded = true;
      }

      if (include_vfb_online_state && api.cgx_vfb_select_online_state != nullptr) {
        const auto rc = reinterpret_cast<cgx_vfb_select_online_state_t>(api.cgx_vfb_select_online_state)(requested_set);
        BOOST_LOG(info) << "macOS private VFB online state requested="sv << requested_set << " rc="sv << rc;
        any_call_succeeded = true;
      }

      if (!any_call_succeeded) {
        return false;
      }

      if (requested_set != 0) {
        private_display_set_previous = previous_set;
        private_display_set_active = true;
      } else {
        private_display_set_active = false;
      }

      return true;
    }

    uint32_t refresh_active_display_ids(std::vector<CGDirectDisplayID> &display_ids) {
      uint32_t active_count = 0;
      if (CGGetActiveDisplayList(0, nullptr, &active_count) != kCGErrorSuccess || active_count == 0) {
        return 0;
      }

      display_ids.assign(active_count, kCGNullDirectDisplay);
      if (CGGetActiveDisplayList(active_count, display_ids.data(), &active_count) != kCGErrorSuccess) {
        display_ids.clear();
        return 0;
      }

      display_ids.resize(active_count);
      return active_count;
    }

    void open_accessibility_settings() {
      NSURL *settings_url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
      if (settings_url == nil) {
        return;
      }

      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSWorkspace sharedWorkspace] openURL:settings_url];
      });
    }

    bool refresh_screen_capture_permission_state() {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
      if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:((NSOperatingSystemVersion) {10, 15, 0})] &&
          CGPreflightScreenCaptureAccess != nullptr) {
        const bool allowed = CGPreflightScreenCaptureAccess();
        screen_capture_allowed = allowed;
        return allowed;
      }
#pragma clang diagnostic pop

      screen_capture_allowed = true;
      return true;
    }

  }  // namespace

  // Return whether screen capture is allowed for this process.
  bool is_screen_capture_allowed() {
    refresh_screen_capture_permission_state();
    return screen_capture_allowed;
  }

  void prepare_app_bundle_environment() {
    NSString *resource_path = [[NSBundle mainBundle] resourcePath];
    if (resource_path != nil && [resource_path length] > 0) {
      const char *resource_path_cstr = [resource_path fileSystemRepresentation];
      if (resource_path_cstr != nullptr) {
        chdir(resource_path_cstr);
      }
    }
  }

  std::unique_ptr<deinit_t> init() {
    if (!refresh_screen_capture_permission_state()) {
      if (!screen_capture_warning_logged.exchange(true)) {
        BOOST_LOG(warning) << "Screen capture permission is not granted yet."sv;
        BOOST_LOG(warning) << "Please enable Apollo in System Settings -> Privacy & Security -> Screen Recording."sv;
      }
    }

    prepare_app_bundle_environment();
    return std::make_unique<deinit_t>();
  }

  fs::path appdata() {
    const char *homedir;
    if ((homedir = getenv("HOME")) == nullptr) {
      homedir = getpwuid(geteuid())->pw_dir;
    }

    return fs::path {homedir} / "Library/Application Support/Apollo"sv;
  }

  using ifaddr_t = util::safe_ptr<ifaddrs, freeifaddrs>;

  ifaddr_t get_ifaddrs() {
    ifaddrs *p {nullptr};

    getifaddrs(&p);

    return ifaddr_t {p};
  }

  std::string from_sockaddr(const sockaddr *const ip_addr) {
    char data[INET6_ADDRSTRLEN] = {};

    auto family = ip_addr->sa_family;
    if (family == AF_INET6) {
      inet_ntop(AF_INET6, &((sockaddr_in6 *) ip_addr)->sin6_addr, data, INET6_ADDRSTRLEN);
    } else if (family == AF_INET) {
      inet_ntop(AF_INET, &((sockaddr_in *) ip_addr)->sin_addr, data, INET_ADDRSTRLEN);
    }

    return std::string {data};
  }

  std::pair<std::uint16_t, std::string> from_sockaddr_ex(const sockaddr *const ip_addr) {
    char data[INET6_ADDRSTRLEN] = {};

    auto family = ip_addr->sa_family;
    std::uint16_t port = 0;
    if (family == AF_INET6) {
      inet_ntop(AF_INET6, &((sockaddr_in6 *) ip_addr)->sin6_addr, data, INET6_ADDRSTRLEN);
      port = ((sockaddr_in6 *) ip_addr)->sin6_port;
    } else if (family == AF_INET) {
      inet_ntop(AF_INET, &((sockaddr_in *) ip_addr)->sin_addr, data, INET_ADDRSTRLEN);
      port = ((sockaddr_in *) ip_addr)->sin_port;
    }

    return {port, std::string {data}};
  }

  std::string get_mac_address(const std::string_view &address) {
    auto ifaddrs = get_ifaddrs();

    for (auto pos = ifaddrs.get(); pos != nullptr; pos = pos->ifa_next) {
      if (pos->ifa_addr && address == from_sockaddr(pos->ifa_addr)) {
        BOOST_LOG(verbose) << "Looking for MAC of "sv << pos->ifa_name;

        struct ifaddrs *ifap, *ifaptr;
        unsigned char *ptr;
        std::string mac_address;

        if (getifaddrs(&ifap) == 0) {
          for (ifaptr = ifap; ifaptr != nullptr; ifaptr = (ifaptr)->ifa_next) {
            if (!strcmp((ifaptr)->ifa_name, pos->ifa_name) && (((ifaptr)->ifa_addr)->sa_family == AF_LINK)) {
              ptr = (unsigned char *) LLADDR((struct sockaddr_dl *) (ifaptr)->ifa_addr);
              char buff[100];

              snprintf(buff, sizeof(buff), "%02x:%02x:%02x:%02x:%02x:%02x", *ptr, *(ptr + 1), *(ptr + 2), *(ptr + 3), *(ptr + 4), *(ptr + 5));
              mac_address = buff;
              break;
            }
          }

          freeifaddrs(ifap);

          if (ifaptr != nullptr) {
            BOOST_LOG(verbose) << "Found MAC of "sv << pos->ifa_name << ": "sv << mac_address;
            return mac_address;
          }
        }
      }
    }

    BOOST_LOG(warning) << "Unable to find MAC address for "sv << address;
    return "00:00:00:00:00:00"s;
  }

  // TODO: return actual IP
  std::string get_local_ip_for_gateway() {
    return "";
  }

  bp::child run_command(bool elevated, bool interactive, const std::string &cmd, boost::filesystem::path &working_dir, const bp::environment &env, FILE *file, std::error_code &ec, bp::group *group) {
    // clang-format off
    if (!group) {
      if (!file) {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > bp::null, bp::std_err > bp::null, bp::limit_handles, ec);
      }
      else {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > file, bp::std_err > file, bp::limit_handles, ec);
      }
    }
    else {
      if (!file) {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > bp::null, bp::std_err > bp::null, bp::limit_handles, ec, *group);
      }
      else {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > file, bp::std_err > file, bp::limit_handles, ec, *group);
      }
    }
    // clang-format on
  }

  /**
   * @brief Open a url in the default web browser.
   * @param url The url to open.
   */
  void open_url(const std::string &url) {
    boost::filesystem::path working_dir;
    std::string cmd = R"(open ")" + url + R"(")";

    boost::process::v1::environment _env = boost::this_process::environment();
    std::error_code ec;
    auto child = run_command(false, false, cmd, working_dir, _env, nullptr, ec, nullptr);
    if (ec) {
      BOOST_LOG(warning) << "Couldn't open url ["sv << url << "]: System: "sv << ec.message();
    } else {
      BOOST_LOG(info) << "Opened url ["sv << url << "]"sv;
      child.detach();
    }
  }

  void adjust_thread_priority(thread_priority_e priority) {
    // Unimplemented
  }

  void streaming_will_start() {
    // Nothing to do
  }

  void streaming_will_stop() {
    // Nothing to do
  }

  bool spawn_restart_process() {
    char executable[2048];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) < 0) {
      BOOST_LOG(fatal) << "NSGetExecutablePath() failed: "sv << errno;
      return false;
    }

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
      BOOST_LOG(fatal) << "posix_spawnattr_init() failed: "sv << errno;
      return false;
    }

    pid_t child_pid = 0;
    const int spawn_status = posix_spawn(&child_pid, executable, nullptr, &attr, lifetime::get_argv(), ::environ);
    posix_spawnattr_destroy(&attr);
    if (spawn_status != 0) {
      BOOST_LOG(fatal) << "posix_spawn() failed: "sv << spawn_status;
      return false;
    }

    BOOST_LOG(info) << "Spawned replacement Apollo process pid="sv << child_pid;
    return true;
  }

  void restart() {
    if (!spawn_restart_process()) {
      BOOST_LOG(error) << "Failed to spawn replacement Apollo process during restart."sv;
      return;
    }
    lifetime::exit_sunshine(0, true);
  }

  int set_env(const std::string &name, const std::string &value) {
    return setenv(name.c_str(), value.c_str(), 1);
  }

  int unset_env(const std::string &name) {
    return unsetenv(name.c_str());
  }

  bool request_process_group_exit(std::uintptr_t native_handle) {
    if (killpg((pid_t) native_handle, SIGTERM) == 0 || errno == ESRCH) {
      BOOST_LOG(debug) << "Successfully sent SIGTERM to process group: "sv << native_handle;
      return true;
    } else {
      BOOST_LOG(warning) << "Unable to send SIGTERM to process group ["sv << native_handle << "]: "sv << errno;
      return false;
    }
  }

  bool process_group_running(std::uintptr_t native_handle) {
    return waitpid(-((pid_t) native_handle), nullptr, WNOHANG) >= 0;
  }

  struct sockaddr_in to_sockaddr(boost::asio::ip::address_v4 address, uint16_t port) {
    struct sockaddr_in saddr_v4 = {};

    saddr_v4.sin_family = AF_INET;
    saddr_v4.sin_port = htons(port);

    auto addr_bytes = address.to_bytes();
    memcpy(&saddr_v4.sin_addr, addr_bytes.data(), sizeof(saddr_v4.sin_addr));

    return saddr_v4;
  }

  struct sockaddr_in6 to_sockaddr(boost::asio::ip::address_v6 address, uint16_t port) {
    struct sockaddr_in6 saddr_v6 = {};

    saddr_v6.sin6_family = AF_INET6;
    saddr_v6.sin6_port = htons(port);
    saddr_v6.sin6_scope_id = address.scope_id();

    auto addr_bytes = address.to_bytes();
    memcpy(&saddr_v6.sin6_addr, addr_bytes.data(), sizeof(saddr_v6.sin6_addr));

    return saddr_v6;
  }

  bool send_batch(batched_send_info_t &send_info) {
    // Fall back to unbatched send calls
    return false;
  }

  bool send(send_info_t &send_info) {
    auto sockfd = (int) send_info.native_socket;
    struct msghdr msg = {};

    // Convert the target address into a sockaddr
    struct sockaddr_in taddr_v4 = {};
    struct sockaddr_in6 taddr_v6 = {};
    if (send_info.target_address.is_v6()) {
      taddr_v6 = to_sockaddr(send_info.target_address.to_v6(), send_info.target_port);

      msg.msg_name = (struct sockaddr *) &taddr_v6;
      msg.msg_namelen = sizeof(taddr_v6);
    } else {
      taddr_v4 = to_sockaddr(send_info.target_address.to_v4(), send_info.target_port);

      msg.msg_name = (struct sockaddr *) &taddr_v4;
      msg.msg_namelen = sizeof(taddr_v4);
    }

    union {
      char buf[std::max(CMSG_SPACE(sizeof(struct in_pktinfo)), CMSG_SPACE(sizeof(struct in6_pktinfo)))];
      struct cmsghdr alignment;
    } cmbuf {};

    socklen_t cmbuflen = 0;

    msg.msg_control = cmbuf.buf;
    msg.msg_controllen = sizeof(cmbuf.buf);

    auto pktinfo_cm = CMSG_FIRSTHDR(&msg);
    if (send_info.source_address.is_v6()) {
      struct in6_pktinfo pktInfo {};

      struct sockaddr_in6 saddr_v6 = to_sockaddr(send_info.source_address.to_v6(), 0);
      pktInfo.ipi6_addr = saddr_v6.sin6_addr;
      pktInfo.ipi6_ifindex = 0;

      cmbuflen += CMSG_SPACE(sizeof(pktInfo));

      pktinfo_cm->cmsg_level = IPPROTO_IPV6;
      pktinfo_cm->cmsg_type = IPV6_PKTINFO;
      pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
      memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
    } else {
      struct in_pktinfo pktInfo {};

      struct sockaddr_in saddr_v4 = to_sockaddr(send_info.source_address.to_v4(), 0);
      pktInfo.ipi_spec_dst = saddr_v4.sin_addr;
      pktInfo.ipi_ifindex = 0;

      cmbuflen += CMSG_SPACE(sizeof(pktInfo));

      pktinfo_cm->cmsg_level = IPPROTO_IP;
      pktinfo_cm->cmsg_type = IP_PKTINFO;
      pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
      memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
    }

    struct iovec iovs[2] = {};
    int iovlen = 0;
    if (send_info.header) {
      iovs[iovlen].iov_base = (void *) send_info.header;
      iovs[iovlen].iov_len = send_info.header_size;
      iovlen++;
    }
    iovs[iovlen].iov_base = (void *) send_info.payload;
    iovs[iovlen].iov_len = send_info.payload_size;
    iovlen++;

    msg.msg_iov = iovs;
    msg.msg_iovlen = iovlen;

    msg.msg_controllen = cmbuflen;

    auto bytes_sent = sendmsg(sockfd, &msg, 0);

    // If there's no send buffer space, wait for some to be available
    while (bytes_sent < 0 && errno == EAGAIN) {
      struct pollfd pfd;

      pfd.fd = sockfd;
      pfd.events = POLLOUT;

      if (poll(&pfd, 1, -1) != 1) {
        BOOST_LOG(warning) << "poll() failed: "sv << errno;
        break;
      }

      // Try to send again
      bytes_sent = sendmsg(sockfd, &msg, 0);
    }

    if (bytes_sent < 0) {
      BOOST_LOG(warning) << "sendmsg() failed: "sv << errno;
      return false;
    }

    return true;
  }

  // We can't track QoS state separately for each destination on this OS,
  // so we keep a ref count to only disable QoS options when all clients
  // are disconnected.
  static std::atomic<int> qos_ref_count = 0;

  class qos_t: public deinit_t {
  public:
    qos_t(int sockfd, std::vector<std::tuple<int, int, int>> options):
        sockfd(sockfd),
        options(options) {
      qos_ref_count++;
    }

    virtual ~qos_t() {
      if (--qos_ref_count == 0) {
        for (const auto &tuple : options) {
          auto reset_val = std::get<2>(tuple);
          if (setsockopt(sockfd, std::get<0>(tuple), std::get<1>(tuple), &reset_val, sizeof(reset_val)) < 0) {
            BOOST_LOG(warning) << "Failed to reset option: "sv << errno;
          }
        }
      }
    }

  private:
    int sockfd;
    std::vector<std::tuple<int, int, int>> options;
  };

  /**
   * @brief Enables QoS on the given socket for traffic to the specified destination.
   * @param native_socket The native socket handle.
   * @param address The destination address for traffic sent on this socket.
   * @param port The destination port for traffic sent on this socket.
   * @param data_type The type of traffic sent on this socket.
   * @param dscp_tagging Specifies whether to enable DSCP tagging on outgoing traffic.
   */
  std::unique_ptr<deinit_t> enable_socket_qos(uintptr_t native_socket, boost::asio::ip::address &address, uint16_t port, qos_data_type_e data_type, bool dscp_tagging) {
    int sockfd = (int) native_socket;
    std::vector<std::tuple<int, int, int>> reset_options;

    // We can use SO_NET_SERVICE_TYPE to set link-layer prioritization without DSCP tagging
    int service_type = 0;
    switch (data_type) {
      case qos_data_type_e::video:
        service_type = NET_SERVICE_TYPE_VI;
        break;
      case qos_data_type_e::audio:
        service_type = NET_SERVICE_TYPE_VO;
        break;
      default:
        BOOST_LOG(error) << "Unknown traffic type: "sv << (int) data_type;
        break;
    }

    if (service_type) {
      if (setsockopt(sockfd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service_type, sizeof(service_type)) == 0) {
        // Reset SO_NET_SERVICE_TYPE to best-effort when QoS is disabled
        reset_options.emplace_back(std::make_tuple(SOL_SOCKET, SO_NET_SERVICE_TYPE, NET_SERVICE_TYPE_BE));
      } else {
        BOOST_LOG(error) << "Failed to set SO_NET_SERVICE_TYPE: "sv << errno;
      }
    }

    if (dscp_tagging) {
      int level;
      int option;
      if (address.is_v6()) {
        level = IPPROTO_IPV6;
        option = IPV6_TCLASS;
      } else {
        level = IPPROTO_IP;
        option = IP_TOS;
      }

      // The specific DSCP values here are chosen to be consistent with Windows,
      // except that we use CS6 instead of CS7 for audio traffic.
      int dscp = 0;
      switch (data_type) {
        case qos_data_type_e::video:
          dscp = 40;
          break;
        case qos_data_type_e::audio:
          dscp = 48;
          break;
        default:
          BOOST_LOG(error) << "Unknown traffic type: "sv << (int) data_type;
          break;
      }

      if (dscp) {
        // Shift to put the DSCP value in the correct position in the TOS field
        dscp <<= 2;

        if (setsockopt(sockfd, level, option, &dscp, sizeof(dscp)) == 0) {
          // Reset TOS to -1 when QoS is disabled
          reset_options.emplace_back(std::make_tuple(level, option, -1));
        } else {
          BOOST_LOG(error) << "Failed to set TOS/TCLASS: "sv << errno;
        }
      }
    }

    return std::make_unique<qos_t>(sockfd, reset_options);
  }

  std::string get_host_name() {
    try {
      return boost::asio::ip::host_name();
    } catch (boost::system::system_error &err) {
      BOOST_LOG(error) << "Failed to get hostname: "sv << err.what();
      return "Sunshine"s;
    }
  }

  class macos_high_precision_timer: public high_precision_timer {
  public:
    void sleep_for(const std::chrono::nanoseconds &duration) override {
      std::this_thread::sleep_for(duration);
    }

    operator bool() override {
      return true;
    }
  };

  std::unique_ptr<high_precision_timer> create_high_precision_timer() {
    return std::make_unique<macos_high_precision_timer>();
  }

  std::string
  get_clipboard() {
    // Placeholder
    return "";
  }

  bool
  set_clipboard(const std::string& content) {
    // Placeholder
    return false;
  }

  void arm_display_wake_watchdog() {
    boost::filesystem::path working_dir;
    boost::process::v1::environment env = boost::this_process::environment();
    std::error_code ec;
    const auto pid = static_cast<long>(getpid());
    std::string cmd = "/bin/sh -c 'while kill -0 " + std::to_string(pid) + " 2>/dev/null; do sleep 1; done; /usr/bin/caffeinate -u -t 1 >/dev/null 2>&1'";
    auto child = run_command(false, false, cmd, working_dir, env, nullptr, ec, nullptr);
    if (ec) {
      BOOST_LOG(warning) << "Failed to arm macOS display wake watchdog: "sv << ec.message();
      return;
    }

    child.detach();
    BOOST_LOG(info) << "Armed macOS display wake watchdog for pid="sv << pid;
  }

  bool isolate_virtual_display(CGDirectDisplayID virtual_display_id) {
    std::call_once(private_display_control_log_once, []() {
      log_private_display_control_availability();
    });
    std::lock_guard lock(virtual_display_layout_mutex);
    if (virtual_display_layout_active) {
      return true;
    }

    std::vector<CGDirectDisplayID> display_ids;
    auto display_count = refresh_active_display_ids(display_ids);
    if (display_count == 0) {
      BOOST_LOG(warning) << "Failed to enumerate active macOS displays for virtual layout isolation"sv;
      return false;
    }

    bool found_virtual_display = false;
    virtual_display_layout_snapshot.clear();
    virtual_display_layout_snapshot.reserve(display_count);
    for (uint32_t index = 0; index < display_count; ++index) {
      const auto display_id = display_ids[index];
      const auto bounds = CGDisplayBounds(display_id);
      virtual_display_layout_snapshot.push_back({
        display_id,
        bounds.origin,
        CGDisplayMirrorsDisplay(display_id)
      });
      found_virtual_display = found_virtual_display || display_id == virtual_display_id;
    }

    if (!found_virtual_display) {
      BOOST_LOG(warning) << "Virtual display "sv << virtual_display_id << " was not active during layout isolation"sv;
      virtual_display_layout_snapshot.clear();
      return false;
    }

    if (config::video.isolated_virtual_display_option) {
      BOOST_LOG(info) << "macOS isolated_virtual_display_option enabled, but skipping unstable private display set selection and using layout isolation only"sv;
    }

    CGDisplayConfigRef config = nullptr;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || config == nullptr) {
      BOOST_LOG(warning) << "Failed to begin macOS display configuration for virtual layout isolation"sv;
      if (private_display_set_active) {
        apply_private_virtual_display_set(0);
      }
      virtual_display_layout_snapshot.clear();
      return false;
    }

    bool configuration_ok = true;
    configuration_ok = configuration_ok && (CGConfigureDisplayMirrorOfDisplay(config, virtual_display_id, kCGNullDirectDisplay) == kCGErrorSuccess);
    configuration_ok = configuration_ok && (CGConfigureDisplayOrigin(config, virtual_display_id, 0, 0) == kCGErrorSuccess);

    int32_t parked_display_index = 0;
    for (const auto &entry : virtual_display_layout_snapshot) {
      if (entry.display_id == virtual_display_id) {
        continue;
      }

      configuration_ok = configuration_ok &&
                         (CGConfigureDisplayMirrorOfDisplay(config, entry.display_id, kCGNullDirectDisplay) == kCGErrorSuccess);
      configuration_ok = configuration_ok &&
                         (CGConfigureDisplayOrigin(
                           config,
                           entry.display_id,
                           kVirtualIsolationParkOriginX,
                           kVirtualIsolationParkOriginY + (parked_display_index++ * kVirtualIsolationParkSpacingY)
                         ) == kCGErrorSuccess);
    }

    if (!configuration_ok || CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
      CGCancelDisplayConfiguration(config);
      BOOST_LOG(warning) << "Failed to isolate macOS virtual display layout"sv;
      if (private_display_set_active) {
        apply_private_virtual_display_set(0);
      }
      virtual_display_layout_snapshot.clear();
      return false;
    }

    virtual_display_layout_active = true;
    BOOST_LOG(info) << "Isolated macOS virtual display layout around display "sv << virtual_display_id;
    return true;
  }

  void log_private_display_control_availability() {
    const auto api = load_private_display_control_api();
    if (!api.handle) {
      BOOST_LOG(warning) << "CoreDisplay private framework was not available for macOS display isolation probing"sv;
      return;
    }

    BOOST_LOG(info) << "macOS private display control candidates: "
                    << "CGXCurrentDisplaySet="sv << (api.cgx_current_display_set ? "yes"sv : "no"sv)
                    << " CGXSelectDisplaySet="sv << (api.cgx_select_display_set ? "yes"sv : "no"sv)
                    << " CGXSetDisplaySet="sv << (api.cgx_set_display_set ? "yes"sv : "no"sv)
                    << " CoreDisplay_Display_IsMain="sv << (api.coredisplay_display_is_main ? "yes"sv : "no"sv)
                    << " WSCanonicalMirrorMasterForDisplayDevice="sv << (api.ws_canonical_mirror_master_for_display_device ? "yes"sv : "no"sv)
                    << " WSDisplayIsCanonicalMirrorMaster="sv << (api.ws_display_is_canonical_mirror_master ? "yes"sv : "no"sv)
                    << " CGXVFBSelectOnlineState="sv << (api.cgx_vfb_select_online_state ? "yes"sv : "no"sv);
  }

  void restore_virtual_display_isolation() {
    std::lock_guard lock(virtual_display_layout_mutex);
    if ((!virtual_display_layout_active || virtual_display_layout_snapshot.empty()) && !private_display_set_active) {
      return;
    }

    if (private_display_set_active) {
      const auto requested_restore_set = private_display_set_previous;
      apply_private_virtual_display_set(requested_restore_set);
      BOOST_LOG(info) << "Restored macOS private display set to "sv << requested_restore_set;
    }

    if (!virtual_display_layout_active || virtual_display_layout_snapshot.empty()) {
      return;
    }

    CGDisplayConfigRef config = nullptr;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || config == nullptr) {
      BOOST_LOG(warning) << "Failed to begin macOS display configuration for layout restore"sv;
      return;
    }

    bool configuration_ok = true;
    for (const auto &entry : virtual_display_layout_snapshot) {
      configuration_ok = configuration_ok &&
                         (CGConfigureDisplayMirrorOfDisplay(config, entry.display_id, entry.mirror_master) == kCGErrorSuccess);
      configuration_ok = configuration_ok &&
                         (CGConfigureDisplayOrigin(
                           config,
                           entry.display_id,
                           static_cast<int32_t>(entry.origin.x),
                           static_cast<int32_t>(entry.origin.y)
                         ) == kCGErrorSuccess);
    }

    if (!configuration_ok || CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
      CGCancelDisplayConfiguration(config);
      BOOST_LOG(warning) << "Failed to restore macOS display layout after virtual session"sv;
      return;
    }

    virtual_display_layout_snapshot.clear();
    virtual_display_layout_active = false;
    BOOST_LOG(info) << "Restored macOS display layout after virtual session"sv;
  }

  void focus_virtual_display_workspace(CGDirectDisplayID virtual_display_id) {
    const auto bounds = CGDisplayBounds(virtual_display_id);
    if (CGRectIsEmpty(bounds)) {
      BOOST_LOG(warning) << "Unable to focus macOS virtual display "sv << virtual_display_id << " because its bounds were empty"sv;
      return;
    }

    const CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    CGDisplayMoveCursorToPoint(virtual_display_id, center);
    CGWarpMouseCursorPosition(center);

    const auto trusted = AXIsProcessTrusted();
    if (!trusted) {
      if (!accessibility_prompt_requested.exchange(true)) {
        CFTypeRef keys[] = {kAXTrustedCheckOptionPrompt};
        CFTypeRef values[] = {kCFBooleanTrue};
        CFDictionaryRef options = CFDictionaryCreate(
          kCFAllocatorDefault,
          keys,
          values,
          1,
          &kCFCopyStringDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks
        );
        if (options != nullptr) {
          AXIsProcessTrustedWithOptions(options);
          CFRelease(options);
        }
        open_accessibility_settings();
      }
      BOOST_LOG(warning) << "Skipping macOS window migration to virtual display because Accessibility permission is not granted"sv;
      return;
    }

    const CFArrayRef window_info = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (window_info == nullptr) {
      BOOST_LOG(warning) << "Unable to enumerate macOS windows for virtual display focus"sv;
      return;
    }

    const auto target_origin = CGPointMake(bounds.origin.x + 80.0, bounds.origin.y + 80.0);
    const auto entry_count = CFArrayGetCount(window_info);
    CFIndex moved_windows = 0;
    for (CFIndex index = 0; index < entry_count; ++index) {
      const auto entry = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(window_info, index));
      if (entry == nullptr) {
        continue;
      }

      const auto owner_name = static_cast<CFStringRef>(CFDictionaryGetValue(entry, kCGWindowOwnerName));
      if (owner_name != nullptr) {
        if (CFStringCompare(owner_name, CFSTR("Window Server"), 0) == kCFCompareEqualTo ||
            CFStringCompare(owner_name, CFSTR("Dock"), 0) == kCFCompareEqualTo) {
          continue;
        }
      }

      const auto pid_number = static_cast<CFNumberRef>(CFDictionaryGetValue(entry, kCGWindowOwnerPID));
      if (pid_number == nullptr) {
        continue;
      }

      pid_t pid = 0;
      if (!CFNumberGetValue(pid_number, kCFNumberIntType, &pid) || pid <= 0 || pid == getpid()) {
        continue;
      }

      const auto app = AXUIElementCreateApplication(pid);
      if (app == nullptr) {
        continue;
      }

      CFArrayRef windows = nullptr;
      if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, reinterpret_cast<CFTypeRef *>(&windows)) != kAXErrorSuccess || windows == nullptr) {
        CFRelease(app);
        continue;
      }

      const auto window_count = CFArrayGetCount(windows);
      for (CFIndex window_index = 0; window_index < window_count; ++window_index) {
        const auto window = static_cast<AXUIElementRef>(CFArrayGetValueAtIndex(windows, window_index));
        if (window == nullptr) {
          continue;
        }

        auto position = AXValueCreate(static_cast<AXValueType>(kAXValueCGPointType), &target_origin);
        if (position != nullptr) {
          if (AXUIElementSetAttributeValue(window, kAXPositionAttribute, position) == kAXErrorSuccess) {
            ++moved_windows;
          }
          CFRelease(position);
        }
      }

      CFRelease(windows);
      CFRelease(app);
    }

    CFRelease(window_info);
    BOOST_LOG(info) << "Focused macOS virtual display workspace around display "sv << virtual_display_id << " moved_windows="sv << moved_windows;
  }

  bool sleep_physical_displays() {
    boost::filesystem::path working_dir;
    boost::process::v1::environment env = boost::this_process::environment();
    std::error_code ec;
    auto child = run_command(false, false, "/usr/bin/pmset displaysleepnow", working_dir, env, nullptr, ec, nullptr);
    if (ec) {
      BOOST_LOG(warning) << "Failed to sleep physical displays: "sv << ec.message();
      return false;
    }

    child.wait();
    if (child.exit_code() != 0) {
      BOOST_LOG(warning) << "pmset displaysleepnow exited with code "sv << child.exit_code();
      return false;
    }

    arm_display_wake_watchdog();
    BOOST_LOG(info) << "Requested macOS physical displays to sleep"sv;
    return true;
  }

  bool wake_physical_displays() {
    boost::filesystem::path working_dir;
    boost::process::v1::environment env = boost::this_process::environment();
    std::error_code ec;
    auto child = run_command(false, false, "/usr/bin/caffeinate -u -t 1", working_dir, env, nullptr, ec, nullptr);
    if (ec) {
      BOOST_LOG(warning) << "Failed to wake physical displays: "sv << ec.message();
      return false;
    }

    child.wait();
    if (child.exit_code() != 0) {
      BOOST_LOG(warning) << "caffeinate wake request exited with code "sv << child.exit_code();
      return false;
    }

    BOOST_LOG(info) << "Requested macOS physical displays to wake"sv;
    return true;
  }
}  // namespace platf

namespace dyn {
  void *handle(const std::vector<const char *> &libs) {
    void *handle;

    for (auto lib : libs) {
      handle = dlopen(lib, RTLD_LAZY | RTLD_LOCAL);
      if (handle) {
        return handle;
      }
    }

    std::stringstream ss;
    ss << "Couldn't find any of the following libraries: ["sv << libs.front();
    std::for_each(std::begin(libs) + 1, std::end(libs), [&](auto lib) {
      ss << ", "sv << lib;
    });

    ss << ']';

    BOOST_LOG(error) << ss.str();

    return nullptr;
  }

  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict) {
    int err = 0;
    for (auto &func : funcs) {
      TUPLE_2D_REF(fn, name, func);

      *fn = (void (*)()) dlsym(handle, name);

      if (!*fn && strict) {
        BOOST_LOG(error) << "Couldn't find function: "sv << name;

        err = -1;
      }
    }

    return err;
  }
}  // namespace dyn
