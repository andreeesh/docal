use crate::models::RuntimeInfo;

fn map_os_name(os: &str) -> &'static str {
    match os {
        "windows" => "windows",
        "linux" => "linux",
        "macos" => "macos",
        _ => "unknown",
    }
}

#[tauri::command]
pub fn get_runtime_info() -> RuntimeInfo {
    RuntimeInfo::new(map_os_name(std::env::consts::OS))
}

#[cfg(test)]
mod tests {
    use super::map_os_name;

    #[test]
    fn maps_supported_operating_systems() {
        assert_eq!(map_os_name("windows"), "windows");
        assert_eq!(map_os_name("linux"), "linux");
        assert_eq!(map_os_name("macos"), "macos");
    }

    #[test]
    fn maps_unrecognized_operating_systems_to_unknown() {
        assert_eq!(map_os_name("freebsd"), "unknown");
        assert_eq!(map_os_name("ios"), "unknown");
    }
}
