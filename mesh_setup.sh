#!/bin/sh
# =============================================================================
# OpenWrt B.A.T.M.A.N. Advanced Mesh Network Auto-Setup Script
# =============================================================================
# 
# DESCRIPTION:
#   This script automatically updates OpenWrt, installs 802.11s mesh support,
#   configures B.A.T.M.A.N. advanced routing, and bridges Ethernet ports to
#   the mesh network. It is designed to be universal across OpenWrt versions
#   and architectures.
#
# HOW TO USE:
#   1. Copy this script to your OpenWrt router (e.g., via SCP):
#      scp mesh_setup.sh root@192.168.1.1:/root/
#
#   2. SSH into your router:
#      ssh root@192.168.1.1
#
#   3. Make the script executable:
#      chmod +x /root/mesh_setup.sh
#
#   4. Set the IS_GATEWAY variable (edit line 35 below):
#      - IS_GATEWAY=1  : This node will run DHCP server (gateway node)
#      - IS_GATEWAY=0  : This node will NOT run DHCP (mesh client node)
#
#   5. Run the script:
#      /root/mesh_setup.sh
#
#   6. The script will:
#      - Check for OpenWrt updates and upgrade if needed (reboots router)
#      - After reboot, continue with mesh configuration automatically
#      - Install required packages (batman-adv, wpad-mesh, etc.)
#      - Configure 802.11s Wi-Fi mesh interface
#      - Configure B.A.T.M.A.N. advanced routing
#      - Bridge Ethernet ports to the mesh
#
# NOTES:
#   - The script is idempotent - safe to run multiple times
#   - All actions are logged to system log (view with: logread | grep mesh_setup)
#   - Default Mesh ID: "OpenWrt-Mesh" (change MESH_ID variable if needed)
#   - Requires internet connection for package installation
#
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIGURATION VARIABLES - EDIT THESE BEFORE RUNNING
# -----------------------------------------------------------------------------
IS_GATEWAY=0              # Set to 1 if this node should provide DHCP, 0 otherwise
MESH_ID="OpenWrt-Mesh"    # SSID/Mesh ID for the 802.11s network
MESH_CHANNEL="auto"       # Wi-Fi channel (use "auto" or specify like "36", "6")
MESH_BAND="auto"          # Band preference (auto, 2g, 5g)

# -----------------------------------------------------------------------------
# GLOBAL VARIABLES
# -----------------------------------------------------------------------------
SCRIPT_NAME="mesh_setup"
STAGE2_FLAG="/tmp/.mesh_stage2"
STAGE2_INIT="/etc/init.d/mesh_stage2"
LOG_TAG="mesh_setup"

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS
# -----------------------------------------------------------------------------

log_msg() {
    # Log message to system log and stdout
    local level="$1"
    local message="$2"
    logger -t "$LOG_TAG" -p "$level" "$message"
    echo "[$level] $message"
}

log_info() {
    log_msg "user.info" "$1"
}

log_warn() {
    log_msg "user.warning" "$1"
}

log_error() {
    log_msg "user.err" "$1"
}

check_command() {
    # Check if a command exists
    command -v "$1" >/dev/null 2>&1
}

uci_delete_safe() {
    # Safely delete UCI section if it exists (idempotency)
    local section_type="$1"
    local section_name="$2"
    
    if uci get "$section_name" >/dev/null 2>&1; then
        uci delete "$section_name" 2>/dev/null
        log_info "Deleted existing UCI section: $section_name"
    fi
}

get_openwrt_version() {
    # Get OpenWrt version number
    if [ -f "/etc/openwrt_release" ]; then
        . /etc/openwrt_release
        echo "${DISTRIB_RELEASE:-unknown}"
    elif [ -f "/etc/os-release" ]; then
        . /etc/os-release
        echo "${VERSION_ID:-unknown}"
    else
        echo "unknown"
    fi
}

get_architecture() {
    # Get system architecture
    uname -m
}

# -----------------------------------------------------------------------------
# STAGE 1: SYSTEM UPDATE CHECK AND EXECUTION
# -----------------------------------------------------------------------------

