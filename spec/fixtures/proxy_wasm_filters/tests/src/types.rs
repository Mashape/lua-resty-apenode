use crate::*;
use std::collections::HashMap;

pub struct TestConfig {
    pub map: HashMap<String, String>,
}

impl FromStr for TestConfig {
    type Err = std::str::Utf8Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(TestConfig {
            map: s
                .split_whitespace()
                .filter_map(|s| s.split_once('='))
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        })
    }
}

impl std::fmt::Display for TestConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut values: Vec<String> = self.map.iter().map(|(k, v)| format!("{k}={v}")).collect();

        values.sort();

        write!(f, "{}", values.join(" "))
    }
}

#[derive(Debug, Eq, PartialEq, enum_utils::FromStr)]
#[enumeration(rename_all = "snake_case")]
pub enum TestPhase {
    RequestHeaders,
    RequestBody,
    ResponseHeaders,
    ResponseBody,
    Log,
}
