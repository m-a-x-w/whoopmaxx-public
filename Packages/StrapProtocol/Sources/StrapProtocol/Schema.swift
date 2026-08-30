import Foundation

/// Wire-format name tables: opcode and type numbers to the names the strap's own vocabulary uses.
///
/// A number with no entry here is NOT an error — it is a name this decoder has not learned. It
/// renders as `UNKNOWN(<n>)` so an unmapped opcode shows up in a log as a specific missing fact
/// rather than as a silent blank.
public enum Schema {
    public static let packetTypeNames: [Int: String] = [
        35: "COMMAND",
        36: "COMMAND_RESPONSE",
        37: "PUFFIN_COMMAND",
        38: "PUFFIN_COMMAND_RESPONSE",
        40: "REALTIME_DATA",
        43: "REALTIME_RAW_DATA",
        47: "HISTORICAL_DATA",
        48: "EVENT",
        49: "METADATA",
        50: "CONSOLE_LOGS",
        51: "REALTIME_IMU_STREAM",
        52: "HISTORICAL_IMU_STREAM",
        53: "RELATIVE_PUFFIN_EVENTS",
        54: "PUFFIN_EVENTS_FROM_STRAP",
        55: "RELATIVE_BATTERY_PACK_CONSOLE_LOGS",
        56: "PUFFIN_METADATA",
    ]

    public static let commandNames: [Int: String] = [
        1: "LINK_VALID",
        2: "GET_MAX_PROTOCOL_VERSION",
        3: "TOGGLE_REALTIME_HR",
        7: "REPORT_VERSION_INFO",
        10: "SET_CLOCK",
        11: "GET_CLOCK",
        14: "SET_GENERIC_HR_PROFILE",
        15: "FORGET_BONDS",
        19: "RUN_HAPTIC_PATTERN_MAVERICK",
        20: "ABORT_HISTORICAL_TRANSMITS",
        22: "SEND_HISTORICAL_DATA",
        23: "HISTORICAL_DATA_RESULT",
        25: "FORCE_TRIM",
        26: "GET_BATTERY_LEVEL",
        29: "REBOOT_STRAP",
        32: "POWER_CYCLE_STRAP",
        33: "SET_READ_POINTER",
        34: "GET_DATA_RANGE",
        35: "GET_HELLO_HARVARD",
        36: "START_UPDATE_LOAD",
        37: "LOAD_UPDATE_DATA",
        38: "PROCESS_UPDATE_IMAGE",
        48: "SEND_EVENT_PACKETS",
        61: "SET_AFE_PARAMS",
        62: "GET_AFE_PARAMS",
        63: "SEND_R10_R11_REALTIME",
        66: "SET_ALARM_TIME",
        67: "GET_ALARM_TIME",
        68: "RUN_ALARM",
        69: "DISABLE_ALARM",
        76: "GET_ADVERTISING_NAME_HARVARD",
        77: "SET_ADVERTISING_NAME_HARVARD",
        79: "RUN_HAPTICS_PATTERN",
        81: "START_RAW_DATA",
        82: "STOP_RAW_DATA",
        84: "GET_BODY_LOCATION_AND_STATUS",
        96: "ENTER_HIGH_FREQ_SYNC",
        97: "EXIT_HIGH_FREQ_SYNC",
        98: "GET_EXTENDED_BATTERY_INFO",
        103: "DISABLE_BLE_UART",
        105: "SAVE_IMU_DATA",
        106: "TOGGLE_IMU_MODE",
        107: "ENABLE_OPTICAL_DATA",
        108: "TOGGLE_OPTICAL_MODE",
        115: "GET_CONFIG_KEY_COUNT",
        116: "GET_CONFIG_KEY_NAME",
        117: "GET_FLAG_KEY_COUNT",
        118: "GET_FLAG_KEY_NAME",
        119: "SET_DEVICE_CONFIG_VALUE",
        120: "SET_FF_VALUE",
        121: "GET_CONFIG_VALUE",
        122: "STOP_HAPTICS",
        123: "SELECT_WRIST",
        124: "TOGGLE_LABRADOR_DATA_GENERATION",
        125: "TOGGLE_LABRADOR_RAW_SAVE",
        126: "ECG_SEND_RAW_DATA",
        127: "ECG_SAVE_FILTERED_DATA",
        128: "GET_FLAG_VALUE",
        138: "SET_SIGNAL_CONFIG",
        139: "TOGGLE_LABRADOR_FILTERED",
        140: "SET_CUSTOM_ADVERTISING_NAME",
        141: "GET_CUSTOM_ADVERTISING_NAME",
        145: "GET_HELLO",
        146: "SET_CLOCK_MAVERICK",
        147: "GET_CLOCK_GEN5",
        148: "WEAR_DETECT_OVERRIDE",
        149: "SET_LED_ACCESSIBILITY",
        150: "GYRO_ENABLE",
        151: "GET_BATTERY_PACK_INFO",
        152: "GYRO_STATUS",
        153: "PERSISTENT_OPTICAL_SAVE",
        154: "TOGGLE_PERSISTENT_R21",
    ]