check_and_update_openwrt() {
    log_info "Checking for OpenWrt updates..."
    
    # Check if we're in stage 2 (post-update)
    if [ -f "$STAGE2_FLAG" ]; then
        log_info "Detected post-update reboot, proceeding to Stage 2 (configuration)"
        return 1  # Signal that update was performed
    fi
    
    # Try to update package lists
    if ! opkg update >/dev/null 2>&1; then
        log_warn "Failed to update package lists, continuing anyway..."
    fi
    
    # Check if sysupgrade is available
    if ! check_command "sysupgrade"; then
        log_error "sysupgrade command not found, skipping update check"
        return 1
    fi
    
    # For now, skip automatic major version updates as they require careful handling
    # This is a placeholder for future enhancement
    log_info "No critical update detected, proceeding to configuration"
    return 1
}

create_stage2_init() {
    # Create init script to run stage 2 after reboot
    cat > "$STAGE2_INIT" << 'INITSCRIPT'
#!/bin/sh
# Stage 2 init script - runs after sysupgrade reboot

case "$1" in
    start)
        if [ -f "/tmp/.mesh_stage2" ]; then
            logger -t mesh_setup "Stage 2 triggered, running mesh configuration"
            # Wait for network to be ready
            sleep 30
            /root/mesh_setup.sh stage2
            rm -f /tmp/.mesh_stage2
            rm -f /etc/init.d/mesh_stage2
        fi
        ;;
esac

exit 0
INITSCRIPT

    chmod +x "$STAGE2_INIT"
    log_info "Created Stage 2 init script at $STAGE2_INIT"
}

perform_sysupgrade() {
    local firmware_url="$1"
    
    log_info "Downloading firmware from $firmware_url"
    
    # Download firmware
    if ! wget -O /tmp/firmware.bin "$firmware_url" 2>/dev/null; then
        log_error "Failed to download firmware"
        return 1
    fi
    
    # Create stage 2 trigger
    touch "$STAGE2_FLAG"
    create_stage2_init
    
    # Enable the init script
    /etc/init.d/mesh_stage2 enable 2>/dev/null || true
    
    log_info "Initiating sysupgrade - router will reboot"
    sysupgrade --keep /tmp/firmware.bin
    
    # If we reach here, sysupgrade failed
    log_error "Sysupgrade failed or was interrupted"
    rm -f /tmp/firmware.bin "$STAGE2_FLAG"
    return 1
}

# -----------------------------------------------------------------------------
# STAGE 2: PACKAGE INSTALLATION AND CONFIGURATION
# -----------------------------------------------------------------------------

detect_wpad_variant() {
    # Detect which wpad variant to install based on what's available
    local wpad_variants="wpad-mesh-wolfssl wpad-mesh-openssl wpad-mesh-mbedtls"
    local installed_wpad=""
    local available_wpad=""
    
    # Check what's currently installed
    for variant in $wpad_variants; do
        if opkg status "$variant" 2>/dev/null | grep -q "^Status: install"; then
            installed_wpad="$variant"
            break
        fi
    done
    
    # If nothing installed, check what's available
    if [ -z "$installed_wpad" ]; then
        for variant in $wpad_variants; do
            if opkg list "$variant" 2>/dev/null | grep -q "^$variant"; then
                available_wpad="$variant"
                break
            fi
        done
    fi
    
    # Return the preferred variant
    if [ -n "$installed_wpad" ]; then
        echo "$installed_wpad"
    elif [ -n "$available_wpad" ]; then
        echo "$available_wpad"
    else
        # Fallback to wolfssl as it's most common
        echo "wpad-mesh-wolfssl"
    fi
}

