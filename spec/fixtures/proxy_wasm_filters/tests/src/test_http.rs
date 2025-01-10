use crate::*;

pub struct TestHttp {
    pub config: Option<TestConfig>,
}

impl TestHttp {
    pub fn send_plain_response(&mut self, status: StatusCode, body: Option<&str>) {
        self.send_http_response(status.as_u16() as u32, vec![], body.map(|b| b.as_bytes()))
    }

    fn get_prop(&self, ns: &str, prop: &str) -> String {
        if let Some(addr) = self.get_property(vec![ns, prop]) {
            match std::str::from_utf8(&addr) {
                Ok(value) => value.to_string(),
                Err(_) => "".to_string(),
            }
        } else {
            "".to_string()
        }
    }

    fn set_prop(&self, ns: &str, prop: &str, value: Option<&str>) {
        let value: Option<&[u8]> = value.map(|v| v.as_bytes());
        self.set_property(vec![ns, prop], value);
    }

    fn update_metrics(&self) {
        let base: u64 = 2;

        let s_name = self.get_prop("kong", "service_name");
        let r_name = self.get_prop("kong", "route_name");

        let labeled_c = format!("a_labeled_counter_s_id={}_r_id={}", s_name, r_name);
        let labeled_g = format!("a_labeled_gauge_s_id={}_r_id={}", s_name, r_name);
        let labeled_h = format!("a_labeled_histogram_s_id={}_r_id={}", s_name, r_name);

        metrics::increment_counter("a_counter").unwrap();
        metrics::increment_counter(&labeled_c).unwrap();

        metrics::record_gauge("a_gauge", 1).unwrap();
        metrics::record_gauge(&labeled_g, 1).unwrap();

        for i in 0..18 {
            metrics::record_histogram("a_histogram", base.pow(i)).unwrap();
            metrics::record_histogram(&labeled_h, base.pow(i)).unwrap();
        }
    }

    fn send_http_dispatch(&mut self, config: TestConfig) -> Action {
        let mut timeout = Duration::from_secs(0);
        let mut headers = Vec::new();

        headers.push((
            ":method",
            config
                .map
                .get("method")
                .map(|v| v.as_str())
                .unwrap_or("GET"),
        ));

        headers.push((
            ":path",
            config.map.get("path").map(|v| v.as_str()).unwrap_or("/"),
        ));

        headers.push((
            ":authority",
            config
                .map
                .get("host")
                .map(|v| v.as_str())
                .unwrap_or("127.0.0.1:15555"),
        ));

        if let Some(vals) = config.map.get("headers") {
            for (k, v) in vals.split('|').filter_map(|s| s.split_once(':')) {
                headers.push((k, v));
            }
        }

        if let Some(val) = config.map.get("timeout") {
            if let Ok(t) = parse_duration::parse(val) {
                timeout = t;
            }
        }

        self.dispatch_http_call(
            config
                .map
                .get("host")
                .map(|v| v.as_str())
                .unwrap_or("127.0.0.1:15555"),
            headers,
            config.map.get("body").map(|v| v.as_bytes()),
            vec![],
            timeout,
        )
        .expect("dispatch error");

        Action::Pause
    }

    pub fn run_tests(&mut self, cur_phase: TestPhase) -> Action {
        const PHASE_HEADER_NAME: &str = "X-PW-Phase";
        const TEST_HEADER_NAME: &str = "X-PW-Test";
        const INPUT_HEADER_NAME: &str = "X-PW-Input";

        let opt_input = self.get_http_request_header(INPUT_HEADER_NAME);
        let opt_test = self.get_http_request_header(TEST_HEADER_NAME);
        let on_phase = self.get_http_request_header(PHASE_HEADER_NAME).map_or(
            TestPhase::RequestHeaders,
            |s| {
                s.parse()
                    .unwrap_or_else(|_| panic!("unknown phase: {:?}", s))
            },
        );

        if cur_phase == on_phase {
            info!("[proxy-wasm] testing in \"{:?}\"", on_phase);

            if cur_phase == TestPhase::RequestHeaders || cur_phase == TestPhase::RequestBody {
                self.set_http_request_header(INPUT_HEADER_NAME, None);
                self.set_http_request_header(TEST_HEADER_NAME, None);
                self.set_http_request_header(PHASE_HEADER_NAME, None);

                add_request_header(self);
            }

            add_response_header(self);

            if let Some(test) = opt_test {
                match test.as_str() {
                    "trap" => panic!("trap msg"),
                    "local_response" => {
                        self.send_plain_response(StatusCode::OK, opt_input.as_deref())
                    }
                    "get_kong_property" => {
                        let name = &opt_input.unwrap_or("".to_string());
                        let value = self.get_prop("kong", name);
                        info!("[proxy-wasm] kong.{}: \"{:?}\"", name, value);
                        self.send_plain_response(StatusCode::OK, Some(&value))
                    }
                    "set_kong_property" => {
                        if let Some(input) = opt_input {
                            let (key, value) = match input.split_once('=') {
                                Some((key, value)) => (key, Some(value)),
                                None => (input.as_ref(), None),
                            };

                            self.set_prop("kong", key, value);
                            info!("[proxy-wasm] kong.{} = \"{:?}\"", key, value);
                        }
                    }
                    "echo_http_dispatch" => {
                        let config = TestConfig::from_str(&opt_input.unwrap_or("".to_string()))
                            .expect("invalid configuration");

                        return self.send_http_dispatch(config);
                    }
                    "update_metrics" => self.update_metrics(),
                    "dump_config" => {
                        let res = self.config.as_ref().map(|config| config.to_string());
                        self.send_plain_response(StatusCode::OK, res.as_deref());
                    }
                    _ => (),
                }
            }
        }

        Action::Continue
    }
}
