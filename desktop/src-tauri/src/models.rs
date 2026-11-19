use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeInfo {
    pub host_os: String,
    pub backend_status: String,
    pub data_source: String,
}

impl RuntimeInfo {
    pub fn new(host_os: impl Into<String>) -> Self {
        Self {
            host_os: host_os.into(),
            backend_status: "not_connected".to_string(),
            data_source: "native".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::RuntimeInfo;

    #[test]
    fn defaults_never_claim_a_docal_connection() {
        let info = RuntimeInfo::new("linux");
        assert_eq!(info.backend_status, "not_connected");
        assert_eq!(info.data_source, "native");
    }
}