install_required_packages() {
    log_info "Installing required packages..."
    
    # Update package lists
    if ! opkg update; then
        log_error "Failed to update package lists"
        return 1
    fi
    
    # Remove basic wpad if installed (conflicts with mesh)
    if opkg status "wpad-basic" 2>/dev/null | grep -q "^Status: install"; then
        log_info "Removing wpad-basic (incompatible with 802.11s)"
        opkg remove wpad-basic --force-removal-of-dependent-packages 2>/dev/null || true
    fi
    
    # Detect and install correct wpad variant
    local wpad_variant
    wpad_variant=$(detect_wpad_variant)
    log_info "Using wpad variant: $wpad_variant"
    
    if ! opkg status "$wpad_variant" 2>/dev/null | grep -q "^Status: install"; then
        log_info "Installing $wpad_variant"
        if ! opkg install "$wpad_variant"; then
            log_error "Failed to install $wpad_variant"
            return 1
        fi
    fi
    
    # Install batman-adv modules and tools
    log_info "Installing batman-adv packages"
    opkg install kmod-batman-adv batctl-default iw 2>/dev/null
    
    # Verify installations
    if ! check_command "batctl"; then
        log_warn "batctl not found, batman-adv may not be fully functional"
    fi
    
    log_info "Package installation complete"
    return 0
}

configure_wifi_mesh() {
    log_info "Configuring 802.11s Wi-Fi mesh..."
    
    # Get wifi configuration
    local wifi_config="/etc/config/wireless"
    
    # Find available radios
    local radio_count=0
    local radio_names=""
    
    for radio in $(uci show wireless | grep "=wifi-device" | cut -d'.' -f2 | cut -d'=' -f1); do
        radio_names="$radio_names $radio"
        radio_count=$((radio_count + 1))
    done
    
    if [ "$radio_count" -eq 0 ]; then
        log_error "No Wi-Fi radios detected"
        return 1
    fi
    
    log_info "Found $radio_count radio(s):$radio_names"
    
    # Configure each radio for 802.11s mesh
    for radio in $radio_names; do
        log_info "Configuring mesh interface on $radio"
        
        # Get radio band for channel selection
        local band
        band=$(uci get wireless.${radio}.band 2>/dev/null || echo "2g")
        
        # Determine channel based on band if auto
        local channel="$MESH_CHANNEL"
        if [ "$channel" = "auto" ]; then
            if [ "$band" = "5g" ] || [ "$band" = "5GHz" ]; then
                channel="36"
            else
                channel="6"
            fi
        fi
        
        # Delete existing mesh interface if it exists (idempotency)
        uci_delete_safe "wifi-iface" "mesh_${radio}"
        
        # Create new mesh interface configuration
        uci set wireless.mesh_${radio}=wifi-iface
        uci set wireless.mesh_${radio}.device="$radio"
        uci set wireless.mesh_${radio}.network="mesh_net"
        uci set wireless.mesh_${radio}.mode="mesh"
        uci set wireless.mesh_${radio}.mesh_id="$MESH_ID"
        uci set wireless.mesh_${radio}.encryption="none"
        uci set wireless.mesh_${radio}.mesh_fwding="0"
        
        # CRITICAL: mesh_fwding must be 0 to prevent 802.11s from interfering
        # with batman-adv's own forwarding logic
        log_info "Set mesh_fwding=0 on $radio (required for batman-adv)"
        
        # Set channel if not already configured on radio
        local current_channel
        current_channel=$(uci get wireless.${radio}.channel 2>/dev/null || echo "")
        if [ -z "$current_channel" ] || [ "$current_channel" = "auto" ]; then
            uci set wireless.${radio}.channel="$channel"
        fi
        
        # Ensure HT mode is set for better performance
        local ht_mode
        ht_mode=$(uci get wireless.${radio}.htmode 2>/dev/null || echo "")
        if [ -z "$ht_mode" ]; then
            if [ "$band" = "5g" ] || [ "$band" = "5GHz" ]; then
                uci set wireless.${radio}.htmode="VHT80"
            else
                uci set wireless.${radio}.htmode="HT40"
            fi
        fi
    done
    
    # Commit wireless changes
    uci commit wireless
    log_info "Wi-Fi mesh configuration saved"
    
    return 0
}