    public static let eventNames: [Int: String] = [
        3: "BATTERY_LEVEL",
        7: "CHARGING_ON",
        8: "CHARGING_OFF",
        9: "WRIST_ON",
        10: "WRIST_OFF",
        13: "RTC_LOST",
        14: "DOUBLE_TAP",
        15: "BOOT",
        16: "SET_RTC",
        21: "BATTERY_PACK_CONNECTED",
        22: "BATTERY_PACK_REMOVED",
        26: "TRIM_ALL_DATA",
        27: "TRIM_ALL_DATA_ENDED",
        28: "FLASH_INIT_COMPLETE",
        29: "STRAP_CONDITION_REPORT",
        31: "BLE_BONDED",
        33: "BLE_REALTIME_HR_ON",
        34: "BLE_REALTIME_HR_OFF",
        40: "CH1_SATURATION",
        41: "CH2_SATURATION",
        42: "ACCEL_SATURATION",
        46: "RAW_DATA_COLLECTION_ON",
        47: "RAW_DATA_COLLECTION_OFF",
        56: "STRAP_DRIVEN_ALARM_SET",
        57: "STRAP_DRIVEN_ALARM_EXECUTED",
        58: "APP_DRIVEN_ALARM_EXECUTED",
        59: "STRAP_DRIVEN_ALARM_DISABLED",
        60: "HAPTICS_FIRED",
        63: "EXTENDED_BATTERY_INFORMATION",
        96: "HIGH_FREQ_SYNC_PROMPT",
        97: "HIGH_FREQ_SYNC_ENABLED",
        98: "HIGH_FREQ_SYNC_DISABLED",
        100: "HAPTICS_TERMINATED",
        109: "BATTERY_PACK_INFO",
        111: "TEMPERATURE_LEVEL",
        123: "GENERIC_FIRMWARE_EVENT",
    ]

    public static let metadataNames: [Int: String] = [
        1: "HISTORY_START",
        2: "HISTORY_END",
        3: "HISTORY_COMPLETE",
    ]

    /// Look up a name, falling back to a form that names the number it could not resolve.
    public static func name(_ table: [Int: String], _ value: Int) -> String {
        table[value] ?? "UNKNOWN(\(value))"
    }

    /// REALTIME_RAW_DATA's IMU variant, told from the optical variant (1924) by inner length.
    /// Only the IMU variant carries heart rate and R-R in its header.
    public static let rawImuInnerLength = 1920

    /// BATTERY_LEVEL. The strap re-emits this every eight minutes or so, and it is the only
    /// source of a live state-of-charge reading.
    public static let batteryLevelEvent = 3

    /// GET_BATTERY_LEVEL — the on-demand battery poll; its reply is deci-percent.
    public static let getBatteryLevelOpcode = 26

    /// REPORT_VERSION_INFO — the gen4 firmware readout BLEManager requests on connect.
    public static let reportVersionInfoOpcode = 7

    /// GET_HELLO — the gen5 info block carrying the firmware version.
    public static let getHelloOpcode = 145

    /// GET_CLOCK. Both generations answer on this opcode — gen5's 147 is deprecated — so the one
    /// number covers the reply that carries the strap's RTC.
    public static let getClockOpcode = 11

    public static func packetTypeName(_ v: Int) -> String { name(packetTypeNames, v) }
    public static func commandName(_ v: Int) -> String { name(commandNames, v) }
    public static func eventName(_ v: Int) -> String { name(eventNames, v) }
    public static func metadataName(_ v: Int) -> String { name(metadataNames, v) }
}