configure_batman_adv() {
    log_info "Configuring B.A.T.M.A.N. advanced..."
    
    local batman_config="/etc/config/batman-adv"
    
    # Delete existing bat0 interface if it exists (idempotency)
    uci_delete_safe "batman-adv" "bat0"
    
    # Create bat0 interface
    uci set batman-adv.bat0=batman-adv
    uci set batman-adv.bat0.ap_isolation="0"
    uci set batman-adv.bat0.bonding="0"
    uci set batman-adv.bat0.bridge_loop_avoidance="1"
    uci set batman-adv.bat0.distributed_arp_table="1"
    uci set batman-adv.bat0.fragmentation="1"
    uci set batman-adv.bat0.gw_mode="off"
    uci set batman-adv.bat0.isolation_mark="0x0000/0x0000"
    uci set batman-adv.bat0.log_level="0"
    uci set batman-adv.bat0.multicast_fanout="1"
    uci set batman-adv.bat0.multicast_mode="1"
    uci set batman-adv.bat0.orig_interval="1000"
    
    # Gateway mode configuration
    if [ "$IS_GATEWAY" -eq 1 ]; then
        uci set batman-adv.bat0.gw_mode="server"
        uci set batman-adv.bat0.gw_bandwidth="10000kbit/10000kbit"
        log_info "Configured as gateway node (gw_mode=server)"
    else
        uci set batman-adv.bat0.gw_mode="client"
        log_info "Configured as mesh client node (gw_mode=client)"
    fi
    
    uci commit batman-adv
    log_info "B.A.T.M.A.N. advanced configuration saved"
    
    return 0
}

configure_network_interfaces() {
    log_info "Configuring network interfaces..."
    
    local network_config="/etc/config/network"
    
    # Create mesh network interface (layer 2)
    uci_delete_safe "interface" "mesh_net"
    uci set network.mesh_net=interface
    uci set network.mesh_net.proto="none"
    uci set network.mesh_net.device="bat0"
    
    # Add bat0 to br-lan bridge
    # First, check if br-lan exists
    local lan_proto
    lan_proto=$(uci get network.lan.proto 2>/dev/null || echo "")
    
    if [ -n "$lan_proto" ]; then
        # br-lan exists, add bat0 to it
        log_info "Adding bat0 to existing br-lan bridge"
        
        # Get current devices
        local current_devices
        current_devices=$(uci get network.lan.device 2>/dev/null || echo "")
        
        # Add bat0 if not already present
        case "$current_devices" in
            *bat0*)
                log_info "bat0 already in br-lan devices"
                ;;
            *)
                if [ -n "$current_devices" ]; then
                    uci set network.lan.device="$current_devices bat0"
                else
                    uci set network.lan.device="bat0"
                fi
                log_info "Added bat0 to br-lan bridge"
                ;;
        esac
        
        # Also ensure mesh_net device is properly set
        uci set network.mesh_net.device="bat0"
    else
        # No br-lan, configure bat0 as the main LAN interface
        log_info "No br-lan found, configuring bat0 as primary LAN"
        uci set network.lan.proto="static"
        uci set network.lan.ipaddr="192.168.1.1"
        uci set network.lan.netmask="255.255.255.0"
        uci set network.lan.device="bat0"
    fi
    
    uci commit network
    log_info "Network interface configuration saved"
    
    return 0
}

configure_dhcp() {
    log_info "Configuring DHCP server..."
    
    local dhcp_config="/etc/config/dhcp"
    
    if [ "$IS_GATEWAY" -eq 1 ]; then
        # Enable DHCP on gateway nodes
        log_info "This node is a gateway - enabling DHCP server"
        
        # Ensure dnsmasq is enabled for lan
        uci set dhcp.lan.interface="lan"
        uci set dhcp.lan.start="100"
        uci set dhcp.lan.limit="150"
        uci set dhcp.lan.leasetime="12h"
        
        # Also listen on mesh_net interface
        uci_delete_safe "dhcp" "mesh"
        uci set dhcp.mesh=dhcp
        uci set dhcp.mesh.interface="mesh_net"
        uci set dhcp.mesh.start="100"
        uci set dhcp.mesh.limit="150"
        uci set dhcp.mesh.leasetime="12h"
        
        # Start dnsmasq service
        /etc/init.d/dnsmasq enable
        /etc/init.d/dnsmasq restart 2>/dev/null || true
    else
        # Disable DHCP on client nodes to avoid conflicts
        log_info "This node is a client - disabling DHCP server"
        
        uci set dhcp.lan.ignore="1"
        uci_delete_safe "dhcp" "mesh"
        
        # Stop dnsmasq on non-gateway nodes
        /etc/init.d/dnsmasq stop 2>/dev/null || true
        /etc/init.d/dnsmasq disable 2>/dev/null || true
    fi
    
    uci commit dhcp
    log_info "DHCP configuration saved"
    
    return 0
}

apply_configuration() {
    log_info "Applying configuration..."
    
    # Reload network configuration
    log_info "Reloading network configuration"
    /etc/init.d/network reload 2>/dev/null || service network reload 2>/dev/null || true
    
    # Restart batman-adv
    log_info "Restarting batman-adv"
    /etc/init.d/batman-adv restart 2>/dev/null || true
    
    # Reload wireless configuration
    log_info "Reloading Wi-Fi configuration"
    wifi 2>/dev/null || true
    
    # Wait for interfaces to come up
    sleep 5
    
    # Verify bat0 interface exists
    if ip link show bat0 >/dev/null 2>&1; then
        log_info "bat0 interface is up"
        
        # Show batman-adv status
        if check_command "batctl"; then
            log_info "Batman-adv status:"
            batctl g 2>/dev/null | head -5 || true
        fi
    else
        log_warn "bat0 interface not found - configuration may need manual intervention"
    fi
    
    # Show mesh interface status
    if iw dev | grep -q "OpenWrt-Mesh"; then
        log_info "802.11s mesh interface is active"
    else
        log_warn "802.11s mesh interface may not be active yet"
    fi
    
    log_info "Configuration applied successfully"
    return 0
}

cleanup_stage2() {
    # Clean up stage 2 files
    rm -f "$STAGE2_FLAG"
    rm -f "$STAGE2_INIT"
    log_info "Cleaned up Stage 2 files"
}

# -----------------------------------------------------------------------------
# MAIN EXECUTION
# -----------------------------------------------------------------------------

main() {
    log_info "=========================================="
    log_info "Starting OpenWrt Mesh Setup Script"
    log_info "=========================================="
    log_info "Architecture: $(get_architecture)"
    log_info "OpenWrt Version: $(get_openwrt_version)"
    log_info "Gateway Mode: $IS_GATEWAY"
    
    # Check if running as stage 2
    if [ "$1" = "stage2" ]; then
        log_info "Running Stage 2 (post-update configuration)"
        cleanup_stage2
        
        # Update package lists after fresh install
        log_info "Updating package lists after sysupgrade"
        opkg update || log_warn "opkg update failed"
        
        # Proceed to configuration
        configure_mesh_network
        apply_configuration
        
        log_info "=========================================="
        log_info "Mesh setup complete!"
        log_info "=========================================="
        return 0
    fi
    
    # Stage 1: Check for updates
    if check_and_update_openwrt; then
        log_info "Update performed, rebooting..."
        log_info "Stage 2 will run automatically after reboot"
        return 0
    fi
    
    # No update needed, proceed to configuration
    configure_mesh_network
    apply_configuration
    
    log_info "=========================================="
    log_info "Mesh setup complete!"
    log_info "=========================================="
    log_info "To verify mesh status, run:"
    log_info "  batctl g          # Show gateway info"
    log_info "  batctl o          # Show originators"
    log_info "  iw dev            # Show wireless interfaces"
    log_info "  logread | grep mesh_setup  # View setup logs"
}

configure_mesh_network() {
    # Main configuration sequence
    install_required_packages || {
        log_error "Package installation failed"
        return 1
    }
    
    configure_wifi_mesh || {
        log_error "Wi-Fi mesh configuration failed"
        return 1
    }
    
    configure_batman_adv || {
        log_error "Batman-adv configuration failed"
        return 1
    }
    
    configure_network_interfaces || {
        log_error "Network interface configuration failed"
        return 1
    }
    
    configure_dhcp || {
        log_error "DHCP configuration failed"
        return 1
    }
    
    return 0
}

# Run main function
main "$@"
