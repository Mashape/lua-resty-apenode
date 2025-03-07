# Table of Contents

- [3.9.0](#390)
- [3.8.1](#381)
- [3.8.0](#380)
- [3.7.1](#371)
- [3.7.0](#370)
- [3.6.1](#361)
- [3.6.0](#360)
- [3.5.0](#350)
- [3.4.2](#342)
- [3.4.1](#341)
- [3.4.0](#340)
- [3.3.0](#330)
- [3.2.0](#320)
- [3.1.0](#310)
- [3.0.1](#301)
- [3.0.0](#300)
- [Previous releases](#previous-releases)

## Unreleased

Individual unreleased changelog entries can be located at [changelog/unreleased](changelog/unreleased). They will be assembled into [CHANGELOG.md](CHANGELOG.md) once released.

## 3.9.0

### Kong

#### Deprecations
##### Core

- `node_id` in configuration has been deprecated.
 [#13687](https://github.com/Kong/kong/issues/13687)

#### Dependencies
##### Core

- Bumped lua-kong-nginx-module from 0.11.0 to 0.11.1 to fix an issue where the upstream cert chain wasn't properly set.
 [#12752](https://github.com/Kong/kong/issues/12752)

- Bumped lua-resty-events to 0.3.1. Optimized the memory usage.
 [#13097](https://github.com/Kong/kong/issues/13097)

- Bumped lua-resty-lmdb to 1.6.0. Allowing page_size to be 1.
 [#13908](https://github.com/Kong/kong/issues/13908)

- Bumped lua-resty-lmdb to 1.5.0. Added page_size parameter to allow overriding page size from caller side.
 [#12786](https://github.com/Kong/kong/issues/12786)

##### Default

- Kong Gateway now supports Ubuntu 24.04 (Noble Numbat) with both open-source and Enterprise packages.
 [#13626](https://github.com/Kong/kong/issues/13626)

- Bumped rpm dockerfile default base UBI 8 -> 9
 [#13574](https://github.com/Kong/kong/issues/13574)

- Bumped lua-resty-aws to 1.5.4 to fix a bug inside region prefix generation.
 [#12846](https://github.com/Kong/kong/issues/12846)

- Bumped lua-resty-ljsonschema to 1.2.0, adding support for `null` as a valid option in `enum` types and properly calculation of utf8 string length instead of byte count
 [#13783](https://github.com/Kong/kong/issues/13783)

- Bumped `ngx_wasm_module` to `9136e463a6f1d80755ce66c88c3ddecd0eb5e25d`
 [#12011](https://github.com/Kong/kong/issues/12011)


- Bumped `Wasmtime` version to `26.0.0`
 [#12011](https://github.com/Kong/kong/issues/12011)

- Bumped OpenSSL to 3.2.3 to fix unbounded memory growth with session handling in TLSv1.3 and other CVEs.
 [#13448](https://github.com/Kong/kong/issues/13448)

 - **Wasm**: Removed the experimental datakit Wasm filter
 [#14012](https://github.com/Kong/kong/issues/14012)

#### Features
##### CLI Command
- Added the `kong drain` CLI command to make the `/status/ready` endpoint return a `503 Service Unavailable` response.
 [#13838](https://github.com/Kong/kong/issues/13838)
##### Core

- Added a new feature for Kong Manager that supports multiple domains, enabling dynamic cross-origin access for Admin API requests.
 [#13664](https://github.com/Kong/kong/issues/13664)

- Added an ADA dependency: WHATWG-compliant and fast URL parser.
 [#13120](https://github.com/Kong/kong/issues/13120)

- Addded a new LLM driver for interfacing with the Hugging Face inference API.
The driver supports both serverless and dedicated LLM instances hosted by
Hugging Face for conversational and text generation tasks.
 [#13484](https://github.com/Kong/kong/issues/13484)


- Increased the priority order of the correlation id to 100001 from 1 so that the plugin can be used
with other plugins especially custom auth plugins.
 [#13581](https://github.com/Kong/kong/issues/13581)

- Added a `tls.disable_http2_alpn()` function patch for disabling HTTP/2 ALPN when performing a TLS handshake.
 [#13709](https://github.com/Kong/kong/issues/13709)


- Improved the output of the request debugger:
  - The resolution of field `total_time` is now in microseconds.
  - A new field, `total_time_without_upstream`,  shows the latency only introduced by Kong.
 [#13460](https://github.com/Kong/kong/issues/13460)
- **proxy-wasm**: Added support for Wasm filters to be configured via the `/plugins` Admin API.
 [#13843](https://github.com/Kong/kong/issues/13843)
##### PDK

- Added `kong.service.request.clear_query_arg(name)` to PDK.
 [#13619](https://github.com/Kong/kong/issues/13619)

- Array and Map type span attributes are now supported by the tracing PDK
 [#13818](https://github.com/Kong/kong/issues/13818)
##### Plugin
- **Prometheus**: Increased the upper limit of `KONG_LATENCY_BUCKETS` to 6000 to enhance latency tracking precision.
 [#13588](https://github.com/Kong/kong/issues/13588)

- **ai-proxy**: Disabled HTTP/2 ALPN handshake for connections on routes configured with AI-proxy.
 [#13735](https://github.com/Kong/kong/issues/13735)

- **Redirect**: Added a new plugin to redirect requests to another location.
 [#13900](https://github.com/Kong/kong/issues/13900)


- **Prometheus**: Added support for Proxy-Wasm metrics.
 [#13681](https://github.com/Kong/kong/issues/13681)

##### Admin API
- **Admin API**: Added support for official YAML media-type (`application/yaml`) to the `/config` endpoint.
 [#13713](https://github.com/Kong/kong/issues/13713)
##### Clustering

- Added a remote procedure call (RPC) framework for Hybrid mode deployments.
 [#12320](https://github.com/Kong/kong/issues/12320)

#### Fixes
##### Core

- Fixed an issue where the `ngx.balancer.recreate_request` API did not refresh the body buffer when `ngx.req.set_body_data` is used in the balancer phase.
 [#13882](https://github.com/Kong/kong/issues/13882)

- Fix to always pass `ngx.ctx` to `log_init_worker_errors` as otherwise it may runtime crash.
 [#13731](https://github.com/Kong/kong/issues/13731)

- Fixed an issue where the workspace ID was not included in the plugin config in the plugins iterator.
 [#13377](https://github.com/Kong/kong/issues/13377)

- Fixed an issue where the workspace id was not included in the plugin config in the plugins iterator.
 [#13872](https://github.com/Kong/kong/issues/13872)

- Fixed a 500 error triggered by unhandled nil fields during schema validation.
 [#13861](https://github.com/Kong/kong/issues/13861)

- **Vault**: Fixed an issue where array-like configuration fields cannot contain vault reference.
 [#13953](https://github.com/Kong/kong/issues/13953)

- **Vault**: Fixed an issue where updating a vault entity in a non-default workspace wouldn't take effect.
 [#13610](https://github.com/Kong/kong/issues/13610)

- **Vault**: Fixed an issue where vault reference in kong configuration cannot be dereferenced when both http and stream subsystems are enabled.
 [#13953](https://github.com/Kong/kong/issues/13953)

- **proxy-wasm:** Added a check that prevents Kong from starting when the
database contains invalid Wasm filters.
 [#13764](https://github.com/Kong/kong/issues/13764)

- Fixed an issue where the `kong.request.enable_buffering` couldn't be used when the downstream used HTTP/2.
 [#13614](https://github.com/Kong/kong/issues/13614)
##### PDK

- Lined up the `kong.log.inspect` function to log at `notice` level as documented
 [#13642](https://github.com/Kong/kong/issues/13642)

- Fix error message for invalid retries variable
 [#13605](https://github.com/Kong/kong/issues/13605)

##### Plugin

- **ai-proxy**: Fixed a bug where tools (function) calls to Anthropic would return empty results.
 [#13760](https://github.com/Kong/kong/issues/13760)


- **ai-proxy**: Fixed a bug where tools (function) calls to Bedrock would return empty results.
 [#13760](https://github.com/Kong/kong/issues/13760)


- **ai-proxy**: Fixed a bug where Bedrock Guardrail config was ignored.
 [#13760](https://github.com/Kong/kong/issues/13760)


- **ai-proxy**: Fixed a bug where tools (function) calls to Cohere would return empty results.
 [#13760](https://github.com/Kong/kong/issues/13760)


- **ai-proxy**: Fixed a bug where Gemini provider would return an error if content safety failed in AI Proxy.
 [#13760](https://github.com/Kong/kong/issues/13760)


- **ai-proxy**: Fixed a bug where tools (function) calls to Gemini (or via Vertex) would return empty results.
 [#13760](https://github.com/Kong/kong/issues/13760)


- **ai-proxy**: Fixed an issue where AI Transformer plugins always returned a 404 error when using 'Google One' Gemini subscriptions.
 [#13703](https://github.com/Kong/kong/issues/13703)


- **ai-transformers**: Fixed a bug where the correct LLM error message was not propagated to the caller.
 [#13703](https://github.com/Kong/kong/issues/13703)

- **AI-Proxy**: Fixed an issue where multi-modal requests were blocked on the Azure AI provider.
 [#13702](https://github.com/Kong/kong/issues/13702)


- Fixed an bug that AI semantic cache can't use request provided models
 [#13627](https://github.com/Kong/kong/issues/13627)

- **AWS-Lambda**: Fixed an issue in proxy integration mode that caused an internal server error when the `multiValueHeaders` was null.
 [#13533](https://github.com/Kong/kong/issues/13533)

- **jwt**: ensure `rsa_public_key` isn't base64-decoded.
 [#13717](https://github.com/Kong/kong/issues/13717)

- **key-auth**: Fixed an issue with the order of query arguments, ensuring that arguments retain order when hiding the credentials.
 [#13619](https://github.com/Kong/kong/issues/13619)

- **rate-limiting**: Fixed a bug where the returned values from `get_redis_connection()` were incorrect.
 [#13613](https://github.com/Kong/kong/issues/13613)

- **rate-limiting**: Fixed an issue that caused an HTTP 500 error when `hide_client_headers` was set to `true` and the request exceeded the rate limit.
 [#13722](https://github.com/Kong/kong/issues/13722)
##### Admin API

- Fix for querying admin API entities with empty tags
 [#13723](https://github.com/Kong/kong/issues/13723)

- Fixed an issue where nested parameters couldn't be parsed correctly when using `form-urlencoded` requests.
 [#13668](https://github.com/Kong/kong/issues/13668)
##### Clustering

- **Clustering**: Adjusted error log levels for control plane connections.
 [#13863](https://github.com/Kong/kong/issues/13863)
##### Default

- **Loggly**: Fixed an issue where `/bin/hostname` missing caused an error warning on startup.
 [#13788](https://github.com/Kong/kong/issues/13788)

### Kong-Manager

#### Fixes
##### Default

- Kong Manager will now hide the scope change field when creating/editing a scoped plugin from another entity.
 [#297](https://github.com/Kong/kong-manager/issues/297)


- Improved the user experience in Kong Manager by fixing various UI-related issues.
 [#277](https://github.com/Kong/kong-manager/issues/277) [#283](https://github.com/Kong/kong-manager/issues/283) [#286](https://github.com/Kong/kong-manager/issues/286) [#287](https://github.com/Kong/kong-manager/issues/287) [#288](https://github.com/Kong/kong-manager/issues/288) [#291](https://github.com/Kong/kong-manager/issues/291) [#293](https://github.com/Kong/kong-manager/issues/293) [#295](https://github.com/Kong/kong-manager/issues/295) [#298](https://github.com/Kong/kong-manager/issues/298) [#302](https://github.com/Kong/kong-manager/issues/302) [#304](https://github.com/Kong/kong-manager/issues/304) [#306](https://github.com/Kong/kong-manager/issues/306) [#309](https://github.com/Kong/kong-manager/issues/309) [#317](https://github.com/Kong/kong-manager/issues/317) [#319](https://github.com/Kong/kong-manager/issues/319) [#322](https://github.com/Kong/kong-manager/issues/322) [#325](https://github.com/Kong/kong-manager/issues/325) [#329](https://github.com/Kong/kong-manager/issues/329) [#330](https://github.com/Kong/kong-manager/issues/330)


- Unified the redirection logic in Kong Manager upon entity operations.
 [#289](https://github.com/Kong/kong-manager/issues/289)


## 3.8.1

## Kong

#### Dependencies
##### Core

- Bumped lua-kong-nginx-module from 0.11.0 to 0.11.1 to fix an issue where the upstream cert chain wasn't properly set.
 [#12752](https://github.com/Kong/kong/issues/12752)
##### Default

- Bumped lua-resty-aws to 1.5.4, to fix a bug inside region prefix generating
 [#12846](https://github.com/Kong/kong/issues/12846)

#### Features
##### Plugin

- **Prometheus**: Bumped KONG_LATENCY_BUCKETS bucket's maximal capacity to 6000
 [#13797](https://github.com/Kong/kong/issues/13797)

#### Fixes
##### Core

- **Vault**: Fixed an issue where updating a vault entity in a non-default workspace will not take effect.
 [#13670](https://github.com/Kong/kong/issues/13670)
##### Plugin

- **ai-proxy**: Fixed an issue where AI Transformer plugins always returned a 404 error when using 'Google One' Gemini subscriptions.
 [#13753](https://github.com/Kong/kong/issues/13753)


- **ai-transformers**: Fixed a bug where the correct LLM error message was not propagated to the caller.
 [#13753](https://github.com/Kong/kong/issues/13753)


- Fixed an bug that AI semantic cache can't use request provided models
 [#13633](https://github.com/Kong/kong/issues/13633)


- **Rate-Limiting**: Fixed an issue that caused a 500 error when using the rate-limiting plugin. When the `hide_client_headers` option is set to true and a 429 error is triggered,
it should return a 429 error code instead of a 500 error code.
 [#13759](https://github.com/Kong/kong/issues/13759)
##### Admin API

- Fixed an issue where sending `tags= `(empty parameter) resulted in 500 error. Now, Kong returns a 400 error, as empty explicit tags are not allowed.
 [#13813](https://github.com/Kong/kong/issues/13813)

## 3.8.0

### Kong


#### Performance
##### Performance

- Fixed an inefficiency issue in the Luajit hashing algorithm
 [#13240](https://github.com/Kong/kong/issues/13240)

##### Core

- Removed unnecessary DNS client initialization
 [#13479](https://github.com/Kong/kong/issues/13479)


- Improved latency performance when gzipping/gunzipping large data (such as CP/DP config data).
 [#13338](https://github.com/Kong/kong/issues/13338)



#### Deprecations
##### Default

- Debian 10, CentOS 7, and RHEL 7 reached their End of Life (EOL) dates on June 30, 2024. As of version 3.8.0.0 onward, Kong is not building installation packages or Docker images for these operating systems. Kong is no longer providing official support for any Kong version running on these systems.
 [#13468](https://github.com/Kong/kong/issues/13468)





#### Dependencies
##### Core

- Bumped lua-resty-acme to 0.15.0 to support username/password auth with redis.
 [#12909](https://github.com/Kong/kong/issues/12909)


- Bumped lua-resty-aws to 1.5.3 to fix a bug related to STS regional endpoint.
 [#12846](https://github.com/Kong/kong/issues/12846)


- Bumped lua-resty-healthcheck from 3.0.1 to 3.1.0 to fix an issue that was causing high memory usage
 [#13038](https://github.com/Kong/kong/issues/13038)


- Bumped lua-resty-lmdb to 1.4.3 to get fixes from the upstream (lmdb 0.9.33), which resolved numerous race conditions and fixed a cursor issue.
 [#12786](https://github.com/Kong/kong/issues/12786)


- Bumped lua-resty-openssl to 1.5.1 to fix some issues including a potential use-after-free issue.
 [#12665](https://github.com/Kong/kong/issues/12665)


- Bumped OpenResty to 1.25.3.2 to improve the performance of the LuaJIT hash computation.
 [#12327](https://github.com/Kong/kong/issues/12327)


- Bumped PCRE2 to 10.44 to fix some bugs and tidy-up the release (nothing important)
 [#12366](https://github.com/Kong/kong/issues/12366)




- Introduced a yieldable JSON library `lua-resty-simdjson`,
which would improve the latency significantly.
 [#13421](https://github.com/Kong/kong/issues/13421)

##### Default

- Bumped lua-protobuf 0.5.2
 [#12834](https://github.com/Kong/kong/issues/12834)


- Bumped LuaRocks from 3.11.0 to 3.11.1
 [#12662](https://github.com/Kong/kong/issues/12662)


- Bumped `ngx_wasm_module` to `96b4e27e10c63b07ed40ea88a91c22f23981db35`
 [#12011](https://github.com/Kong/kong/issues/12011)


- Bumped `Wasmtime` version to `23.0.2`
 [#13567](https://github.com/Kong/kong/pull/13567)



- Made the RPM package relocatable with the default prefix set to `/`.
 [#13468](https://github.com/Kong/kong/issues/13468)


#### Features
##### Configuration

- Configure Wasmtime module cache when Wasm is enabled
  [#12930](https://github.com/Kong/kong/issues/12930)

##### Core

- **prometheus**: Added `ai_requests_total`, `ai_cost_total` and `ai_tokens_total` metrics in the Prometheus plugin to start counting AI usage.
 [#13148](https://github.com/Kong/kong/issues/13148)


- Added a new configuration `concurrency_limit`(integer, default to 1) for Queue to specify the number of delivery timers.
Note that setting `concurrency_limit` to `-1` means no limit at all, and each HTTP log entry would create an individual timer for sending.
 [#13332](https://github.com/Kong/kong/issues/13332)


- Append gateway info to upstream `Via` header like `1.1 kong/3.8.0`, and optionally to
response `Via` header if it is present in the `headers` config of "kong.conf", like `2 kong/3.8.0`,
according to `RFC7230` and `RFC9110`.
 [#12733](https://github.com/Kong/kong/issues/12733)


- Starting from this version, a new DNS client library has been implemented and added into Kong, which is disabled by default. The new DNS client library has the following changes - Introduced global caching for DNS records across workers, significantly reducing the query load on DNS servers. - Introduced observable statistics for the new DNS client, and a new Status API `/status/dns` to retrieve them. - Simplified the logic and make it more standardized
 [#12305](https://github.com/Kong/kong/issues/12305)

##### PDK

- Added `0` to support unlimited body size. When parameter `max_allowed_file_size` is `0`, `get_raw_body` will return the entire body, but the size of this body will still be limited by Nginx's `client_max_body_size`.
 [#13431](https://github.com/Kong/kong/issues/13431)


- Extend kong.request.get_body and kong.request.get_raw_body to read from buffered file
 [#13158](https://github.com/Kong/kong/issues/13158)

- Added a new PDK module `kong.telemetry` and function: `kong.telemetry.log`
to generate log entries to be reported via the OpenTelemetry plugin.
 [#13329](https://github.com/Kong/kong/issues/13329)

##### Plugin

- **acl:** Added a new config `always_use_authenticated_groups` to support using authenticated groups even when an authenticated consumer already exists.
 [#13184](https://github.com/Kong/kong/issues/13184)


- AI plugins: retrieved latency data and pushed it to logs and metrics.
 [#13428](https://github.com/Kong/kong/issues/13428)

- Allow AI plugin to read request from buffered file
 [#13158](https://github.com/Kong/kong/pull/13158)


- **AI-proxy-plugin**: Add `allow_override` option to allow overriding the upstream model auth parameter or header from the caller's request.
 [#13158](https://github.com/Kong/kong/issues/13158)


- **AI-proxy-plugin**: Replace the lib and use cycle_aware_deep_copy for the `request_table` object.
 [#13582](https://github.com/Kong/kong/issues/13582)


- Kong AI Gateway (AI Proxy and associated plugin family) now supports
all AWS Bedrock "Converse API" models.
 [#12948](https://github.com/Kong/kong/issues/12948)


- Kong AI Gateway (AI Proxy and associated plugin family) now supports
the Google Gemini "chat" (generateContent) interface.
 [#12948](https://github.com/Kong/kong/issues/12948)


- **ai-proxy**: Allowed mistral provider to use mistral.ai managed service by omitting upstream_url
 [#13481](https://github.com/Kong/kong/issues/13481)

- **ai-proxy**: Added a new response header X-Kong-LLM-Model that displays the name of the language model used in the AI-Proxy plugin.
 [#13472](https://github.com/Kong/kong/issues/13472)

- **AI-Prompt-Guard**: add `match_all_roles` option to allow match all roles in addition to `user`.
 [#13183](https://github.com/Kong/kong/issues/13183)

- "**AWS-Lambda**: Added support for a configurable STS endpoint with the new configuration field `aws_sts_endpoint_url`.
 [#13388](https://github.com/Kong/kong/issues/13388)


- **AWS-Lambda**: A new configuration field `empty_arrays_mode` is now added to control whether Kong should send `[]` empty arrays (returned by Lambda function) as `[]` empty arrays or `{}` empty objects in JSON responses.`
 [#13084](https://github.com/Kong/kong/issues/13084)




- Added support for json_body rename in response-transformer plugin
 [#13131](https://github.com/Kong/kong/issues/13131)


- **OpenTelemetry:** Added support for OpenTelemetry formatted logs.
 [#13291](https://github.com/Kong/kong/issues/13291)


- **standard-webhooks**: Added standard webhooks plugin.
 [#12757](https://github.com/Kong/kong/issues/12757)

- **Request-Transformer**: Fixed an issue where renamed query parameters, url-encoded body parameters, and json body parameters were not handled properly when target name is the same as the source name in the request.
 [#13358](https://github.com/Kong/kong/issues/13358)

##### Admin API

- Added support for brackets syntax for map fields configuration via the Admin API
 [#13313](https://github.com/Kong/kong/issues/13313)


#### Fixes
##### CLI Command

- Fixed an issue where some debug level error logs were not being displayed by the CLI.
 [#13143](https://github.com/Kong/kong/issues/13143)

##### Configuration

- Re-enabled the Lua DNS resolver from proxy-wasm by default.
 [#13424](https://github.com/Kong/kong/issues/13424)

##### Core

- Fixed an issue where luarocks-admin was not available in /usr/local/bin.
 [#13372](https://github.com/Kong/kong/issues/13372)


- Fixed an issue where 'read' was not always passed to Postgres read-only database operations.
 [#13530](https://github.com/Kong/kong/issues/13530)


- Deprecated shorthand fields don't take precedence over replacement fields when both are specified.
 [#13486](https://github.com/Kong/kong/issues/13486)


- Fixed an issue where `lua-nginx-module` context was cleared when `ngx.send_header()` triggered `filter_finalize` [openresty/lua-nginx-module#2323](https://github.com/openresty/lua-nginx-module/pull/2323).
 [#13316](https://github.com/Kong/kong/issues/13316)


- Changed the way deprecated shorthand fields are used with new fields.
If the new field contains null it allows for deprecated field to overwrite it if both are present in the request.
 [#13592](https://github.com/Kong/kong/issues/13592)


- Fixed an issue where unnecessary uninitialized variable error log is reported when 400 bad requests were received.
 [#13201](https://github.com/Kong/kong/issues/13201)


- Fixed an issue where the URI captures are unavailable when the first capture group is absent.
 [#13024](https://github.com/Kong/kong/issues/13024)


- Fixed an issue where the priority field can be set in a traditional mode route
When 'router_flavor' is configured as 'expressions'.
 [#13142](https://github.com/Kong/kong/issues/13142)


- Fixed an issue where setting `tls_verify` to `false` didn't override the global level `proxy_ssl_verify`.
 [#13470](https://github.com/Kong/kong/issues/13470)


- Fixed an issue where the sni cache isn't invalidated when a sni is updated.
 [#13165](https://github.com/Kong/kong/issues/13165)


- The kong.logrotate configuration file will no longer be overwritten during upgrade.
When upgrading, set the environment variable `DEBIAN_FRONTEND=noninteractive` on Debian/Ubuntu to avoid any interactive prompts and enable fully automatic upgrades.
 [#13348](https://github.com/Kong/kong/issues/13348)


- Fixed an issue where the Vault secret cache got refreshed during `resurrect_ttl` time and could not be fetched by other workers.
 [#13561](https://github.com/Kong/kong/issues/13561)


- Error logs during Vault secret rotation are now logged at the `notice` level instead of `warn`.
 [#13540](https://github.com/Kong/kong/issues/13540)


- Fix a bug that the `host_header` attribute of upstream entity can not be set correctly in requests to upstream as Host header when retries to upstream happen.
 [#13135](https://github.com/Kong/kong/issues/13135)


- Moved internal Unix sockets to a subdirectory (`sockets`) of the Kong prefix.
 [#13409](https://github.com/Kong/kong/issues/13409)


- Changed the behaviour of shorthand fields that are used to describe deprecated fields. If
both fields are sent in the request and their values mismatch - the request will be rejected.
 [#13594](https://github.com/Kong/kong/issues/13594)


- Reverted DNS client to original behaviour of ignoring ADDITIONAL SECTION in DNS responses.
 [#13278](https://github.com/Kong/kong/issues/13278)


- Shortened names of internal Unix sockets to avoid exceeding the socket name limit.
 [#13571](https://github.com/Kong/kong/issues/13571)

##### PDK

- **PDK**: Fixed a bug that log serializer will log `upstream_status` as nil in the requests that contains subrequest
 [#12953](https://github.com/Kong/kong/issues/12953)


- **Vault**: Reference ending with slash when parsed should not return a key.
 [#13538](https://github.com/Kong/kong/issues/13538)


- Fixed an issue that pdk.log.serialize() will throw an error when JSON entity set by serialize_value contains json.null
 [#13376](https://github.com/Kong/kong/issues/13376)

##### Plugin

- **AI-proxy-plugin**: Fixed a bug where certain Azure models would return partial tokens/words
when in response-streaming mode.
 [#13000](https://github.com/Kong/kong/issues/13000)


- **AI-Transformer-Plugins**: Fixed a bug where cloud identity authentication
was not used in `ai-request-transformer` and `ai-response-transformer` plugins.
 [#13487](https://github.com/Kong/kong/issues/13487)


- **AI-proxy-plugin**: Fixed a bug where Cohere and Anthropic providers don't read the `model` parameter properly
from the caller's request body.
 [#13000](https://github.com/Kong/kong/issues/13000)


- **AI-proxy-plugin**: Fixed a bug where using "OpenAI Function" inference requests would log a
request error, and then hang until timeout.
 [#13000](https://github.com/Kong/kong/issues/13000)


- **AI-proxy-plugin**: Fixed a bug where AI Proxy would still allow callers to specify their own model,
ignoring the plugin-configured model name.
 [#13000](https://github.com/Kong/kong/issues/13000)


- **AI-proxy-plugin**: Fixed a bug where AI Proxy would not take precedence of the
plugin's configured model tuning options, over those in the user's LLM request.
 [#13000](https://github.com/Kong/kong/issues/13000)


- **AI-proxy-plugin**: Fixed a bug where setting OpenAI SDK model parameter "null" caused analytics
to not be written to the logging plugin(s).
 [#13000](https://github.com/Kong/kong/issues/13000)


- **ACME**: Fixed an issue of DP reporting that deprecated config fields are used when configuration from CP is pushed
 [#13069](https://github.com/Kong/kong/issues/13069)


- **ACME**: Fixed an issue where username and password were not accepted as valid authentication methods.
 [#13496](https://github.com/Kong/kong/issues/13496)


- **AI-Proxy**: Fixed issue when response is gzipped even if client doesn't accept.
 [#13155](https://github.com/Kong/kong/issues/13155)

- **Prometheus**: Fixed an issue where CP/DP compatibility check was missing for the new configuration field `ai_metrics`.
 [#13417](https://github.com/Kong/kong/issues/13417)


- Fixed certain AI plugins cannot be applied per consumer or per service.
 [#13209](https://github.com/Kong/kong/issues/13209)

- **AI-Prompt-Guard**: Fixed an issue when `allow_all_conversation_history` is set to false, the first user request is selected instead of the last one.
 [#13183](https://github.com/Kong/kong/issues/13183)

- **AI-Proxy**: Resolved a bug where the object constructor would set data on the class instead of the instance
 [#13028](https://github.com/Kong/kong/issues/13028)

- **AWS-Lambda**: Fixed an issue that the plugin does not work with multiValueHeaders defined in proxy integration and legacy empty_arrays_mode.
 [#12971](https://github.com/Kong/kong/issues/12971)

- **AWS-Lambda**: Fixed an issue that the `version` field is not set in the request payload when `awsgateway_compatible` is enabled.
 [#13018](https://github.com/Kong/kong/issues/13018)


- **correlation-id**: Fixed an issue where the plugin would not work if we explicitly set the `generator` to `null`.
 [#13439](https://github.com/Kong/kong/issues/13439)


- **CORS**: Fixed an issue where the `Access-Control-Allow-Origin` header was not sent when `conf.origins` has multiple entries but includes `*`.
 [#13334](https://github.com/Kong/kong/issues/13334)


- **grpc-gateway**: When there is a JSON decoding error, respond with status 400 and error information in the body instead of status 500.
 [#12971](https://github.com/Kong/kong/issues/12971)


- **HTTP-Log**: Fix an issue where the plugin doesn't include port information in the HTTP host header when sending requests to the log server.
 [#13116](https://github.com/Kong/kong/issues/13116)

- "**AI Plugins**: Fixed an issue for multi-modal inputs are not properly validated and calculated.
 [#13445](https://github.com/Kong/kong/issues/13445)


- **OpenTelemetry:** Fixed an issue where migration fails when upgrading from below version 3.3 to 3.7.
 [#13391](https://github.com/Kong/kong/issues/13391)


- **OpenTelemetry / Zipkin**: remove redundant deprecation warnings
 [#13220](https://github.com/Kong/kong/issues/13220)


- **Basic-Auth**: Fix an issue of realm field not recognized for older kong versions (before 3.6)
 [#13042](https://github.com/Kong/kong/issues/13042)


- **Key-Auth**: Fix an issue of realm field not recognized for older kong versions (before 3.7)
 [#13042](https://github.com/Kong/kong/issues/13042)


- **Request Size Limiting**: Fixed an issue where the body size doesn't get checked when the request body is buffered to a temporary file.
 [#13303](https://github.com/Kong/kong/issues/13303)


- **Response-RateLimiting**: Fixed an issue of DP reporting that deprecated config fields are used when configuration from CP is pushed
 [#13069](https://github.com/Kong/kong/issues/13069)


- **Rate-Limiting**: Fixed an issue of DP reporting that deprecated config fields are used when configuration from CP is pushed
 [#13069](https://github.com/Kong/kong/issues/13069)


- **OpenTelemetry:** Improved accuracy of sampling decisions.
 [#13275](https://github.com/Kong/kong/issues/13275)


- **hmac-auth**: Add WWW-Authenticate headers to 401 responses.
 [#11791](https://github.com/Kong/kong/issues/11791)


- **Prometheus**: Improved error logging when having inconsistent labels count.
 [#13020](https://github.com/Kong/kong/issues/13020)


- **jwt**: Add WWW-Authenticate headers to 401 responses.
 [#11792](https://github.com/Kong/kong/issues/11792)


- **ldap-auth**: Add WWW-Authenticate headers to all 401 responses.
 [#11820](https://github.com/Kong/kong/issues/11820)


- **OAuth2**: Add WWW-Authenticate headers to all 401 responses and realm option.
 [#11833](https://github.com/Kong/kong/issues/11833)


- **proxy-cache**: Fixed an issue where the Age header was not being updated correctly when serving cached responses.
 [#13387](https://github.com/Kong/kong/issues/13387)


- Fixed an bug that AI semantic cache can't use request provided models
 [#13633](https://github.com/Kong/kong/issues/13633)

##### Admin API

- Fixed an issue where validation of the certificate schema failed if the `snis` field was present in the request body.
 [#13357](https://github.com/Kong/kong/issues/13357)

##### Clustering

- Fixed an issue where hybrid mode not working if the forward proxy password contains special character(#). Note that the `proxy_server` configuration parameter still needs to be url-encoded.
 [#13457](https://github.com/Kong/kong/issues/13457)

##### Default

- **AI-proxy**: A configuration validation is added to prevent from enabling `log_statistics` upon
providers not supporting statistics. Accordingly, the default of `log_statistics` is changed from
`true` to `false`, and a database migration is added as well for disabling `log_statistics` if it
has already been enabled upon unsupported providers.
 [#12860](https://github.com/Kong/kong/issues/12860)

### Kong-Manager






#### Features
##### Default

- Improved accessibility in Kong Manager.
 [#13522](https://github.com/Kong/kong-manager/issues/13522)


- Enhanced entity lists so that you can resize or hide list columns.
 [#13522](https://github.com/Kong/kong-manager/issues/13522)


- Added an SNIs field to the certificate form.
 [#264](https://github.com/Kong/kong-manager/issues/264)


#### Fixes
##### Default

- Improved the user experience in Kong Manager by fixing various UI-related issues.
 [#232](https://github.com/Kong/kong-manager/issues/232) [#233](https://github.com/Kong/kong-manager/issues/233) [#234](https://github.com/Kong/kong-manager/issues/234) [#237](https://github.com/Kong/kong-manager/issues/237) [#238](https://github.com/Kong/kong-manager/issues/238) [#240](https://github.com/Kong/kong-manager/issues/240) [#244](https://github.com/Kong/kong-manager/issues/244) [#250](https://github.com/Kong/kong-manager/issues/250) [#252](https://github.com/Kong/kong-manager/issues/252) [#255](https://github.com/Kong/kong-manager/issues/255) [#257](https://github.com/Kong/kong-manager/issues/257) [#263](https://github.com/Kong/kong-manager/issues/263) [#264](https://github.com/Kong/kong-manager/issues/264) [#267](https://github.com/Kong/kong-manager/issues/267) [#272](https://github.com/Kong/kong-manager/issues/272)




## 3.7.1
### Kong

#### Performance

##### Performance

 - Fixed an inefficiency issue in the Luajit hashing algorithm
 [#13240](https://github.com/Kong/kong/issues/13240)

## 3.7.0
### Kong


#### Performance
##### Performance

- Improved proxy performance by refactoring internal hooking mechanism.
 [#12784](https://github.com/Kong/kong/issues/12784)

- Sped up the router matching when the `router_flavor` is `traditional_compatible` or `expressions`.
 [#12467](https://github.com/Kong/kong/issues/12467)
##### Plugin

- **Opentelemetry**: Increased queue max batch size to 200.
 [#12488](https://github.com/Kong/kong/issues/12488)

#### Breaking Changes
##### Plugin

- **AI Proxy**: To support the new messages API of `Anthropic`, the upstream path of the `Anthropic` for `llm/v1/chat` route type has changed from `/v1/complete` to `/v1/messages`.
 [#12699](https://github.com/Kong/kong/issues/12699)


#### Dependencies
##### Core

- Bumped atc-router from v1.6.0 to v1.6.2
 [#12231](https://github.com/Kong/kong/issues/12231)

- Bumped libexpat to 2.6.2
 [#12910](https://github.com/Kong/kong/issues/12910)

- Bumped lua-kong-nginx-module from 0.8.0 to 0.11.0
 [#12752](https://github.com/Kong/kong/issues/12752)

- Bumped lua-protobuf to 0.5.1
 [#12834](https://github.com/Kong/kong/issues/12834)


- Bumped lua-resty-acme to 0.13.0
 [#12909](https://github.com/Kong/kong/issues/12909)

- Bumped lua-resty-aws from 1.3.6 to 1.4.1
 [#12846](https://github.com/Kong/kong/issues/12846)

- Bumped lua-resty-lmdb from 1.4.1 to 1.4.2
 [#12786](https://github.com/Kong/kong/issues/12786)


- Bumped lua-resty-openssl from 1.2.0 to 1.3.1
 [#12665](https://github.com/Kong/kong/issues/12665)


- Bumped lua-resty-timer-ng to 0.2.7
 [#12756](https://github.com/Kong/kong/issues/12756)

- Bumped PCRE from the legacy libpcre 8.45 to libpcre2 10.43
 [#12366](https://github.com/Kong/kong/issues/12366)

- Bumped penlight to 1.14.0
 [#12862](https://github.com/Kong/kong/issues/12862)

##### Default

- Added package `tzdata` to DEB Docker image for convenient timezone setting.
 [#12609](https://github.com/Kong/kong/issues/12609)

- Bumped lua-resty-http to 0.17.2.
 [#12908](https://github.com/Kong/kong/issues/12908)


- Bumped LuaRocks from 3.9.2 to 3.11.0
 [#12662](https://github.com/Kong/kong/issues/12662)

- Bumped `ngx_wasm_module` to `91d447ffd0e9bb08f11cc69d1aa9128ec36b4526`
 [#12011](https://github.com/Kong/kong/issues/12011)


- Bumped `V8` version to `12.0.267.17`
 [#12704](https://github.com/Kong/kong/issues/12704)


- Bumped `Wasmtime` version to `19.0.0`
 [#12011](https://github.com/Kong/kong/issues/12011)


- Improved the robustness of lua-cjson when handling unexpected input.
 [#12904](https://github.com/Kong/kong/issues/12904)

#### Features
##### Configuration

- TLSv1.1 and lower versions are disabled by default in OpenSSL 3.x.
 [#12420](https://github.com/Kong/kong/issues/12420)

- Introduced `nginx_wasm_main_shm_kv` configuration parameter, which enables
Wasm filters to use the Proxy-Wasm operations `get_shared_data` and
`set_shared_data` without namespaced keys.
 [#12663](https://github.com/Kong/kong/issues/12663)


- **Schema**: Added a deprecation field attribute to identify deprecated fields
 [#12686](https://github.com/Kong/kong/issues/12686)

- Added the `wasm_filters` configuration parameter for enabling individual filters
 [#12843](https://github.com/Kong/kong/issues/12843)
##### Core

- Added `events:ai:response_tokens`, `events:ai:prompt_tokens` and `events:ai:requests` to the anonymous report to start counting AI usage
 [#12924](https://github.com/Kong/kong/issues/12924)


- Improved config handling when the CP runs with the router set to the `expressions` flavor:
  - If mixed config is detected and a lower DP is attached to the CP, no config will be sent at all
  - If the expression is invalid on the CP, no config will be sent at all
  - If the expression is invalid on a lower DP, it will be sent to the DP and DP validation will catch this and communicate back to the CP (this could result in partial config application)
 [#12967](https://github.com/Kong/kong/issues/12967)

- The route entity now supports the following fields when the
`router_flavor` is `expressions`: `methods`, `hosts`, `paths`, `headers`,
`snis`, `sources`, `destinations`, and `regex_priority`.
The meaning of these fields are consistent with the traditional route entity.
 [#12667](https://github.com/Kong/kong/issues/12667)
##### PDK

- Added the `latencies.receive` property to the log serializer
 [#12730](https://github.com/Kong/kong/issues/12730)
##### Plugin

- AI Proxy now reads most prompt tuning parameters from the client,
while the plugin config parameters under `model_options` are now just defaults.
This fixes support for using the respective provider's native SDK.
 [#12903](https://github.com/Kong/kong/issues/12903)

- AI Proxy now has a `preserve` option for `route_type`, where the requests and responses
are passed directly to the upstream LLM. This is to enable compatibility with any
and all models and SDKs that may be used when calling the AI services.
 [#12903](https://github.com/Kong/kong/issues/12903)

- **Prometheus**: Added workspace label to Prometheus plugin metrics.
 [#12836](https://github.com/Kong/kong/issues/12836)

- **AI Proxy**: Added support for streaming event-by-event responses back to the client on supported providers.
 [#12792](https://github.com/Kong/kong/issues/12792)

- **AI Prompt Guard**: Increased the maximum length of regex expressions to 500 for the allow and deny parameters.
 [#12731](https://github.com/Kong/kong/issues/12731)

- Addded support for EdDSA algorithms in JWT plugin
 [#12726](https://github.com/Kong/kong/issues/12726)


- Added support for ES512, PS256, PS384, PS512 algorithms in JWT plugin
 [#12638](https://github.com/Kong/kong/issues/12638)

- **OpenTelemetry, Zipkin**: The propagation module has been reworked. The new
options allow better control over the configuration of tracing headers propagation.
 [#12670](https://github.com/Kong/kong/issues/12670)
##### Default

- Added support for debugging with EmmyLuaDebugger.  This feature is a
tech preview and not officially supported by Kong Inc. for now.
 [#12899](https://github.com/Kong/kong/issues/12899)

#### Fixes
##### CLI Command

- Fixed an issue where the `pg_timeout` was overridden to `60s` even if `--db-timeout`
was not explicitly passed in CLI arguments.
 [#12981](https://github.com/Kong/kong/issues/12981)
##### Configuration

- Fixed the default value in kong.conf.default documentation from 1000 to 10000
for the `upstream_keepalive_max_requests` option.
 [#12643](https://github.com/Kong/kong/issues/12643)

- Fixed an issue where an external plugin (Go, Javascript, or Python) would fail to
apply a change to the plugin config via the Admin API.
 [#12718](https://github.com/Kong/kong/issues/12718)

- Disabled usage of the Lua DNS resolver from proxy-wasm by default.
 [#12825](https://github.com/Kong/kong/issues/12825)

- Set security level of gRPC's TLS to 0 when `ssl_cipher_suite` is set to `old`.
 [#12613](https://github.com/Kong/kong/issues/12613)
##### Core

- Fixed an issue where `POST /config?flatten_errors=1` could not return a proper response if the input included duplicate upstream targets.
 [#12797](https://github.com/Kong/kong/issues/12797)

- **DNS Client**: Ignore a non-positive values on resolv.conf for options timeout, and use a default value of 2 seconds instead.
 [#12640](https://github.com/Kong/kong/issues/12640)

- Updated the file permission of `kong.logrotate` to 644.
 [#12629](https://github.com/Kong/kong/issues/12629)

- Fixed a problem on hybrid mode DPs, where a certificate entity configured with a vault reference may not get refreshed on time.
 [#12868](https://github.com/Kong/kong/issues/12868)

- Fixed the missing router section for the output of the request-debugging.
 [#12234](https://github.com/Kong/kong/issues/12234)

- Fixed an issue in the internal caching logic where mutexes could get never unlocked.
 [#12743](https://github.com/Kong/kong/issues/12743)


- Fixed an issue where the router didn't work correctly
when the route's configuration changed.
 [#12654](https://github.com/Kong/kong/issues/12654)

- Fixed an issue where SNI-based routing didn't work
using `tls_passthrough` and the `traditional_compatible` router flavor.
 [#12681](https://github.com/Kong/kong/issues/12681)

- Fixed a bug that `X-Kong-Upstream-Status` didn't appear in the response headers even if it was set in the `headers` parameter in the `kong.conf` file when the response was hit and returned by the Proxy Cache plugin.
 [#12744](https://github.com/Kong/kong/issues/12744)

- Fixed vault initialization by postponing vault reference resolving on init_worker
 [#12554](https://github.com/Kong/kong/issues/12554)

- Fixed a bug that allowed vault secrets to refresh even when they had no TTL set.
 [#12877](https://github.com/Kong/kong/issues/12877)

- **Vault**: do not use incorrect (default) workspace identifier when retrieving vault entity by prefix
 [#12572](https://github.com/Kong/kong/issues/12572)

- **Core**: Fixed unexpected table nil panic in the balancer's stop_healthchecks function
 [#12865](https://github.com/Kong/kong/issues/12865)


- Use `-1` as the worker ID of privileged agent to avoid access issues.
 [#12385](https://github.com/Kong/kong/issues/12385)

- **Plugin Server**: Fixed an issue where Kong failed to properly restart MessagePack-based pluginservers (used in Python and Javascript plugins, for example).
 [#12582](https://github.com/Kong/kong/issues/12582)

- Reverted the hard-coded limitation of the `ngx.read_body()` API in OpenResty upstreams' new versions when downstream connections are in HTTP/2 or HTTP/3 stream modes.
 [#12658](https://github.com/Kong/kong/issues/12658)

- Each Kong cache instance now utilizes its own cluster event channel. This approach isolates cache invalidation events and reducing the generation of unnecessary worker events.
 [#12321](https://github.com/Kong/kong/issues/12321)

- Updated telemetry collection for AI Plugins to allow multiple plugins data to be set for the same request.
 [#12583](https://github.com/Kong/kong/issues/12583)
##### PDK

- **PDK:** Fixed `kong.request.get_forwarded_port` to always return a number,
which was caused by an incorrectly stored string value in `ngx.ctx.host_port`.
 [#12806](https://github.com/Kong/kong/issues/12806)

- The value of `latencies.kong` in the log serializer payload no longer includes
the response receive time, so it now has the same value as the
`X-Kong-Proxy-Latency` response header. Response receive time is recorded in
the new `latencies.receive` metric, so if desired, the old value can be
calculated as `latencies.kong + latencies.receive`. **Note:** this also
affects payloads from all logging plugins that use the log serializer:
`file-log`, `tcp-log`, `udp-log`,`http-log`, `syslog`, and `loggly`, e.g.
[descriptions of JSON objects for the HTTP Log Plugin's log format](https://docs.konghq.com/hub/kong-inc/http-log/log-format/#json-object-descriptions).
 [#12795](https://github.com/Kong/kong/issues/12795)

- **Tracing**: enhanced robustness of trace ID parsing
 [#12848](https://github.com/Kong/kong/issues/12848)
##### Plugin

- **AI-proxy-plugin**: Fixed the bug that the `route_type` `/llm/v1/chat` didn't include the analytics in the responses.
 [#12781](https://github.com/Kong/kong/issues/12781)

- **ACME**: Fixed an issue where the certificate was not successfully renewed during ACME renewal.
 [#12773](https://github.com/Kong/kong/issues/12773)

- **AWS-Lambda**: Fixed an issue where the latency attributed to AWS Lambda API requests was counted as part of the latency in Kong.
 [#12835](https://github.com/Kong/kong/issues/12835)

- **Jwt**: Fixed an issue where the plugin would fail when using invalid public keys for ES384 and ES512 algorithms.
 [#12724](https://github.com/Kong/kong/issues/12724)


- Added WWW-Authenticate headers to all 401 responses in the Key Auth plugin.
 [#11794](https://github.com/Kong/kong/issues/11794)

- **Opentelemetry**: Fixed an OTEL sampling mode Lua panic bug, which happened when the `http_response_header_for_traceid` option was enabled.
 [#12544](https://github.com/Kong/kong/issues/12544)

- Improve error handling in AI plugins.
 [#12991](https://github.com/Kong/kong/issues/12991)

- **ACME**: Fixed migration of redis configuration.
 [#12989](https://github.com/Kong/kong/issues/12989)

- **Response-RateLimiting**: Fixed migration of redis configuration.
 [#12989](https://github.com/Kong/kong/issues/12989)

- **Rate-Limiting**: Fixed migration of redis configuration.
 [#12989](https://github.com/Kong/kong/issues/12989)
##### Admin API

- **Admin API**: fixed an issue where calling the endpoint `POST /schemas/vaults/validate` was conflicting with the endpoint `/schemas/vaults/:name` which only has GET implemented, hence resulting in a 405.
 [#12607](https://github.com/Kong/kong/issues/12607)
##### Default

- Fixed a bug where, if the the ulimit setting (open files) was low, Kong would fail to start as the `lua-resty-timer-ng` exhausted the available `worker_connections`. Decreased the concurrency range of the `lua-resty-timer-ng` library from `[512, 2048]` to `[256, 1024]` to fix this bug.
 [#12606](https://github.com/Kong/kong/issues/12606)

- Fix an issue where external plugins using the protobuf-based protocol would fail to call the `kong.Service.SetUpstream` method with an error `bad argument #2 to 'encode' (table expected, got boolean)`.
 [#12727](https://github.com/Kong/kong/issues/12727)

### Kong-Manager






#### Features
##### Default

- Kong Manager now supports creating and editing Expressions routes with an interactive in-browser editor with syntax highlighting and autocompletion features for Kong's Expressions language.
 [#217](https://github.com/Kong/kong-manager/issues/217)


- Kong Manager now groups the parameters to provide a better user experience while configuring plugins. Meanwhile, several issues with the plugin form page were fixed.
 [#195](https://github.com/Kong/kong-manager/issues/195) [#199](https://github.com/Kong/kong-manager/issues/199) [#201](https://github.com/Kong/kong-manager/issues/201) [#202](https://github.com/Kong/kong-manager/issues/202) [#207](https://github.com/Kong/kong-manager/issues/207) [#208](https://github.com/Kong/kong-manager/issues/208) [#209](https://github.com/Kong/kong-manager/issues/209) [#213](https://github.com/Kong/kong-manager/issues/213) [#216](https://github.com/Kong/kong-manager/issues/216)


#### Fixes
##### Default

- Improved the user experience in Kong Manager by fixing various UI-related issues.
 [#185](https://github.com/Kong/kong-manager/issues/185) [#188](https://github.com/Kong/kong-manager/issues/188) [#190](https://github.com/Kong/kong-manager/issues/190) [#195](https://github.com/Kong/kong-manager/issues/195) [#199](https://github.com/Kong/kong-manager/issues/199) [#201](https://github.com/Kong/kong-manager/issues/201) [#202](https://github.com/Kong/kong-manager/issues/202) [#207](https://github.com/Kong/kong-manager/issues/207) [#208](https://github.com/Kong/kong-manager/issues/208) [#209](https://github.com/Kong/kong-manager/issues/209) [#213](https://github.com/Kong/kong-manager/issues/213) [#216](https://github.com/Kong/kong-manager/issues/216)

## 3.6.1

### Kong


#### Performance
##### Plugin

- **Opentelemetry**: increase queue max batch size to 200
 [#12542](https://github.com/Kong/kong/issues/12542)



#### Dependencies
##### Core

- Bumped lua-resty-openssl to 1.2.1
 [#12669](https://github.com/Kong/kong/issues/12669)


#### Features
##### Configuration

- now TLSv1.1 and lower is by default disabled in OpenSSL 3.x
 [#12556](https://github.com/Kong/kong/issues/12556)

#### Fixes
##### Configuration

- Fixed default value in kong.conf.default documentation from 1000 to 10000
for upstream_keepalive_max_requests option.
 [#12648](https://github.com/Kong/kong/issues/12648)

- Set security level of gRPC's TLS to 0 when ssl_cipher_suite is set to old
 [#12616](https://github.com/Kong/kong/issues/12616)

##### Core

- Fix the missing router section for the output of the request-debugging
 [#12649](https://github.com/Kong/kong/issues/12649)

- revert the hard-coded limitation of the ngx.read_body() API in OpenResty upstreams' new versions when downstream connections are in HTTP/2 or HTTP/3 stream modes.
 [#12666](https://github.com/Kong/kong/issues/12666)
##### Default

- Fix a bug where the ulimit setting (open files) is low Kong will fail to start as the lua-resty-timer-ng exhausts the available worker_connections. Decrease the concurrency range of the lua-resty-timer-ng library from [512, 2048] to [256, 1024] to fix this bug.
 [#12608](https://github.com/Kong/kong/issues/12608)
### Kong-Manager

## 3.6.0

### Kong


#### Performance
##### Performance

- Bumped the concurrency range of the lua-resty-timer-ng library from [32, 256] to [512, 2048].
 [#12275](https://github.com/Kong/kong/issues/12275)

- Cooperatively yield when building statistics of routes to reduce the impact to proxy path latency.
 [#12013](https://github.com/Kong/kong/issues/12013)

##### Configuration

- Bump `dns_stale_ttl` default to 1 hour so stale DNS record can be used for longer time in case of resolver downtime.
 [#12087](https://github.com/Kong/kong/issues/12087)

- Bumped default values of `nginx_http_keepalive_requests` and `upstream_keepalive_max_requests` to `10000`. These changes are optimized to work better in systems with high throughput. In a low-throughput setting, these new settings may have visible effects in loadbalancing - it can take more requests to start using all the upstreams than before.
 [#12223](https://github.com/Kong/kong/issues/12223)
##### Core

- Reuse match context between requests to avoid frequent memory allocation/deallocation
 [#12258](https://github.com/Kong/kong/issues/12258)
##### PDK

- Performance optimization to avoid unnecessary creations and garbage-collections of spans
 [#12080](https://github.com/Kong/kong/issues/12080)

#### Breaking Changes
##### Core

- **BREAKING:** To avoid ambiguity with other Wasm-related nginx.conf directives, the prefix for Wasm `shm_kv` nginx.conf directives was changed from `nginx_wasm_shm_` to `nginx_wasm_shm_kv_`
 [#11919](https://github.com/Kong/kong/issues/11919)

- In OpenSSL 3.2, the default SSL/TLS security level has been changed from 1 to 2.
  Which means security level set to 112 bits of security. As a result
  RSA, DSA and DH keys shorter than 2048 bits and ECC keys shorter than
  224 bits are prohibited. In addition to the level 1 exclusions any cipher
  suite using RC4 is also prohibited. SSL version 3 is also not allowed.
  Compression is disabled.
  [#7714](https://github.com/Kong/kong/issues/7714)

##### Plugin

- **azure-functions**: azure-functions plugin now eliminates upstream/request URI and only use `routeprefix` configuration field to construct request path when requesting Azure API
 [#11850](https://github.com/Kong/kong/issues/11850)

#### Deprecations
##### Plugin

- **ACME**: Standardize redis configuration across plugins. The redis configuration right now follows common schema that is shared across other plugins.
 [#12300](https://github.com/Kong/kong/issues/12300)

- **Rate Limiting**: Standardize redis configuration across plugins. The redis configuration right now follows common schema that is shared across other plugins.
 [#12301](https://github.com/Kong/kong/issues/12301)

- **Response-RateLimiting**: Standardize redis configuration across plugins. The redis configuration right now follows common schema that is shared across other plugins.
 [#12301](https://github.com/Kong/kong/issues/12301)

#### Dependencies
##### Core

- Bumped atc-router from 1.2.0 to 1.6.0
 [#12231](https://github.com/Kong/kong/issues/12231)

- Bumped kong-lapis from 1.14.0.3 to 1.16.0.1
 [#12064](https://github.com/Kong/kong/issues/12064)


- Bumped LPEG from 1.0.2 to 1.1.0
 [#11955](https://github.com/Kong/kong/issues/11955)
 [UTF-8](https://konghq.atlassian.net/browse/UTF-8)

- Bumped lua-messagepack from 0.5.2 to 0.5.3
 [#11956](https://github.com/Kong/kong/issues/11956)


- Bumped lua-messagepack from 0.5.3 to 0.5.4
 [#12076](https://github.com/Kong/kong/issues/12076)


- Bumped lua-resty-aws from 1.3.5 to 1.3.6
 [#12439](https://github.com/Kong/kong/issues/12439)


- Bumped lua-resty-healthcheck from 3.0.0 to 3.0.1
 [#12237](https://github.com/Kong/kong/issues/12237)

- Bumped lua-resty-lmdb from 1.3.0 to 1.4.1
 [#12026](https://github.com/Kong/kong/issues/12026)

- Bumped lua-resty-timer-ng from 0.2.5 to 0.2.6
 [#12275](https://github.com/Kong/kong/issues/12275)

- Bumped OpenResty from 1.21.4.2 to 1.25.3.1
 [#12327](https://github.com/Kong/kong/issues/12327)

- Bumped OpenSSL from 3.1.4 to 3.2.1
 [#12264](https://github.com/Kong/kong/issues/12264)

- Bump resty-openssl from 0.8.25 to 1.2.0
 [#12265](https://github.com/Kong/kong/issues/12265)


- Bumped ngx_brotli to master branch, and disabled it on rhel7 rhel9-arm64 and amazonlinux-2023-arm64 due to toolchain issues
 [#12444](https://github.com/Kong/kong/issues/12444)

- Bumped lua-resty-healthcheck from 1.6.3 to 3.0.0
 [#11834](https://github.com/Kong/kong/issues/11834)
##### Default

- Bump `ngx_wasm_module` to `a7087a37f0d423707366a694630f1e09f4c21728`
 [#12011](https://github.com/Kong/kong/issues/12011)


- Bump `Wasmtime` version to `14.0.3`
 [#12011](https://github.com/Kong/kong/issues/12011)


#### Features
##### Configuration

- display a warning message when Kong Manager is enabled but the Admin API is not enabled
 [#12071](https://github.com/Kong/kong/issues/12071)

- add DHE-RSA-CHACHA20-POLY1305 cipher to the intermediate configuration
 [#12133](https://github.com/Kong/kong/issues/12133)

- The default value of `dns_no_sync` option has been changed to `off`
 [#11869](https://github.com/Kong/kong/issues/11869)

- Allow to inject Nginx directives into Kong's proxy location block
 [#11623](https://github.com/Kong/kong/issues/11623)


- Validate LMDB cache by Kong's version (major + minor),
wiping the content if tag mismatch to avoid compatibility issues
during minor version upgrade.
 [#12026](https://github.com/Kong/kong/issues/12026)
##### Core

- Adds telemetry collection for AI Proxy, AI Request Transformer, and AI Response Transformer, pertaining to model and provider usage.
 [#12495](https://github.com/Kong/kong/issues/12495)


- add ngx_brotli module to kong prebuild nginx
 [#12367](https://github.com/Kong/kong/issues/12367)

- Allow primary key passed as a full entity to DAO functions.
 [#11695](https://github.com/Kong/kong/issues/11695)


- Build deb packages for Debian 12. The debian variant of kong docker image is built using Debian 12 now.
 [#12218](https://github.com/Kong/kong/issues/12218)

- The expressions route now supports the `!` (not) operator, which allows creating routes like
`!(http.path =^ "/a")` and `!(http.path == "/a" || http.path == "/b")`
 [#12419](https://github.com/Kong/kong/issues/12419)

- Add `source` property to log serializer, indicating the response is generated by `kong` or `upstream`.
 [#12052](https://github.com/Kong/kong/issues/12052)

- Ensure Kong-owned directories are cleaned up after an uninstall using the system's package manager.
 [#12162](https://github.com/Kong/kong/issues/12162)

- Support `http.path.segments.len` and `http.path.segments.*` fields in the expressions router
which allows matching incoming (normalized) request path by individual segment or ranges of segments,
plus checking the total number of segments.
 [#12283](https://github.com/Kong/kong/issues/12283)

- `net.src.*` and `net.dst.*` match fields are now accessible in HTTP routes defined using expressions.
 [#11950](https://github.com/Kong/kong/issues/11950)

- Extend support for getting and setting Gateway values via proxy-wasm properties in the `kong.*` namespace.
 [#11856](https://github.com/Kong/kong/issues/11856)

##### PDK

- Increase the precision of JSON number encoding from 14 to 16 decimals
 [#12019](https://github.com/Kong/kong/issues/12019)
##### Plugin

- Introduced the new **AI Prompt Decorator** plugin that enables prepending and appending llm/v1/chat messages onto consumer LLM requests, for prompt tuning.
 [#12336](https://github.com/Kong/kong/issues/12336)


- Introduced the new **AI Prompt Guard** which can allow and/or block  LLM requests based on pattern matching.
 [#12427](https://github.com/Kong/kong/issues/12427)


- Introduced the new **AI Prompt Template** which can offer consumers and array of LLM prompt templates, with variable substitutions.
 [#12340](https://github.com/Kong/kong/issues/12340)


- Introduced the new **AI Proxy** plugin that enables simplified integration with various AI provider Large Language Models.
 [#12323](https://github.com/Kong/kong/issues/12323)


- Introduced the new **AI Request Transformer** plugin that enables passing mid-flight consumer requests to an LLM for transformation or sanitization.
 [#12426](https://github.com/Kong/kong/issues/12426)


- Introduced the new **AI Response Transformer** plugin that enables passing mid-flight upstream responses to an LLM for transformation or sanitization.
 [#12426](https://github.com/Kong/kong/issues/12426)


- Tracing Sampling Rate can now be set via the `config.sampling_rate` property of the OpenTelemetry plugin instead of it just being a global setting for the gateway.
 [#12054](https://github.com/Kong/kong/issues/12054)
##### Admin API

- add gateway edition to the root endpoint of the admin api
 [#12097](https://github.com/Kong/kong/issues/12097)

- Enable `status_listen` on `127.0.0.1:8007` by default
 [#12304](https://github.com/Kong/kong/issues/12304)
##### Clustering

- **Clustering**: Expose data plane certificate expiry date on the control plane API.
 [#11921](https://github.com/Kong/kong/issues/11921)

#### Fixes
##### Configuration

- fix error data loss caused by weakly typed of function in declarative_config_flattened function
 [#12167](https://github.com/Kong/kong/issues/12167)

- respect custom `proxy_access_log`
 [#12073](https://github.com/Kong/kong/issues/12073)
##### Core

- prevent ca to be deleted when it's still referenced by other entities and invalidate the related ca store caches when a ca cert is updated.
 [#11789](https://github.com/Kong/kong/issues/11789)

- Now cookie names are validated against RFC 6265, which allows more characters than the previous validation.
 [#11881](https://github.com/Kong/kong/issues/11881)


- Remove nulls only if the schema has transformations definitions.
Improve performance as most schemas does not define transformations.
 [#12284](https://github.com/Kong/kong/issues/12284)

- Fix a bug that the error_handler can not provide the meaningful response body when the internal error code 494 is triggered.
 [#12114](https://github.com/Kong/kong/issues/12114)

- Header value matching (`http.headers.*`) in `expressions` router flavor are now case sensitive.
This change does not affect on `traditional_compatible` mode
where header value match are always performed ignoring the case.
 [#11905](https://github.com/Kong/kong/issues/11905)

- print error message correctly when plugin fails
 [#11800](https://github.com/Kong/kong/issues/11800)

- fix ldoc intermittent failure caused by LuaJIT error.
 [#11983](https://github.com/Kong/kong/issues/11983)

- use NGX_WASM_MODULE_BRANCH environment variable to set ngx_wasm_module repository branch when building Kong.
 [#12241](https://github.com/Kong/kong/issues/12241)

- Eliminate asynchronous timer in syncQuery() to prevent hang risk
 [#11900](https://github.com/Kong/kong/issues/11900)

- **tracing:** Fixed an issue where a DNS query failure would cause a tracing failure.
 [#11935](https://github.com/Kong/kong/issues/11935)

- Expressions route in `http` and `stream` subsystem now have stricter validation.
Previously they share the same validation schema which means admin can configure expressions
route using fields like `http.path` even for stream routes. This is no longer allowed.
 [#11914](https://github.com/Kong/kong/issues/11914)

- **Tracing**: dns spans are now correctly generated for upstream dns queries (in addition to cosocket ones)
 [#11996](https://github.com/Kong/kong/issues/11996)

- Validate private and public key for `keys` entity to ensure they match each other.
 [#11923](https://github.com/Kong/kong/issues/11923)

- **proxy-wasm**: Fixed "previous plan already attached" error thrown when a filter triggers re-entrancy of the access handler.
 [#12452](https://github.com/Kong/kong/issues/12452)
##### PDK

- response.set_header support header argument with table array of string
 [#12164](https://github.com/Kong/kong/issues/12164)

- Fix an issue that when using kong.response.exit, the Transfer-Encoding header set by user is not removed
 [#11936](https://github.com/Kong/kong/issues/11936)

- **Plugin Server**: fix an issue where every request causes a new plugin instance to be created
 [#12020](https://github.com/Kong/kong/issues/12020)
##### Plugin

- Add missing WWW-Authenticate headers to 401 response in basic auth plugin.
 [#11795](https://github.com/Kong/kong/issues/11795)

- Enhance error responses for authentication failures in the Admin API
 [#12456](https://github.com/Kong/kong/issues/12456)

- Expose metrics for serviceless routes
 [#11781](https://github.com/Kong/kong/issues/11781)

- **Rate Limiting**: fix to provide better accuracy in counters when sync_rate is used with the redis policy.
 [#11859](https://github.com/Kong/kong/issues/11859)

- **Rate Limiting**: fix an issuer where all counters are synced to the same DB at the same rate.
 [#12003](https://github.com/Kong/kong/issues/12003)

- **Datadog**: Fix a bug that datadog plugin is not triggered for serviceless routes. In this fix, datadog plugin is always triggered, and the value of tag `name`(service_name) is set as an empty value.
 [#12068](https://github.com/Kong/kong/issues/12068)
##### Clustering

- Fix a bug causing data-plane status updates to fail when an empty PING frame is received from a data-plane
 [#11917](https://github.com/Kong/kong/issues/11917)
### Kong-Manager






#### Features
##### Default

- Added a JSON/YAML format preview for all entity forms.
 [#157](https://github.com/Kong/kong-manager/issues/157)


- Adopted resigned basic components for better UI/UX.
 [#131](https://github.com/Kong/kong-manager/issues/131) [#166](https://github.com/Kong/kong-manager/issues/166)


- Kong Manager and Konnect now share the same UI for plugin selection page and plugin form page.
 [#143](https://github.com/Kong/kong-manager/issues/143) [#147](https://github.com/Kong/kong-manager/issues/147)


#### Fixes
##### Default

- Standardized notification text format.
 [#140](https://github.com/Kong/kong-manager/issues/140)

## 3.5.0
### Kong


#### Performance
##### Configuration

- Bumped the default value of `upstream_keepalive_pool_size` to `512` and `upstream_keepalive_max_requests` to `1000`
  [#11515](https://github.com/Kong/kong/issues/11515)
##### Core

- refactor workspace id and name retrieval
  [#11442](https://github.com/Kong/kong/issues/11442)

#### Breaking Changes
##### Plugin

- **Session**: a new configuration field `read_body_for_logout` was added with a default value of `false`, that changes behavior of `logout_post_arg` in a way that it is not anymore considered if the `read_body_for_logout` is not explicitly set to `true`. This is to avoid session plugin from reading request bodies by default on e.g. `POST` request for logout detection.
  [#10333](https://github.com/Kong/kong/issues/10333)


#### Dependencies
##### Core

- Bumped resty.openssl from 0.8.23 to 0.8.25
  [#11518](https://github.com/Kong/kong/issues/11518)

- Fix incorrect LuaJIT register allocation for IR_*LOAD on ARM64
  [#11638](https://github.com/Kong/kong/issues/11638)

- Fix LDP/STP fusing for unaligned accesses on ARM64
  [#11639](https://github.com/Kong/kong/issues/11639)


- Bump lua-kong-nginx-module from 0.6.0 to 0.8.0
  [#11663](https://github.com/Kong/kong/issues/11663)

- Fix incorrect LuaJIT LDP/STP fusion on ARM64 which may sometimes cause incorrect logic
  [#11537](https://github.com/Kong/kong/issues/11537)

##### Default

- Bumped lua-resty-healthcheck from 1.6.2 to 1.6.3
  [#11360](https://github.com/Kong/kong/issues/11360)

- Bumped OpenResty from 1.21.4.1 to 1.21.4.2
  [#11360](https://github.com/Kong/kong/issues/11360)

- Bumped LuaSec from 1.3.1 to 1.3.2
  [#11553](https://github.com/Kong/kong/issues/11553)


- Bumped lua-resty-aws from 1.3.1 to 1.3.5
  [#11613](https://github.com/Kong/kong/issues/11613)


- bump OpenSSL from 3.1.1 to 3.1.4
  [#11844](https://github.com/Kong/kong/issues/11844)


- Bumped kong-lapis from 1.14.0.2 to 1.14.0.3
  [#11849](https://github.com/Kong/kong/issues/11849)


- Bumped ngx_wasm_module to latest rolling release version.
  [#11678](https://github.com/Kong/kong/issues/11678)

- Bump Wasmtime version to 12.0.2
  [#11738](https://github.com/Kong/kong/issues/11738)

- Bumped lua-resty-aws from 1.3.0 to 1.3.1
  [#11419](https://github.com/Kong/kong/pull/11419)

- Bumped lua-resty-session from 4.0.4 to 4.0.5
  [#11416](https://github.com/Kong/kong/pull/11416)


#### Features
##### Core

- Add a new endpoint `/schemas/vaults/:name` to retrieve the schema of a vault.
  [#11727](https://github.com/Kong/kong/issues/11727)

- rename `privileged_agent` to `dedicated_config_processing. Enable `dedicated_config_processing` by default
  [#11784](https://github.com/Kong/kong/issues/11784)

- Support observing the time consumed by some components in the given request.
  [#11627](https://github.com/Kong/kong/issues/11627)

- Plugins can now implement `Plugin:configure(configs)` function that is called whenever there is a change in plugin entities. An array of current plugin configurations is passed to the function, or `nil` in case there is no active configurations for the plugin.
  [#11703](https://github.com/Kong/kong/issues/11703)

- Add a request-aware table able to detect accesses from different requests.
  [#11017](https://github.com/Kong/kong/issues/11017)

- A unique Request ID is now populated in the error log, access log, error templates, log serializer, and in a new X-Kong-Request-Id header (configurable for upstream/downstream using the `headers` and `headers_upstream` configuration options).
  [#11663](https://github.com/Kong/kong/issues/11663)

- Add support for optional Wasm filter configuration schemas
  [#11568](https://github.com/Kong/kong/issues/11568)

- Support JSON in Wasm filter configuration
  [#11697](https://github.com/Kong/kong/issues/11697)

- Support HTTP query parameters in expression routes.
  [#11348](https://github.com/Kong/kong/pull/11348)

##### Plugin

- **response-ratelimiting**: add support for secret rotation with redis connection
  [#10570](https://github.com/Kong/kong/issues/10570)


- **CORS**: Support the `Access-Control-Request-Private-Network` header in crossing-origin pre-light requests
  [#11523](https://github.com/Kong/kong/issues/11523)

- add scan_count to redis storage schema
  [#11532](https://github.com/Kong/kong/issues/11532)


- **AWS-Lambda**: the AWS-Lambda plugin has been refactored by using `lua-resty-aws` as an
  underlying AWS library. The refactor simplifies the AWS-Lambda plugin code base and
  adding support for multiple IAM authenticating scenarios.
  [#11350](https://github.com/Kong/kong/pull/11350)

- **OpenTelemetry** and **Zipkin**: Support GCP X-Cloud-Trace-Context header
  The field `header_type` now accepts the value `gcp` to propagate the
  Google Cloud trace header
  [#11254](https://github.com/Kong/kong/pull/11254)

##### Clustering

- **Clustering**: Allow configuring DP metadata labels for on-premise CP Gateway
  [#11625](https://github.com/Kong/kong/issues/11625)

#### Fixes
##### Configuration

- The default value of `dns_no_sync` option has been changed to `on`
  [#11871](https://github.com/Kong/kong/issues/11871)

##### Core

- Fix an issue that the TTL of the key-auth plugin didnt work in DB-less and Hybrid mode.
  [#11464](https://github.com/Kong/kong/issues/11464)

- Fix a problem that abnormal socket connection will be reused when querying Postgres database.
  [#11480](https://github.com/Kong/kong/issues/11480)

- Fix upstream ssl failure when plugins use response handler
  [#11502](https://github.com/Kong/kong/issues/11502)

- Fix an issue that protocol `tls_passthrough` can not work with expressions flavor
  [#11538](https://github.com/Kong/kong/issues/11538)

- Fix a bug that will cause a failure of sending tracing data to datadog when value of x-datadog-parent-id header in requests is a short dec string
  [#11599](https://github.com/Kong/kong/issues/11599)

- Apply Nginx patch for detecting HTTP/2 stream reset attacks early (CVE-2023-44487)
  [#11743](https://github.com/Kong/kong/issues/11743)

- fix the building failure when applying patches
  [#11696](https://github.com/Kong/kong/issues/11696)

- Vault references can be used in Dbless mode in declarative config
  [#11845](https://github.com/Kong/kong/issues/11845)


- Properly warmup Vault caches on init
  [#11827](https://github.com/Kong/kong/issues/11827)


- Vault resurrect time is respected in case a vault secret is deleted from a vault
  [#11852](https://github.com/Kong/kong/issues/11852)

- Fixed critical level logs when starting external plugin servers. Those logs cannot be suppressed due to the limitation of OpenResty. We choose to remove the socket availability detection feature.
  [#11372](https://github.com/Kong/kong/pull/11372)

- Fix an issue where a crashing Go plugin server process would cause subsequent
  requests proxied through Kong to execute Go plugins with inconsistent configurations.
  The issue only affects scenarios where the same Go plugin is applied to different Route
  or Service entities.
  [#11306](https://github.com/Kong/kong/pull/11306)

- Fix an issue where cluster_cert or cluster_ca_cert is inserted into lua_ssl_trusted_certificate before being base64 decoded.
  [#11385](https://github.com/Kong/kong/pull/11385)

- Fix cache warmup mechanism not working in `acls` plugin groups config entity scenario.
  [#11414](https://github.com/Kong/kong/pull/11414)

- Fix an issue that queue stops processing when a hard error is encountered in the handler function.
  [#11423](https://github.com/Kong/kong/pull/11423)

- Fix an issue that query parameters are not forwarded in proxied request.
  Thanks [@chirag-manwani](https://github.com/chirag-manwani) for contributing this change.
  [#11328](https://github.com/Kong/kong/pull/11328)

- Fix an issue that response status code is not real upstream status when using kong.response function.
  [#11437](https://github.com/Kong/kong/pull/11437)

- Removed a hardcoded proxy-wasm isolation level setting that was preventing the
  `nginx_http_proxy_wasm_isolation` configuration value from taking effect.
  [#11407](https://github.com/Kong/kong/pull/11407)

##### PDK

- Fix several issues in Vault and refactor the Vault code base: - Make DAOs to fallback to empty string when resolving Vault references fail - Use node level mutex when rotation references  - Refresh references on config changes - Update plugin referenced values only once per request - Pass only the valid config options to vault implementations - Resolve multi-value secrets only once when rotating them - Do not start vault secrets rotation timer on control planes - Re-enable negative caching - Reimplement the kong.vault.try function - Remove references from rotation in case their configuration has changed
  [#11652](https://github.com/Kong/kong/issues/11652)

- Fix response body gets repeated when `kong.response.get_raw_body()` is called multiple times in a request lifecycle.
  [#11424](https://github.com/Kong/kong/issues/11424)

- Tracing: fix an issue that resulted in some parent spans to end before their children due to different precision of their timestamps
  [#11484](https://github.com/Kong/kong/issues/11484)

- Fix a bug related to data interference between requests in the kong.log.serialize function.
  [#11566](https://github.com/Kong/kong/issues/11566)
##### Plugin

- **Opentelemetry**: fix an issue that resulted in invalid parent IDs in the propagated tracing headers
  [#11468](https://github.com/Kong/kong/issues/11468)

- **AWS-Lambda**: let plugin-level proxy take effect on EKS IRSA credential provider
  [#11551](https://github.com/Kong/kong/issues/11551)

- Cache the AWS lambda service by those lambda service related fields
  [#11821](https://github.com/Kong/kong/issues/11821)

- **Opentelemetry**: fix an issue that resulted in traces with invalid parent IDs when `balancer` instrumentation was enabled
  [#11830](https://github.com/Kong/kong/issues/11830)


- **tcp-log**: fix an issue of unnecessary handshakes when reusing TLS connection
  [#11848](https://github.com/Kong/kong/issues/11848)

- **OAuth2**: For OAuth2 plugin, `scope` has been taken into account as a new criterion of the request validation. When refreshing token with `refresh_token`, the scopes associated with the `refresh_token` provided in the request must be same with or a subset of the scopes configured in the OAuth2 plugin instance hit by the request.
  [#11342](https://github.com/Kong/kong/pull/11342)

- When the worker is in shutdown mode and more data is immediately available without waiting for `max_coalescing_delay`, queues are now cleared in batches.
  Thanks [@JensErat](https://github.com/JensErat) for contributing this change.
  [#11376](https://github.com/Kong/kong/pull/11376)

- A race condition in the plugin queue could potentially crash the worker when `max_entries` was set to `max_batch_size`.
  [#11378](https://github.com/Kong/kong/pull/11378)

- **AWS-Lambda**: fix an issue that the AWS-Lambda plugin cannot extract a json encoded proxy integration response.
  [#11413](https://github.com/Kong/kong/pull/11413)

##### Default

- Restore lapis & luarocks-admin bins
  [#11578](https://github.com/Kong/kong/issues/11578)
### Kong-Manager






#### Features
##### Default

- Add `JSON` and `YAML` formats in entity config cards.
  [#111](https://github.com/Kong/kong-manager/issues/111)


- Plugin form fields now display descriptions from backend schema.
  [#66](https://github.com/Kong/kong-manager/issues/66)


- Add the `protocols` field in plugin form.
  [#93](https://github.com/Kong/kong-manager/issues/93)


- The upstream target list shows the `Mark Healthy` and `Mark Unhealthy` action items when certain conditions are met.
  [#86](https://github.com/Kong/kong-manager/issues/86)


#### Fixes
##### Default

- Fix incorrect port number in Port Details.
  [#103](https://github.com/Kong/kong-manager/issues/103)


- Fix a bug where the `proxy-cache` plugin cannot be installed.
  [#104](https://github.com/Kong/kong-manager/issues/104)

## 3.4.2

### Kong

#### Fixes
##### Core

- Apply Nginx patch for detecting HTTP/2 stream reset attacks early (CVE-2023-44487)
 [#11743](https://github.com/Kong/kong/issues/11743)
 [CVE-2023](https://konghq.atlassian.net/browse/CVE-2023) [nginx-1](https://konghq.atlassian.net/browse/nginx-1) [SIR-435](https://konghq.atlassian.net/browse/SIR-435)

## 3.4.1

### Kong


#### Additions

##### Core

- Support HTTP query parameters in expression routes.
  [#11348](https://github.com/Kong/kong/pull/11348)


#### Dependencies

##### Core

- Fix incorrect LuaJIT LDP/STP fusion on ARM64 which may sometimes cause incorrect logic
  [#11537](https://github.com/Kong/kong-ee/issues/11537)



#### Fixes

##### Core

- Removed a hardcoded proxy-wasm isolation level setting that was preventing the
  `nginx_http_proxy_wasm_isolation` configuration value from taking effect.
  [#11407](https://github.com/Kong/kong/pull/11407)
- Fix an issue that the TTL of the key-auth plugin didnt work in DB-less and Hybrid mode.
  [#11464](https://github.com/Kong/kong-ee/issues/11464)
- Fix a problem that abnormal socket connection will be reused when querying Postgres database.
  [#11480](https://github.com/Kong/kong-ee/issues/11480)
- Fix upstream ssl failure when plugins use response handler
  [#11502](https://github.com/Kong/kong-ee/issues/11502)
- Fix an issue that protocol `tls_passthrough` can not work with expressions flavor
  [#11538](https://github.com/Kong/kong-ee/issues/11538)

##### PDK

- Fix several issues in Vault and refactor the Vault code base: - Make DAOs to fallback to empty string when resolving Vault references fail - Use node level mutex when rotation references  - Refresh references on config changes - Update plugin referenced values only once per request - Pass only the valid config options to vault implementations - Resolve multi-value secrets only once when rotating them - Do not start vault secrets rotation timer on control planes - Re-enable negative caching - Reimplement the kong.vault.try function - Remove references from rotation in case their configuration has changed

[#11402](https://github.com/Kong/kong-ee/issues/11402)
- Tracing: fix an issue that resulted in some parent spans to end before their children due to different precision of their timestamps
  [#11484](https://github.com/Kong/kong-ee/issues/11484)

##### Plugin

- **Opentelemetry**: fix an issue that resulted in invalid parent IDs in the propagated tracing headers
  [#11468](https://github.com/Kong/kong-ee/issues/11468)

### Kong Manager

#### Fixes

- Fixed entity docs link.
  [#92](https://github.com/Kong/kong-manager/pull/92)

## 3.4.0

### Breaking Changes

- :warning: Alpine packages and Docker images based on Alpine are no longer supported
  [#10926](https://github.com/Kong/kong/pull/10926)
- :warning: Cassandra as a datastore for Kong is no longer supported
  [#10931](https://github.com/Kong/kong/pull/10931)
- Ubuntu 18.04 artifacts are no longer supported as it's EOL
- AmazonLinux 2022 artifacts are renamed to AmazonLinux 2023 according to AWS's decision

### Deprecations

- **CentOS packages are now removed from the release and are no longer supported in future versions.**

### Additions

#### Core

- Enable `expressions` and `traditional_compatible` router flavor in stream subsystem.
  [#11071](https://github.com/Kong/kong/pull/11071)
- Make upstream `host_header` and router `preserve_host` config work in stream tls proxy.
  [#11244](https://github.com/Kong/kong/pull/11244)
- Add beta support for WebAssembly/proxy-wasm
  [#11218](https://github.com/Kong/kong/pull/11218)
- '/schemas' endpoint returns additional information about cross-field validation as part of the schema.
  This should help tools that use the Admin API to perform better client-side validation.
  [#11108](https://github.com/Kong/kong/pull/11108)

#### Kong Manager
- First release of the Kong Manager Open Source Edition.
  [#11131](https://github.com/Kong/kong/pull/11131)

#### Plugins

- **OpenTelemetry**: Support AWS X-Ray propagation header
  The field `header_type`now accepts the `aws` value to handle this specific
  propagation header.
  [11075](https://github.com/Kong/kong/pull/11075)
- **Opentelemetry**: Support the `endpoint` parameter as referenceable.
  [#11220](https://github.com/Kong/kong/pull/11220)
- **Ip-Restriction**: Add TCP support to the plugin.
  Thanks [@scrudge](https://github.com/scrudge) for contributing this change.
  [#10245](https://github.com/Kong/kong/pull/10245)

#### Performance

- In dbless mode, the declarative schema is now fully initialized at startup
  instead of on-demand in the request path. This is most evident in decreased
  response latency when updating configuration via the `/config` API endpoint.
  [#10932](https://github.com/Kong/kong/pull/10932)
- The Prometheus plugin has been optimized to reduce proxy latency impacts during scraping.
  [#10949](https://github.com/Kong/kong/pull/10949)
  [#11040](https://github.com/Kong/kong/pull/11040)
  [#11065](https://github.com/Kong/kong/pull/11065)

### Fixes

#### Core

- Declarative config now performs proper uniqueness checks against its inputs:
  previously, it would silently drop entries with conflicting primary/endpoint
  keys, or accept conflicting unique fields silently.
  [#11199](https://github.com/Kong/kong/pull/11199)
- Fixed a bug that causes `POST /config?flatten_errors=1` to throw an exception
  and return a 500 error under certain circumstances.
  [#10896](https://github.com/Kong/kong/pull/10896)
- Fix a bug when worker consuming dynamic log level setting event and using a wrong reference for notice logging
  [#10897](https://github.com/Kong/kong/pull/10897)
- Added a `User=` specification to the systemd unit definition so that
  Kong can be controlled by systemd again.
  [#11066](https://github.com/Kong/kong/pull/11066)
- Fix a bug that caused sampling rate to be applied to individual spans producing split traces.
  [#11135](https://github.com/Kong/kong/pull/11135)
- Fix a bug that caused spans to not be instrumented with http.status_code when the request was not proxied to an upstream.
  Thanks [@backjo](https://github.com/backjo) for contributing this change.
  [#11152](https://github.com/Kong/kong/pull/11152),
  [#11406](https://github.com/Kong/kong/pull/11406)
- Fix a bug that caused the router to fail in `traditional_compatible` mode when a route with multiple paths and no service was created.
  [#11158](https://github.com/Kong/kong/pull/11158)
- Fix an issue where the router of flavor `expressions` can not work correctly
  when `route.protocols` is set to `grpc` or `grpcs`.
  [#11082](https://github.com/Kong/kong/pull/11082)
- Fix an issue where the router of flavor `expressions` can not configure https redirection.
  [#11166](https://github.com/Kong/kong/pull/11166)
- Added new span attribute `net.peer.name` if balancer_data.hostname is available.
  Thanks [@backjo](https://github.com/backjo) for contributing this change.
  [#10723](https://github.com/Kong/kong/pull/10729)
- Make `kong vault get` CLI command work in dbless mode by injecting the necessary directives into the kong cli nginx.conf.
  [#11127](https://github.com/Kong/kong/pull/11127)
  [#11291](https://github.com/Kong/kong/pull/11291)
- Fix an issue where a crashing Go plugin server process would cause subsequent
  requests proxied through Kong to execute Go plugins with inconsistent configurations.
  The issue only affects scenarios where the same Go plugin is applied to different Route
  or Service entities.
  [#11306](https://github.com/Kong/kong/pull/11306)
- Fix an issue where cluster_cert or cluster_ca_cert is inserted into lua_ssl_trusted_certificate before being base64 decoded.
  [#11385](https://github.com/Kong/kong/pull/11385)
- Update the DNS client to follow configured timeouts in a more predictable manner.  Also fix a corner case in its
  behavior that could cause it to resolve incorrectly during transient network and DNS server failures.
  [#11386](https://github.com/Kong/kong/pull/11386)

#### Admin API

- Fix an issue where `/schemas/plugins/validate` endpoint fails to validate valid plugin configuration
  when the key of `custom_fields_by_lua` contains dot character(s).
  [#11091](https://github.com/Kong/kong/pull/11091)
- Fix an issue with the `/tags/:tag` Admin API returning a JSON object (`{}`) instead of an array (`[]`) for empty data sets.
  [#11213](https://github.com/Kong/kong/pull/11213)

#### Plugins

- **Response Transformer**: fix an issue that plugin does not transform the response body while upstream returns a Content-Type with +json suffix at subtype.
  [#10656](https://github.com/Kong/kong/pull/10656)
- **grpc-gateway**: Fixed an issue that empty (all default value) messages can not be unframed correctly.
  [#10836](https://github.com/Kong/kong/pull/10836)
- **ACME**: Fixed sanity test can't work with "kong" storage in Hybrid mode
  [#10852](https://github.com/Kong/kong/pull/10852)
- **rate-limiting**: Fixed an issue that impact the accuracy with the `redis` policy.
  Thanks [@giovanibrioni](https://github.com/giovanibrioni) for contributing this change.
  [#10559](https://github.com/Kong/kong/pull/10559)
- **Zipkin**: Fixed an issue that traces not being generated correctly when instrumentations are enabled.
  [#10983](https://github.com/Kong/kong/pull/10983)
- **Acme**: Fixed string concatenation on cert renewal errors
  [#11364](https://github.com/Kong/kong/pull/11364)
- Validation for queue related parameters has been
  improved. `max_batch_size`, `max_entries` and `max_bytes` are now
  `integer`s instead of `number`s.  `initial_retry_delay` and
  `max_retry_delay` must now be `number`s greater than 0.001
  (seconds).
  [#10840](https://github.com/Kong/kong/pull/10840)

### Changed

#### Core

- Tracing: new attribute `http.route` added to http request spans.
  [#10981](https://github.com/Kong/kong/pull/10981)
- The default value of `lmdb_map_size` config has been bumped to `2048m`
  from `128m` to accommodate most commonly deployed config sizes in DB-less
  and Hybrid mode.
  [#11047](https://github.com/Kong/kong/pull/11047)
- The default value of `cluster_max_payload` config has been bumped to `16m`
  from `4m` to accommodate most commonly deployed config sizes in Hybrid mode.
  [#11090](https://github.com/Kong/kong/pull/11090)
- Remove kong branding from kong HTML error template.
  [#11150](https://github.com/Kong/kong/pull/11150)
- Drop luasocket in cli
  [#11177](https://github.com/Kong/kong/pull/11177)

#### Status API

- Remove the database information from the status API when operating in dbless
  mode or data plane.
  [#10995](https://github.com/Kong/kong/pull/10995)

### Dependencies

- Bumped lua-resty-openssl from 0.8.20 to 0.8.23
  [#10837](https://github.com/Kong/kong/pull/10837)
  [#11099](https://github.com/Kong/kong/pull/11099)
- Bumped kong-lapis from 1.8.3.1 to 1.14.0.2
  [#10841](https://github.com/Kong/kong/pull/10841)
- Bumped lua-resty-events from 0.1.4 to 0.2.0
  [#10883](https://github.com/Kong/kong/pull/10883)
  [#11083](https://github.com/Kong/kong/pull/11083)
  [#11214](https://github.com/Kong/kong/pull/11214)
- Bumped lua-resty-session from 4.0.3 to 4.0.4
  [#11011](https://github.com/Kong/kong/pull/11011)
- Bumped OpenSSL from 1.1.1t to 3.1.1
  [#10180](https://github.com/Kong/kong/pull/10180)
  [#11140](https://github.com/Kong/kong/pull/11140)
- Bumped pgmoon from 1.16.0 to 1.16.2 (Kong's fork)
  [#11181](https://github.com/Kong/kong/pull/11181)
  [#11229](https://github.com/Kong/kong/pull/11229)
- Bumped atc-router from 1.0.5 to 1.2.0
  [#10100](https://github.com/Kong/kong/pull/10100)
  [#11071](https://github.com/Kong/kong/pull/11071)
- Bumped lua-resty-lmdb from 1.1.0 to 1.3.0
  [#11227](https://github.com/Kong/kong/pull/11227)
- Bumped lua-ffi-zlib from 0.5 to 0.6
  [#11373](https://github.com/Kong/kong/pull/11373)

### Known Issues
- Some referenceable configuration fields, such as the `http_endpoint` field
  of the `http-log` plugin and the `endpoint` field of the `opentelemetry` plugin,
  do not accept reference values due to incorrect field validation.

## 3.3.0

### Breaking Changes

#### Core

- The `traditional_compatible` router mode has been made more compatible with the
  behavior of `traditional` mode by splitting routes with multiple paths into
  multiple atc routes with separate priorities.  Since the introduction of the new
  router in Kong Gateway 3.0, `traditional_compatible` mode assigned only one priority
  to each route, even if different prefix path lengths and regular expressions
  were mixed in a route. This was not how multiple paths were handled in the
  `traditional` router and the behavior has now been changed so that a separate
  priority value is assigned to each path in a route.
  [#10615](https://github.com/Kong/kong/pull/10615)

#### Plugins

- **http-log, statsd, opentelemetry, datadog**: The queueing system
  has been reworked, causing some plugin parameters to not function as expected
  anymore. If you use queues on these plugin, new parameters must be configured.
  The module `kong.tools.batch_queue` has been renamed to `kong.tools.queue` in
  the process and the API was changed.  If your custom plugin uses queues, it must
  be updated to use the new API.
  See
  [this blog post](https://konghq.com/blog/product-releases/reworked-plugin-queues-in-kong-gateway-3-3)
  for a tour of the new queues and how they are parametrized.
  [#10172](https://github.com/Kong/kong/pull/10172)
- **http-log**: If the log server responds with a 3xx HTTP status code, the
  plugin will consider it to be an error and retry according to the retry
  configuration.  Previously, 3xx status codes would be interpreted as success,
  causing the log entries to be dropped.
  [#10172](https://github.com/Kong/kong/pull/10172)
- **Serverless Functions**: `kong.cache` now points to a cache instance that is dedicated to the
  Serverless Functions plugins: it does not provide access to the global kong cache. Access to
  certain fields in kong.configuration has also been restricted.
  [#10417](https://github.com/Kong/kong/pull/10417)
- **Zipkin**: The zipkin plugin now uses queues for internal
  buffering.  The standard queue parameter set is available to
  control queuing behavior.
  [#10753](https://github.com/Kong/kong/pull/10753)
- Tracing: tracing_sampling_rate defaults to 0.01 (trace one of every 100 requests) instead of the previous 1
  (trace all requests). Tracing all requests is inappropriate for most production systems
  [#10774](https://github.com/Kong/kong/pull/10774)
- **Proxy Cache**: Add option to remove the proxy cache headers from the response
  [#10445](https://github.com/Kong/kong/pull/10445)

### Additions

#### Core

- Make runloop and init error response content types compliant with Accept header value
  [#10366](https://github.com/Kong/kong/pull/10366)
- Add a new field `updated_at` for core entities ca_certificates, certificates, consumers,
  targets, upstreams, plugins, workspaces, clustering_data_planes and snis.
  [#10400](https://github.com/Kong/kong/pull/10400)
- Allow configuring custom error templates
  [#10374](https://github.com/Kong/kong/pull/10374)
- The maximum number of request headers, response headers, uri args, and post args that are
  parsed by default can now be configured with a new configuration parameters:
  `lua_max_req_headers`, `lua_max_resp_headers`, `lua_max_uri_args` and `lua_max_post_args`
  [#10443](https://github.com/Kong/kong/pull/10443)
- Allow configuring Labels for data planes to provide metadata information.
  Labels are only compatible with hybrid mode deployments with Kong Konnect (SaaS)
  [#10471](https://github.com/Kong/kong/pull/10471)
- Add Postgres triggers on the core entites and entities in bundled plugins to delete the
  expired rows in an efficient and timely manner.
  [#10389](https://github.com/Kong/kong/pull/10389)
- Support for configurable Node IDs
  [#10385](https://github.com/Kong/kong/pull/10385)
- Request and response buffering options are now enabled for incoming HTTP 2.0 requests too.
  Thanks [@PidgeyBE](https://github.com/PidgeyBE) for contributing this change.
  [#10595](https://github.com/Kong/kong/pull/10595)
  [#10204](https://github.com/Kong/kong/pull/10204)
- Add `KONG_UPSTREAM_DNS_TIME` to `kong.ctx` so that we can record the time it takes for DNS
  resolution when Kong proxies to upstream.
  [#10355](https://github.com/Kong/kong/pull/10355)
- Tracing: rename spans to simplify filtering on tracing backends.
  [#10577](https://github.com/Kong/kong/pull/10577)
- Support timeout for dynamic log level
  [#10288](https://github.com/Kong/kong/pull/10288)
- Added new span attribute `http.client_ip` to capture the client IP when behind a proxy.
  Thanks [@backjo](https://github.com/backjo) for this contribution!
  [#10723](https://github.com/Kong/kong/pull/10723)

#### Admin API

- The `/upstreams/<upstream>/health?balancer_health=1` endpoint always shows the balancer health,
  through a new attribute balancer_health, which always returns HEALTHY or UNHEALTHY (reporting
  the true state of the balancer), even if the overall upstream health status is HEALTHCHECKS_OFF.
  This is useful for debugging.
  [#5885](https://github.com/Kong/kong/pull/5885)

#### Status API

- The `status_listen` server has been enhanced with the addition of the
  `/status/ready` API for monitoring Kong's health.
  This endpoint provides a `200` response upon receiving a `GET` request,
  but only if a valid, non-empty configuration is loaded and Kong is
  prepared to process user requests.
  Load balancers frequently utilize this functionality to ascertain
  Kong's availability to distribute incoming requests.
  [#10610](https://github.com/Kong/kong/pull/10610)
  [#10787](https://github.com/Kong/kong/pull/10787)

#### Plugins

- **ACME**: acme plugin now supports configuring an `account_key` in `keys` and `key_sets`
  [#9746](https://github.com/Kong/kong/pull/9746)
- **Proxy-Cache**: add `ignore_uri_case` to configuring cache-key uri to be handled as lowercase
  [#10453](https://github.com/Kong/kong/pull/10453)
- **HTTP-Log**: add `application/json; charset=utf-8` option for the `Content-Type` header
  in the http-log plugin, for log collectors that require that character set declaration.
  [#10533](https://github.com/Kong/kong/pull/10533)
- **DataDog**: supports value of `host` to be referenceable.
  [#10484](https://github.com/Kong/kong/pull/10484)
- **Zipkin&Opentelemetry**: convert traceid in http response headers to hex format
  [#10534](https://github.com/Kong/kong/pull/10534)
- **ACME**: acme plugin now supports configuring `namespace` for redis storage
  which is default to empty string for backward compatibility.
  [#10562](https://github.com/Kong/kong/pull/10562)
- **AWS Lambda**: add a new field `disable_https` to support scheme config on lambda service api endpoint
  [#9799](https://github.com/Kong/kong/pull/9799)
- **OpenTelemetry**: spans are now correctly correlated in downstream Datadog traces.
  [10531](https://github.com/Kong/kong/pull/10531)
- **OpenTelemetry**: add `header_type` field in OpenTelemetry plugin.
  Previously, the `header_type` was hardcoded to `preserve`, now it can be set to one of the
  following values: `preserve`, `ignore`, `b3`, `b3-single`, `w3c`, `jaeger`, `ot`.
  [#10620](https://github.com/Kong/kong/pull/10620)
- **StatsD**: allow using credential id as consumer id
  [#12412](https://github.com/Kong/kong/pull/12412)

#### PDK

- PDK now supports getting plugins' ID with `kong.plugin.get_id`.
  [#9903](https://github.com/Kong/kong/pull/9903)

### Fixes

#### Core

- Fixed an issue where upstream keepalive pool has CRC32 collision.
  [#9856](https://github.com/Kong/kong/pull/9856)
- Fix an issue where control plane does not downgrade config for `aws_lambda` and `zipkin` for older version of data planes.
  [#10346](https://github.com/Kong/kong/pull/10346)
- Fix an issue where control plane does not rename fields correctly for `session` for older version of data planes.
  [#10352](https://github.com/Kong/kong/pull/10352)
- Fix an issue where validation to regex routes may be skipped when the old-fashioned config is used for DB-less Kong.
  [#10348](https://github.com/Kong/kong/pull/10348)
- Fix and issue where tracing may cause unexpected behavior.
  [#10364](https://github.com/Kong/kong/pull/10364)
- Fix an issue where balancer passive healthcheck would use wrong status code when kong changes status code
  from upstream in `header_filter` phase.
  [#10325](https://github.com/Kong/kong/pull/10325)
  [#10592](https://github.com/Kong/kong/pull/10592)
- Fix an issue where schema validations failing in a nested record did not propagate the error correctly.
  [#10449](https://github.com/Kong/kong/pull/10449)
- Fixed an issue where dangling Unix sockets would prevent Kong from restarting in
  Docker containers if it was not cleanly stopped.
  [#10468](https://github.com/Kong/kong/pull/10468)
- Fix an issue where sorting function for traditional router sources/destinations lead to "invalid order
  function for sorting" error.
  [#10514](https://github.com/Kong/kong/pull/10514)
- Fix the UDP socket leak caused by frequent DNS queries.
  [#10691](https://github.com/Kong/kong/pull/10691)
- Fix a typo of mlcache option `shm_set_tries`.
  [#10712](https://github.com/Kong/kong/pull/10712)
- Fix an issue where slow start up of Go plugin server causes dead lock.
  [#10561](https://github.com/Kong/kong/pull/10561)
- Tracing: fix an issue that caused the `sampled` flag of incoming propagation
  headers to be handled incorrectly and only affect some spans.
  [#10655](https://github.com/Kong/kong/pull/10655)
- Tracing: fix an issue that was preventing `http_client` spans to be created for OpenResty HTTP client requests.
  [#10680](https://github.com/Kong/kong/pull/10680)
- Tracing: fix an approximation issue that resulted in reduced precision of the balancer span start and end times.
  [#10681](https://github.com/Kong/kong/pull/10681)
- Tracing: tracing_sampling_rate defaults to 0.01 (trace one of every 100 requests) instead of the previous 1
  (trace all requests). Tracing all requests is inappropriate for most production systems
  [#10774](https://github.com/Kong/kong/pull/10774)
- Fix issue when stopping a Kong could error out if using Vault references
  [#10775](https://github.com/Kong/kong/pull/10775)
- Fix issue where Vault configuration stayed sticky and cached even when configurations were changed.
  [#10776](https://github.com/Kong/kong/pull/10776)
- Backported the openresty `ngx.print` chunk encoding buffer double free bug fix that
  leads to the corruption of chunk-encoded response data.
  [#10816](https://github.com/Kong/kong/pull/10816)
  [#10824](https://github.com/Kong/kong/pull/10824)


#### Admin API

- Fix an issue where empty value of URI argument `custom_id` crashes `/consumer`.
  [#10475](https://github.com/Kong/kong/pull/10475)

#### Plugins

- **Request-Transformer**: fix an issue where requests would intermittently
  be proxied with incorrect query parameters.
  [10539](https://github.com/Kong/kong/pull/10539)
- **Request Transformer**: honor value of untrusted_lua configuration parameter
  [#10327](https://github.com/Kong/kong/pull/10327)
- **OAuth2**: fix an issue that OAuth2 token was being cached to nil while access to the wrong service first.
  [#10522](https://github.com/Kong/kong/pull/10522)
- **OpenTelemetry**: fix an issue that reconfigure of OpenTelemetry does not take effect.
  [#10172](https://github.com/Kong/kong/pull/10172)
- **OpenTelemetry**: fix an issue that caused spans to be propagated incorrectly
  resulting in a wrong hierarchy being rendered on tracing backends.
  [#10663](https://github.com/Kong/kong/pull/10663)
- **gRPC gateway**: `null` in the JSON payload caused an uncaught exception to be thrown during pb.encode.
  [#10687](https://github.com/Kong/kong/pull/10687)
- **Oauth2**: prevent an authorization code created by one plugin instance to be exchanged for an access token by a different plugin instance.
  [#10011](https://github.com/Kong/kong/pull/10011)
- **gRPC gateway**: fixed an issue that empty arrays in JSON are incorrectly encoded as `"{}"`; they are
now encoded as `"[]"` to comply with standard.
  [#10790](https://github.com/Kong/kong/pull/10790)

#### PDK

- Fixed an issue for tracing PDK where sample rate does not work.
  [#10485](https://github.com/Kong/kong/pull/10485)

### Changed

#### Core

- Postgres TTL cleanup timer will now only run on traditional and control plane nodes that have enabled the Admin API.
  [#10405](https://github.com/Kong/kong/pull/10405)
- Postgres TTL cleanup timer now runs a batch delete loop on each ttl enabled table with a number of 50.000 rows per batch.
  [#10407](https://github.com/Kong/kong/pull/10407)
- Postgres TTL cleanup timer now runs every 5 minutes instead of every 60 seconds.
  [#10389](https://github.com/Kong/kong/pull/10389)
- Postgres TTL cleanup timer now deletes expired rows based on database server-side timestamp to avoid potential
  problems caused by the difference of clock time between Kong and database server.
  [#10389](https://github.com/Kong/kong/pull/10389)

#### PDK

- `request.get_uri_captures` now returns the unnamed part tagged as an array (for jsonification).
  [#10390](https://github.com/Kong/kong/pull/10390)

#### Plugins

- **Request-Termination**: If the echo option was used, it would not return the uri-captures.
  [#10390](https://github.com/Kong/kong/pull/10390)
- **OpenTelemetry**: add `http_response_header_for_traceid` field in OpenTelemetry plugin.
  The plugin will set the corresponding header in the response
  if the field is specified with a string value.
  [#10379](https://github.com/Kong/kong/pull/10379)

### Dependencies

- Bumped lua-resty-session from 4.0.2 to 4.0.3
  [#10338](https://github.com/Kong/kong/pull/10338)
- Bumped lua-protobuf from 0.3.3 to 0.5.0
  [#10137](https://github.com/Kong/kong/pull/10413)
  [#10790](https://github.com/Kong/kong/pull/10790)
- Bumped lua-resty-timer-ng from 0.2.3 to 0.2.5
  [#10419](https://github.com/Kong/kong/pull/10419)
  [#10664](https://github.com/Kong/kong/pull/10664)
- Bumped lua-resty-openssl from 0.8.17 to 0.8.20
  [#10463](https://github.com/Kong/kong/pull/10463)
  [#10476](https://github.com/Kong/kong/pull/10476)
- Bumped lua-resty-http from 0.17.0.beta.1 to 0.17.1
  [#10547](https://github.com/Kong/kong/pull/10547)
- Bumped LuaSec from 1.2.0 to 1.3.1
  [#10528](https://github.com/Kong/kong/pull/10528)
- Bumped lua-resty-acme from 0.10.1 to 0.11.0
  [#10562](https://github.com/Kong/kong/pull/10562)
- Bumped lua-resty-events from 0.1.3 to 0.1.4
  [#10634](https://github.com/Kong/kong/pull/10634)
- Bumped lua-kong-nginx-module from 0.5.1 to 0.6.0
  [#10288](https://github.com/Kong/kong/pull/10288)
- Bumped lua-resty-lmdb from 1.0.0 to 1.1.0
  [#10766](https://github.com/Kong/kong/pull/10766)

## 3.2.0

### Breaking Changes

#### Plugins

- **JWT**: JWT plugin now denies a request that has different tokens in the jwt token search locations.
  [#9946](https://github.com/Kong/kong/pull/9946)
- **Session**: for sessions to work as expected it is required that all nodes run Kong >= 3.2.x.
  For that reason it is advisable that during upgrades mixed versions of proxy nodes run for
  as little as possible. During that time, the invalid sessions could cause failures and partial downtime.
  All existing sessions are invalidated when upgrading to this version.
  The parameter `idling_timeout` now has a default value of `900`: unless configured differently,
  sessions expire after 900 seconds (15 minutes) of idling.
  The parameter `absolute_timeout` has a default value of `86400`: unless configured differently,
  sessions expire after 86400 seconds (24 hours).
  [#10199](https://github.com/Kong/kong/pull/10199)
- **Proxy Cache**: Add wildcard and parameter match support for content_type
  [#10209](https://github.com/Kong/kong/pull/10209)

### Additions

#### Core

- Expose postgres connection pool configuration.
  [#9603](https://github.com/Kong/kong/pull/9603)
- When `router_flavor` is `traditional_compatible`, verify routes created using the
  Expression router instead of the traditional router to ensure created routes
  are actually compatible.
  [#9987](https://github.com/Kong/kong/pull/9987)
- Nginx charset directive can now be configured with Nginx directive injections
  [#10111](https://github.com/Kong/kong/pull/10111)
- Services upstream TLS config is extended to stream subsystem.
  [#9947](https://github.com/Kong/kong/pull/9947)
- New configuration option `ssl_session_cache_size` to set the Nginx directive `ssl_session_cache`.
  This config defaults to `10m`.
  Thanks [Michael Kotten](https://github.com/michbeck100) for contributing this change.
  [#10021](https://github.com/Kong/kong/pull/10021)

#### Balancer

- Add a new load-balancing `algorithm` option `latency` to the `Upstream` entity.
  This algorithm will choose a target based on the response latency of each target
  from prior requests.
  [#9787](https://github.com/Kong/kong/pull/9787)

#### Plugins

- **Plugin**: add an optional field `instance_name` that identifies a
  particular plugin entity.
  [#10077](https://github.com/Kong/kong/pull/10077)
- **Zipkin**: Add support to set the durations of Kong phases as span tags
  through configuration property `config.phase_duration_flavor`.
  [#9891](https://github.com/Kong/kong/pull/9891)
- **HTTP logging**: Suppport value of `headers` to be referenceable.
  [#9948](https://github.com/Kong/kong/pull/9948)
- **AWS Lambda**: Add `aws_imds_protocol_version` configuration
  parameter that allows the selection of the IMDS protocol version.
  Defaults to `v1`, can be set to `v2` to enable IMDSv2.
  [#9962](https://github.com/Kong/kong/pull/9962)
- **OpenTelemetry**: Support scoping with services, routes and consumers.
  [#10096](https://github.com/Kong/kong/pull/10096)
- **Statsd**: Add `tag_style` configuration
  parameter that allows to send metrics with [tags](https://github.com/prometheus/statsd_exporter#tagging-extensions).
  Defaults to `nil` which means do not add any tags
  to the metrics.
  [#10118](https://github.com/Kong/kong/pull/10118)
- **Session**: now uses lua-resty-session v4.0.0
  [#10199](https://github.com/Kong/kong/pull/10199)

#### Admin API

- In dbless mode, `/config` API endpoint can now flatten entity-related schema
  validation errors to a single array via the optional `flatten_errors` query
  parameter. Non-entity errors remain unchanged in this mode.
  [#10161](https://github.com/Kong/kong/pull/10161)
  [#10256](https://github.com/Kong/kong/pull/10256)

#### PDK

- Support for `upstream_status` field in log serializer.
  [#10296](https://github.com/Kong/kong/pull/10296)

### Fixes

#### Core

- Add back Postgres `FLOOR` function when calculating `ttl`, so the returned `ttl` is always a whole integer.
  [#9960](https://github.com/Kong/kong/pull/9960)
- Fix an issue where after a valid declarative configuration is loaded,
  the configuration hash is incorrectly set to the value: `00000000000000000000000000000000`.
  [#9911](https://github.com/Kong/kong/pull/9911)
- Update the batch queues module so that queues no longer grow without bounds if
  their consumers fail to process the entries.  Instead, old batches are now dropped
  and an error is logged.
  [#10247](https://github.com/Kong/kong/pull/10247)
- Fix an issue where 'X-Kong-Upstream-Status' cannot be emitted when response is buffered.
  [#10056](https://github.com/Kong/kong/pull/10056)

#### Plugins

- **Zipkin**: Fix an issue where the global plugin's sample ratio overrides route-specific.
  [#9877](https://github.com/Kong/kong/pull/9877)
- **JWT**: Deny requests that have different tokens in the jwt token search locations. Thanks Jackson 'Che-Chun' Kuo from Latacora for reporting this issue.
  [#9946](https://github.com/Kong/kong/pull/9946)
- **Statsd**: Fix a bug in the StatsD plugin batch queue processing where metrics are published multiple times.
  [#10052](https://github.com/Kong/kong/pull/10052)
- **Datadog**: Fix a bug in the Datadog plugin batch queue processing where metrics are published multiple times.
  [#10044](https://github.com/Kong/kong/pull/10044)
- **OpenTelemetry**: Fix non-compliances to specification:
  - For `http.uri` in spans. The field should be full HTTP URI.
    [#10069](https://github.com/Kong/kong/pull/10069)
  - For `http.status_code`. It should be present on spans for requests that have a status code.
    [#10160](https://github.com/Kong/kong/pull/10160)
  - For `http.flavor`. It should be a string value, not a double.
    [#10160](https://github.com/Kong/kong/pull/10160)
- **OpenTelemetry**: Fix a bug that when getting the trace of other formats, the trace ID reported and propagated could be of incorrect length.
    [#10332](https://github.com/Kong/kong/pull/10332)
- **OAuth2**: `refresh_token_ttl` is now limited between `0` and `100000000` by schema validator. Previously numbers that are too large causes requests to fail.
  [#10068](https://github.com/Kong/kong/pull/10068)

### Changed

#### Core

- Improve error message for invalid JWK entities.
  [#9904](https://github.com/Kong/kong/pull/9904)
- Renamed two configuration properties:
    * `opentelemetry_tracing` => `tracing_instrumentations`
    * `opentelemetry_tracing_sampling_rate` => `tracing_sampling_rate`

  The old `opentelemetry_*` properties are considered deprecated and will be
  fully removed in a future version of Kong.
  [#10122](https://github.com/Kong/kong/pull/10122)
  [#10220](https://github.com/Kong/kong/pull/10220)

#### Hybrid Mode

- Revert the removal of WebSocket protocol support for configuration sync,
  and disable the wRPC protocol.
  [#9921](https://github.com/Kong/kong/pull/9921)

### Dependencies

- Bumped luarocks from 3.9.1 to 3.9.2
  [#9942](https://github.com/Kong/kong/pull/9942)
- Bumped atc-router from 1.0.1 to 1.0.5
  [#9925](https://github.com/Kong/kong/pull/9925)
  [#10143](https://github.com/Kong/kong/pull/10143)
  [#10208](https://github.com/Kong/kong/pull/10208)
- Bumped lua-resty-openssl from 0.8.15 to 0.8.17
  [#9583](https://github.com/Kong/kong/pull/9583)
  [#10144](https://github.com/Kong/kong/pull/10144)
- Bumped lua-kong-nginx-module from 0.5.0 to 0.5.1
  [#10181](https://github.com/Kong/kong/pull/10181)
- Bumped lua-resty-session from 3.10 to 4.0.2
  [#10199](https://github.com/Kong/kong/pull/10199)
  [#10230](https://github.com/Kong/kong/pull/10230)
  [#10308](https://github.com/Kong/kong/pull/10308)
- Bumped OpenSSL from 1.1.1s to 1.1.1t
  [#10266](https://github.com/Kong/kong/pull/10266)
- Bumped lua-resty-timer-ng from 0.2.0 to 0.2.3
  [#10265](https://github.com/Kong/kong/pull/10265)


## 3.1.0

### Breaking Changes

#### Core

- Change the reponse body for a TRACE method from `The upstream server responded with 405`
  to `Method not allowed`, make the reponse to show more clearly that Kong do not support
  TRACE method.
  [#9448](https://github.com/Kong/kong/pull/9448)
- Add `allow_debug_header` Kong conf to allow use of the `Kong-Debug` header for debugging.
  This option defaults to `off`.
  [#10054](https://github.com/Kong/kong/pull/10054)
  [#10125](https://github.com/Kong/kong/pull/10125)


### Additions

#### Core

- Allow `kong.conf` ssl properties to be stored in vaults or environment
  variables. Allow such properties to be configured directly as content
  or base64 encoded content.
  [#9253](https://github.com/Kong/kong/pull/9253)
- Add support for full entity transformations in schemas
  [#9431](https://github.com/Kong/kong/pull/9431)
- Allow schema `map` type field being marked as referenceable.
  [#9611](https://github.com/Kong/kong/pull/9611)
- Add support for dynamically changing the log level
  [#9744](https://github.com/Kong/kong/pull/9744)
- Add `keys` entity to store and manage asymmetric keys.
  [#9737](https://github.com/Kong/kong/pull/9737)
- Add `key-sets` entity to group and manage `keys`
  [#9737](https://github.com/Kong/kong/pull/9737)

#### Plugins

- **Rate-limiting**: The HTTP status code and response body for rate-limited
  requests can now be customized. Thanks, [@utix](https://github.com/utix)!
  [#8930](https://github.com/Kong/kong/pull/8930)
- **Zipkin**: add `response_header_for_traceid` field in Zipkin plugin.
  The plugin will set the corresponding header in the response
  if the field is specified with a string value.
  [#9173](https://github.com/Kong/kong/pull/9173)
- **AWS Lambda**: add `requestContext` field into `awsgateway_compatible` input data
  [#9380](https://github.com/Kong/kong/pull/9380)
- **ACME**: add support for Redis SSL, through configuration properties
  `config.storage_config.redis.ssl`, `config.storage_config.redis.ssl_verify`,
  and `config.storage_config.redis.ssl_server_name`.
  [#9626](https://github.com/Kong/kong/pull/9626)
- **Session**: Add new config `cookie_persistent` that allows browser to persist
  cookies even if browser is closed. This defaults to `false` which means
  cookies are not persistend across browser restarts. Thanks [@tschaume](https://github.com/tschaume)
  for this contribution!
  [#8187](https://github.com/Kong/kong/pull/8187)
- **Response-rate-limiting**: add support for Redis SSL, through configuration properties
  `redis_ssl` (can be set to `true` or `false`), `ssl_verify`, and `ssl_server_name`.
  [#8595](https://github.com/Kong/kong/pull/8595)
  Thanks [@dominikkukacka](https://github.com/dominikkukacka)!
- **OpenTelemetry**: add referenceable attribute to the `headers` field
  that could be stored in vaults.
  [#9611](https://github.com/Kong/kong/pull/9611)
- **HTTP-Log**: Support `http_endpoint` field to be referenceable
  [#9714](https://github.com/Kong/kong/pull/9714)
- **rate-limiting**: Add a new configuration `sync_rate` to the `redis` policy,
  which synchronizes metrics to redis periodically instead of on every request.
  [#9538](https://github.com/Kong/kong/pull/9538)


#### Hybrid Mode

- Data plane node IDs will now persist across restarts.
  [#9067](https://github.com/Kong/kong/pull/9067)
- Add HTTP CONNECT forward proxy support for Hybrid Mode connections. New configuration
  options `cluster_use_proxy`, `proxy_server` and `proxy_server_ssl_verify` are added.
  [#9758](https://github.com/Kong/kong/pull/9758)
  [#9773](https://github.com/Kong/kong/pull/9773)

#### Performance

- Increase the default value of `lua_regex_cache_max_entries`, a warning will be thrown
  when there are too many regex routes and `router_flavor` is `traditional`.
  [#9624](https://github.com/Kong/kong/pull/9624)
- Add batch queue into the Datadog and StatsD plugin to reduce timer usage.
  [#9521](https://github.com/Kong/kong/pull/9521)

#### PDK

- Extend `kong.client.tls.request_client_certificate` to support setting
  the Distinguished Name (DN) list hints of the accepted CA certificates.
  [#9768](https://github.com/Kong/kong/pull/9768)

### Fixes

#### Core

- Fix issue where external plugins crashing with unhandled exceptions
  would cause high CPU utilization after the automatic restart.
  [#9384](https://github.com/Kong/kong/pull/9384)
- Fix issue where Zipkin plugin cannot parse OT baggage headers
  due to invalid OT baggage pattern. [#9280](https://github.com/Kong/kong/pull/9280)
- Add `use_srv_name` options to upstream for balancer.
  [#9430](https://github.com/Kong/kong/pull/9430)
- Fix issue in `header_filter` instrumentation where the span was not
  correctly created.
  [#9434](https://github.com/Kong/kong/pull/9434)
- Fix issue in router building where when field contains an empty table,
  the generated expression is invalid.
  [#9451](https://github.com/Kong/kong/pull/9451)
- Fix issue in router rebuilding where when paths field is invalid,
  the router's mutex is not released properly.
  [#9480](https://github.com/Kong/kong/pull/9480)
- Fixed an issue where `kong docker-start` would fail if `KONG_PREFIX` was set to
  a relative path.
  [#9337](https://github.com/Kong/kong/pull/9337)
- Fixed an issue with error-handling and process cleanup in `kong start`.
  [#9337](https://github.com/Kong/kong/pull/9337)

#### Hybrid Mode

- Fixed a race condition that can cause configuration push events to be dropped
  when the first data-plane connection is established with a control-plane
  worker.
  [#9616](https://github.com/Kong/kong/pull/9616)

#### CLI

- Fix slow CLI performance due to pending timer jobs
  [#9536](https://github.com/Kong/kong/pull/9536)

#### Admin API

- Increase the maximum request argument number from `100` to `1000`,
  and return `400` error if request parameters reach the limitation to
  avoid being truncated.
  [#9510](https://github.com/Kong/kong/pull/9510)
- Paging size parameter is now propogated to next page if specified
  in current request.
  [#9503](https://github.com/Kong/kong/pull/9503)
- Non-normalized prefix route path is now rejected. It will also suggest
  how to write the path in normalized form.
  [#9760](https://github.com/Kong/kong/pull/9760)

#### PDK

- Added support for `kong.request.get_uri_captures`
  (`kong.request.getUriCaptures`)
  [#9512](https://github.com/Kong/kong/pull/9512)
- Fixed parameter type of `kong.service.request.set_raw_body`
  (`kong.service.request.setRawBody`), return type of
  `kong.service.response.get_raw_body`(`kong.service.request.getRawBody`),
  and body parameter type of `kong.response.exit` to bytes. Note that old
  version of go PDK is incompatible after this change.
  [#9526](https://github.com/Kong/kong/pull/9526)
- Vault will not call `semaphore:wait` in `init` or `init_worker` phase.
  [#9851](https://github.com/Kong/kong/pull/9851)

#### Plugins

- Add missing `protocols` field to various plugin schemas.
  [#9525](https://github.com/Kong/kong/pull/9525)
- **AWS Lambda**: Fix an issue that is causing inability to
  read environment variables in ECS environment.
  [#9460](https://github.com/Kong/kong/pull/9460)
- **Request-Transformer**: fix a bug when header renaming will override
  existing header and cause unpredictable result.
  [#9442](https://github.com/Kong/kong/pull/9442)
- **OpenTelemetry**:
  - Fix an issue that the default propagation header
    is not configured to `w3c` correctly.
    [#9457](https://github.com/Kong/kong/pull/9457)
  - Replace the worker-level table cache with
    `BatchQueue` to avoid data race.
    [#9504](https://github.com/Kong/kong/pull/9504)
  - Fix an issue that the `parent_id` is not set
    on the span when propagating w3c traceparent.
    [#9628](https://github.com/Kong/kong/pull/9628)
- **Response-Transformer**: Fix the bug that Response-Transformer plugin
  breaks when receiving an unexcepted body.
  [#9463](https://github.com/Kong/kong/pull/9463)
- **HTTP-Log**: Fix an issue where queue id serialization
  does not include `queue_size` and `flush_timeout`.
  [#9789](https://github.com/Kong/kong/pull/9789)

### Changed

#### Hybrid Mode

- The legacy hybrid configuration protocol has been removed in favor of the wRPC
  protocol introduced in 3.0.
  [#9740](https://github.com/Kong/kong/pull/9740)

### Dependencies

- Bumped openssl from 1.1.1q to 1.1.1s
  [#9674](https://github.com/Kong/kong/pull/9674)
- Bumped atc-router from 1.0.0 to 1.0.1
  [#9558](https://github.com/Kong/kong/pull/9558)
- Bumped lua-resty-openssl from 0.8.10 to 0.8.15
  [#9583](https://github.com/Kong/kong/pull/9583)
  [#9600](https://github.com/Kong/kong/pull/9600)
  [#9675](https://github.com/Kong/kong/pull/9675)
- Bumped lyaml from 6.2.7 to 6.2.8
  [#9607](https://github.com/Kong/kong/pull/9607)
- Bumped lua-resty-acme from 0.8.1 to 0.9.0
  [#9626](https://github.com/Kong/kong/pull/9626)
- Bumped resty.healthcheck from 1.6.1 to 1.6.2
  [#9778](https://github.com/Kong/kong/pull/9778)
- Bumped pgmoon from 1.15.0 to 1.16.0
  [#9815](https://github.com/Kong/kong/pull/9815)


## [3.0.1]

### Fixes

#### Core

- Fix issue where Zipkin plugin cannot parse OT baggage headers
  due to invalid OT baggage pattern. [#9280](https://github.com/Kong/kong/pull/9280)
- Fix issue in `header_filter` instrumentation where the span was not
  correctly created.
  [#9434](https://github.com/Kong/kong/pull/9434)
- Fix issue in router building where when field contains an empty table,
  the generated expression is invalid.
  [#9451](https://github.com/Kong/kong/pull/9451)
- Fix issue in router rebuilding where when paths field is invalid,
  the router's mutex is not released properly.
  [#9480](https://github.com/Kong/kong/pull/9480)
- Fixed an issue where `kong docker-start` would fail if `KONG_PREFIX` was set to
  a relative path.
  [#9337](https://github.com/Kong/kong/pull/9337)
- Fixed an issue with error-handling and process cleanup in `kong start`.
  [#9337](https://github.com/Kong/kong/pull/9337)


## [3.0.0]

> Released 2022/09/12

This major release adds a new router written in Rust and a tracing API
that is compatible with the OpenTelemetry API spec.  Furthermore,
various internal changes have been made to improve Kong's performance
and memory consumption.  As it is a major release, users are advised
to review the list of braking changes to determine whether
configuration changes are needed when upgrading.

### Breaking Changes

#### Deployment

- Blue-green deployment from Kong earlier than `2.1.0` is not supported, upgrade to
  `2.1.0` or later before upgrading to `3.0.0` to have blue-green deployment.
  Thank you [@marc-charpentier]((https://github.com/charpentier)) for reporting issue
  and proposing a pull-request.
  [#8896](https://github.com/Kong/kong/pull/8896)
- Deprecate/stop producing Amazon Linux (1) containers and packages (EOLed December 31, 2020)
  [Kong/docs.konghq.com #3966](https://github.com/Kong/docs.konghq.com/pull/3966)
- Deprecate/stop producing Debian 8 "Jessie" containers and packages (EOLed June 2020)
  [Kong/kong-build-tools #448](https://github.com/Kong/kong-build-tools/pull/448)
  [Kong/kong-distributions #766](https://github.com/Kong/kong-distributions/pull/766)

#### Core


- Kong schema library's `process_auto_fields` function will not any more make a deep
  copy of data that is passed to it when the given context is `"select"`. This was
  done to avoid excessive deep copying of tables where we believe the data most of
  the time comes from a driver like `pgmoon` or `lmdb`. If a custom plugin relied
  on `process_auto_fields` not overriding the given table, it must make its own copy
  before passing it to the function now.
  [#8796](https://github.com/Kong/kong/pull/8796)
- The deprecated `shorthands` field in Kong Plugin or DAO schemas was removed in favor
  or the typed `shorthand_fields`. If your custom schemas still use `shorthands`, you
  need to update them to use `shorthand_fields`.
  [#8815](https://github.com/Kong/kong/pull/8815)
- The support for `legacy = true/false` attribute was removed from Kong schemas and
  Kong field schemas.
  [#8958](https://github.com/Kong/kong/pull/8958)
- The deprecated alias of `Kong.serve_admin_api` was removed. If your custom Nginx
  templates still use it, please change it to `Kong.admin_content`.
  [#8815](https://github.com/Kong/kong/pull/8815)
- The Kong singletons module `"kong.singletons"` was removed in favor of the PDK `kong.*`.
  [#8874](https://github.com/Kong/kong/pull/8874)
- The dataplane config cache was removed. The config persistence is now done automatically with LMDB.
  [#8704](https://github.com/Kong/kong/pull/8704)
- `ngx.ctx.balancer_address` does not exist anymore, please use `ngx.ctx.balancer_data` instead.
  [#9043](https://github.com/Kong/kong/pull/9043)
- We have changed the normalization rules for `route.path`: Kong stores the unnormalized path, but
  regex path always pattern matches with the normalized URI. We used to replace percent-encoding
  in regex path pattern to ensure different forms of URI matches.
  That is no longer supported. Except for reserved characters defined in
  [rfc3986](https://datatracker.ietf.org/doc/html/rfc3986#section-2.2),
  we should write all other characters without percent-encoding.
  [#9024](https://github.com/Kong/kong/pull/9024)
- Kong will no longer use an heuristic to guess whether a `route.path` is a regex pattern. From now 3.0 onwards,
  all regex paths must start with the `"~"` prefix, and all paths that don't start with `"~"` will be considered plain text.
  The migration process should automatically convert the regex paths when upgrading from 2.x to 3.0
  [#9027](https://github.com/Kong/kong/pull/9027)
- Bumping version number (`_format_version`) of declarative configuration to "3.0" for changes on `route.path`.
  Declaritive configuration with older version are upgraded to "3.0" on the fly.
  [#9078](https://github.com/Kong/kong/pull/9078)
- Removed deprecated `config.functions` from serverless-functions plugin's schema,
  please use `config.access` phase instead.
  [#8559](https://github.com/Kong/kong/pull/8559)
- Tags may now contain space characters.
  [#9143](https://github.com/Kong/kong/pull/9143)
- The [Secrets Management](https://docs.konghq.com/gateway/latest/plan-and-deploy/security/secrets-management/)
  feature, which has been in beta since release 2.8.0, is now included as a regular feature.
  [#8871](https://github.com/Kong/kong/pull/8871)
  [#9217](https://github.com/Kong/kong/pull/9217)

#### Admin API

- `POST` requests on Targets endpoint are no longer able to update
  existing entities, they are only able to create new ones.
  [#8596](https://github.com/Kong/kong/pull/8596),
  [#8798](https://github.com/Kong/kong/pull/8798). If you have scripts that use
  `POST` requests to modify Targets, you should change them to `PUT`
  requests to the appropriate endpoints before updating to Kong 3.0.
- Insert and update operations on duplicated Targets returns 409.
  [#8179](https://github.com/Kong/kong/pull/8179),
  [#8768](https://github.com/Kong/kong/pull/8768)
- The list of reported plugins available on the server now returns a table of
  metadata per plugin instead of a boolean `true`.
  [#8810](https://github.com/Kong/kong/pull/8810)

#### PDK

- The `kong.request.get_path()` PDK function now performs path normalization
  on the string that is returned to the caller. The raw, non-normalized version
  of the request path can be fetched via `kong.request.get_raw_path()`.
  [#8823](https://github.com/Kong/kong/pull/8823)
- `pdk.response.set_header()`, `pdk.response.set_headers()`, `pdk.response.exit()` now ignore and emit warnings for manually set `Transfer-Encoding` headers.
  [#8698](https://github.com/Kong/kong/pull/8698)
- The PDK is no longer versioned
  [#8585](https://github.com/Kong/kong/pull/8585)
- The JavaScript PDK now returns `Uint8Array` for `kong.request.getRawBody`,
  `kong.response.getRawBody` and `kong.service.response.getRawBody`. The Python PDK returns `bytes` for `kong.request.get_raw_body`,
  `kong.response.get_raw_body`, `kong.service.response.get_raw_body`. All these funtions used to return strings in the past.
  [#8623](https://github.com/Kong/kong/pull/8623)

#### Plugins

- DAOs in plugins must be listed in an array, so that their loading order is explicit. Loading them in a
  hash-like table is no longer supported.
  [#8988](https://github.com/Kong/kong/pull/8988)
- Plugins MUST now have a valid `PRIORITY` (integer) and `VERSION` ("x.y.z" format)
  field in their `handler.lua` file, otherwise the plugin will fail to load.
  [#8836](https://github.com/Kong/kong/pull/8836)
- The old `kong.plugins.log-serializers.basic` library was removed in favor of the PDK
  function `kong.log.serialize`, please upgrade your plugins to use PDK.
  [#8815](https://github.com/Kong/kong/pull/8815)
- The support for deprecated legacy plugin schemas was removed. If your custom plugins
  still use the old (`0.x era`) schemas, you are now forced to upgrade them.
  [#8815](https://github.com/Kong/kong/pull/8815)
- Some plugins received new priority values.
  This is important for those who run custom plugins as it may affect the sequence your plugins are executed.
  Note that this does not change the order of execution for plugins in a standard kong installation.
  List of plugins and their old and new priority value:
  - `acme` changed from 1007 to 1705
  - `basic-auth` changed from 1001 to 1100
  - `hmac-auth` changed from 1000 to 1030
  - `jwt` changed from 1005 to 1450
  - `key-auth` changed from 1003 to 1250
  - `ldap-auth` changed from 1002 to 1200
  - `oauth2` changed from 1004 to 1400
  - `rate-limiting` changed from 901 to 910
- **HTTP-log**: `headers` field now only takes a single string per header name,
  where it previously took an array of values
  [#6992](https://github.com/Kong/kong/pull/6992)
- **AWS Lambda**: `aws_region` field must be set through either plugin config or environment variables,
  allow both `host` and `aws_region` fields, and always apply SigV4 signature.
  [#8082](https://github.com/Kong/kong/pull/8082)
- **Serverless Functions** Removed deprecated `config.functions`,
  please use `config.access` instead.
  [#8559](https://github.com/Kong/kong/pull/8559)
- **Serverless Functions**: The pre-functions plugin changed priority from `+inf` to `1000000`.
  [#8836](https://github.com/Kong/kong/pull/8836)
- **JWT**: The authenticated JWT is no longer put into the nginx
  context (ngx.ctx.authenticated_jwt_token).  Custom plugins which depend on that
  value being set under that name must be updated to use Kong's shared context
  instead (kong.ctx.shared.authenticated_jwt_token) before upgrading to 3.0
- **Prometheus**: The prometheus metrics have been reworked extensively for 3.0.
  - Latency has been split into 4 different metrics: kong_latency_ms, upstream_latency_ms and request_latency_ms (http) /tcp_session_duration_ms (stream). Buckets details below.
  - Separate out Kong Latency Bucket values and Upstream Latency Bucket values.
  - `consumer_status` removed.
  - `request_count` and `consumer_status` have been merged into just `http_requests_total`. If the `per_consumer` config is set false, the consumer label will be empty.
     If the `per_consumer` config is true, it will be filled.
  - `http_requests_total` has a new label `source`, set to either `exit`, `error` or `service`.
  - New Metric: `node_info`. Single gauge set to 1 that outputs the node's id and kong version.
  - All Memory metrics have a new label `node_id`
  - `nginx_http_current_connections` merged with `nginx_stream_current_connection` into `nginx_current_connections`
  [#8712](https://github.com/Kong/kong/pull/8712)
- **Prometheus**: The plugin doesn't export status codes, latencies, bandwidth and upstream
  healthcheck metrics by default. They can still be turned on manually by setting `status_code_metrics`,
  `latency_metrics`, `bandwidth_metrics` and `upstream_health_metrics` respectively. Enabling those metrics will impact the performance if you have a large volume of Kong entities, we recommend using the [statsd](https://github.com/Kong/kong/tree/master/kong/plugins/statsd) plugin with the push model if that is the case. And now `prometheus` plugin new grafana [dashboard](https://grafana.com/grafana/dashboards/7424-kong-official/) updated
  [#9028](https://github.com/Kong/kong/pull/9028)
- **ACME**: `allow_any_domain` field added. It is default to false and if set to true, the gateway will
  ignore the `domains` field.
  [#9047](https://github.com/Kong/kong/pull/9047)
- **Statsd**:
  - The metric name that is related to the service has been renamed by adding a `service.` prefix. e.g. `kong.service.<service_identifier>.request.count` [#9046](https://github.com/Kong/kong/pull/9046)
  - The metric `kong.<service_identifier>.request.status.<status>` and `kong.<service_identifier>.user.<consumer_identifier>.request.status.<status>` has been renamed to `kong.service.<service_identifier>.status.<status>` and  `kong.service.<service_identifier>.user.<consumer_identifier>.status.<status>` [#9046](https://github.com/Kong/kong/pull/9046)
  - The metric `*.status.<status>.total` from metrics `status_count` and `status_count_per_user` has been removed [#9046](https://github.com/Kong/kong/pull/9046)
- **Proxy-cache**: The plugin does not store the response data in
  `ngx.ctx.proxy_cache_hit` anymore. Logging plugins that need the response data
  must read it from `kong.ctx.shared.proxy_cache_hit` from Kong 3.0 on.
  [#8607](https://github.com/Kong/kong/pull/8607)
- **Rate-limiting**: The default policy is now `local` for all deployment modes.
  [#9344](https://github.com/Kong/kong/pull/9344)
- **Response-rate-limiting**: The default policy is now `local` for all deployment modes.
  [#9344](https://github.com/Kong/kong/pull/9344)

### Deprecations

- The `go_pluginserver_exe` and `go_plugins_dir` directives are no longer supported.
  [#8552](https://github.com/Kong/kong/pull/8552). If you are using
  [Go plugin server](https://github.com/Kong/go-pluginserver), please migrate your plugins to use the
  [Go PDK](https://github.com/Kong/go-pdk) before upgrading.
- The migration helper library (mostly used for Cassandra migrations) is no longer supplied with Kong
  [#8781](https://github.com/Kong/kong/pull/8781)
- The path_handling algorithm `v1` is deprecated and only supported when `router_flavor` config option
  is set to `traditional`.
  [#9290](https://github.com/Kong/kong/pull/9290)

#### Configuration

- The Kong constant `CREDENTIAL_USERNAME` with value of `X-Credential-Username` was
  removed. Kong plugins in general have moved (since [#5516](https://github.com/Kong/kong/pull/5516))
  to use constant `CREDENTIAL_IDENTIFIER` with value of `X-Credential-Identifier` when
  setting  the upstream headers for a credential.
  [#8815](https://github.com/Kong/kong/pull/8815)
- Change the default of `lua_ssl_trusted_certificate` to `system`
  [#8602](https://github.com/Kong/kong/pull/8602) to automatically load trusted CA list from system CA store.
- Remove a warning of `AAAA` being experimental with `dns_order`.
- It is no longer possible to use a .lua format to import a declarative config from the `kong`
  command-line tool, only json and yaml are supported. If your update procedure with kong involves
  executing `kong config db_import config.lua`, please create a `config.json` or `config.yml` and
  use that before upgrading.
  [#8898](https://github.com/Kong/kong/pull/8898)
- We bumped the version number (`_format_version`) of declarative configuration to "3.0" because of changes on `route.path`.
  Declarative configuration with older version should be upgraded to "3.0" on the fly.
  [#9078](https://github.com/Kong/kong/pull/9078)

#### Migrations

- Postgres migrations can now have an `up_f` part like Cassandra
  migrations, designating a function to call.  The `up_f` part is
  invoked after the `up` part has been executed against the database
  for both Postgres and Cassandra.
- A new CLI command, `kong migrations status`, generates the status on a JSON file.

### Dependencies

- Bumped OpenResty from 1.19.9.1 to [1.21.4.1](https://openresty.org/en/changelog-1021004.html)
  [#8850](https://github.com/Kong/kong/pull/8850)
- Bumped pgmoon from 1.13.0 to 1.15.0
  [#8908](https://github.com/Kong/kong/pull/8908)
  [#8429](https://github.com/Kong/kong/pull/8429)
- Bumped OpenSSL from 1.1.1n to 1.1.1q
  [#9074](https://github.com/Kong/kong/pull/9074)
  [#8544](https://github.com/Kong/kong/pull/8544)
  [#8752](https://github.com/Kong/kong/pull/8752)
  [#8994](https://github.com/Kong/kong/pull/8994)
- Bumped resty.openssl from 0.8.8 to 0.8.10
  [#8592](https://github.com/Kong/kong/pull/8592)
  [#8753](https://github.com/Kong/kong/pull/8753)
  [#9023](https://github.com/Kong/kong/pull/9023)
- Bumped inspect from 3.1.2 to 3.1.3
  [#8589](https://github.com/Kong/kong/pull/8589)
- Bumped resty.acme from 0.7.2 to 0.8.1
  [#8680](https://github.com/Kong/kong/pull/8680)
  [#9165](https://github.com/Kong/kong/pull/9165)
- Bumped luarocks from 3.8.0 to 3.9.1
  [#8700](https://github.com/Kong/kong/pull/8700)
  [#9204](https://github.com/Kong/kong/pull/9204)
- Bumped luasec from 1.0.2 to 1.2.0
  [#8754](https://github.com/Kong/kong/pull/8754)
  [#8754](https://github.com/Kong/kong/pull/9205)
- Bumped resty.healthcheck from 1.5.0 to 1.6.1
  [#8755](https://github.com/Kong/kong/pull/8755)
  [#9018](https://github.com/Kong/kong/pull/9018)
  [#9150](https://github.com/Kong/kong/pull/9150)
- Bumped resty.cassandra from 1.5.1 to 1.5.2
  [#8845](https://github.com/Kong/kong/pull/8845)
- Bumped penlight from 1.12.0 to 1.13.1
  [#9206](https://github.com/Kong/kong/pull/9206)
- Bumped lua-resty-mlcache from 2.5.0 to 2.6.0
  [#9287](https://github.com/Kong/kong/pull/9287)

### Additions

#### Performance

- Do not register unnecessary event handlers on Hybrid mode Control Plane
  nodes [#8452](https://github.com/Kong/kong/pull/8452).
- Use the new timer library to improve performance,
  except for the plugin server.
  [#8912](https://github.com/Kong/kong/pull/8912)
- Increased use of caching for DNS queries by activating `additional_section` by default
  [#8895](https://github.com/Kong/kong/pull/8895)
- `pdk.request.get_header` changed to a faster implementation, not to fetch all headers every time it's called
  [#8716](https://github.com/Kong/kong/pull/8716)
- Conditional rebuilding of router, plugins iterator and balancer on DP
  [#8519](https://github.com/Kong/kong/pull/8519),
  [#8671](https://github.com/Kong/kong/pull/8671)
- Made config loading code more cooperative by yielding
  [#8888](https://github.com/Kong/kong/pull/8888)
- Use LuaJIT encoder instead of JSON to serialize values faster in LMDB
  [#8942](https://github.com/Kong/kong/pull/8942)
- Move inflating and JSON decoding non-concurrent, which avoids blocking and makes DP reloads faster
  [#8959](https://github.com/Kong/kong/pull/8959)
- Stop duplication of some events
  [#9082](https://github.com/Kong/kong/pull/9082)
- Improve performance of config hash calculation by using string buffer and tablepool
  [#9073](https://github.com/Kong/kong/pull/9073)
- Reduce cache usage in dbless by not using the kong cache for Routes and Services in LMDB
  [#8972](https://github.com/Kong/kong/pull/8972)


#### Core

- Implemented delayed response in stream mode
  [#6878](https://github.com/Kong/kong/pull/6878)
- Added `cache_key` on target entity for uniqueness detection.
  [#8179](https://github.com/Kong/kong/pull/8179)
- Introduced the tracing API which compatible with OpenTelemetry API spec and
  add build-in instrumentations.
  The tracing API is intend to be used with a external exporter plugin.
  Build-in instrumentation types and sampling rate are configuable through
  `opentelemetry_tracing` and `opentelemetry_tracing_sampling_rate` options.
  [#8724](https://github.com/Kong/kong/pull/8724)
- Added `path`, `uri_capture`, and `query_arg` options to upstream `hash_on`
  for load balancing.
  [#8701](https://github.com/Kong/kong/pull/8701)
- Introduced unix domain socket based `lua-resty-events` to
  replace shared memory based `lua-resty-worker-events`.
  [#8890](https://github.com/Kong/kong/pull/8890)
- Introduced a new router implementation `atc-router`,
  which is written in Rust.
  [#8938](https://github.com/Kong/kong/pull/8938)
- Introduce a new field for entities `table_name` that allows to specify a
  table name. Before the name was deduced by the entity `name` attribute.
  [#9182](https://github.com/Kong/kong/pull/9182)
- Added `headers` on active healthcheck for upstreams.
  [#8255](https://github.com/Kong/kong/pull/8255)
- Target entities using hostnames were resolved when they were not needed. Now
  when a target is removed or updated, the DNS record associated with it is
  removed from the list of hostnames to be resolved.
  [#8497](https://github.com/Kong/kong/pull/8497) [9265](https://github.com/Kong/kong/pull/9265)
- Improved error handling and debugging info in the DNS code
  [#8902](https://github.com/Kong/kong/pull/8902)
- Kong will now attempt to recover from an unclean shutdown by detecting and
  removing dangling unix sockets in the prefix directory
  [#9254](https://github.com/Kong/kong/pull/9254)

#### Admin API

- Added a new API `/timers` to get the timer statistics.
  [#8912](https://github.com/Kong/kong/pull/8912)
  and worker info
  [#8999](https://github.com/Kong/kong/pull/8999)
- `/` endpoint now includes plugin priority
  [#8821](https://github.com/Kong/kong/pull/8821)

#### Hybrid Mode

- Add wRPC protocol support. Now configuration synchronization is over wRPC.
  wRPC is an RPC protocol that encodes with ProtoBuf and transports
  with WebSocket.
  [#8357](https://github.com/Kong/kong/pull/8357)
- To keep compatibility with earlier versions,
  add support for CP to fall back to the previous protocol to support old DP.
  [#8834](https://github.com/Kong/kong/pull/8834)
- Add support to negotiate services supported with wRPC protocol.
  We will support more services than config sync over wRPC in the future.
  [#8926](https://github.com/Kong/kong/pull/8926)
- Declarative config exports happen inside a transaction in Postgres
  [#8586](https://github.com/Kong/kong/pull/8586)

#### Plugins

- Sync all plugin versions to the Kong version
  [#8772](https://github.com/Kong/kong/pull/8772)
- Introduced the new **OpenTelemetry** plugin that export tracing instrumentations
  to any OTLP/HTTP compatible backend.
  `opentelemetry_tracing` configuration should be enabled to collect
  the core tracing spans of Kong.
  [#8826](https://github.com/Kong/kong/pull/8826)
- **Zipkin**: add support for including HTTP path in span name
  through configuration property `http_span_name`.
  [#8150](https://github.com/Kong/kong/pull/8150)
- **Zipkin**: add support for socket connect and send/read timeouts
  through configuration properties `connect_timeout`, `send_timeout`,
  and `read_timeout`. This can help mitigate `ngx.timer` saturation
  when upstream collectors are unavailable or slow.
  [#8735](https://github.com/Kong/kong/pull/8735)
- **AWS-Lambda**: add support for cross account invocation through
  configuration properties `aws_assume_role_arn` and
  `aws_role_session_name`.[#8900](https://github.com/Kong/kong/pull/8900)
  [#8900](https://github.com/Kong/kong/pull/8900)
- **AWS-Lambda**: accept string type `statusCode` as valid return when
  working in proxy integration mode.
  [#8765](https://github.com/Kong/kong/pull/8765)
- **AWS-Lambda**: separate aws credential cache by IAM role ARN
  [#8907](https://github.com/Kong/kong/pull/8907)
- **Statsd**: :fireworks: **Newly open-sourced plugin capabilities**: All capabilities of [Statsd Advanced](https://docs.konghq.com/hub/kong-inc/statsd-advanced/) are now bundled in [Statsd](https://docs.konghq.com/hub/kong-inc/statsd).
  [#9046](https://github.com/Kong/kong/pull/9046)

#### Configuration

- A new configuration item (`openresty_path`) has been added to allow
  developers/operators to specify the OpenResty installation to use when
  running Kong (instead of using the system-installed OpenResty)
  [#8412](https://github.com/Kong/kong/pull/8412)
- Add `ipv6only` to listen options (e.g. `KONG_PROXY_LISTEN`)
  [#9225](https://github.com/Kong/kong/pull/9225)
- Add `so_keepalive` to listen options (e.g. `KONG_PROXY_LISTEN`)
  [#9225](https://github.com/Kong/kong/pull/9225)
- Add LMDB dbless config persistence and removed the JSON based
  config cache for faster startup time
  [#8670](https://github.com/Kong/kong/pull/8670)
- `nginx_events_worker_connections=auto` has a lower bound of 1024
  [#9276](https://github.com/Kong/kong/pull/9276)
- `nginx_main_worker_rlimit_nofile=auto` has a lower bound of 1024
  [#9276](https://github.com/Kong/kong/pull/9276)

#### PDK

- Added new PDK function: `kong.request.get_start_time()`
  [#8688](https://github.com/Kong/kong/pull/8688)
- `kong.db.*.cache_key()` falls back to `.id` if nothing from `cache_key` is found
  [#8553](https://github.com/Kong/kong/pull/8553)

### Fixes

#### Core

- The schema validator now correctly converts `null` from declarative
  configurations to `nil`.
  [#8483](https://github.com/Kong/kong/pull/8483)
- Only reschedule router and plugin iterator timers after finishing previous
  execution, avoiding unnecessary concurrent executions.
  [#8567](https://github.com/Kong/kong/pull/8567)
- External plugins now handle returned JSON with null member correctly.
  [#8611](https://github.com/Kong/kong/pull/8611)
- Fixed an issue where the address of the environ variable could change but the code didn't
  assumed it was fixed after init
  [#8581](https://github.com/Kong/kong/pull/8581)
- Fix issue where the Go plugin server instance would not be updated after
  a restart (e.g., upon a plugin server crash).
  [#8547](https://github.com/Kong/kong/pull/8547)
- Fixed an issue on trying to reschedule the DNS resolving timer when Kong was
  being reloaded.
  [#8702](https://github.com/Kong/kong/pull/8702)
- The private stream API has been rewritten to allow for larger message payloads
  [#8641](https://github.com/Kong/kong/pull/8641)
- Fixed an issue that the client certificate sent to upstream was not updated when calling PATCH Admin API
  [#8934](https://github.com/Kong/kong/pull/8934)
- Fixed an issue where the CP and wRPC modules would cause Kong to crash when calling `export_deflated_reconfigure_payload` without a pcall
  [#8668](https://github.com/Kong/kong/pull/8668)
- Moved all `.proto` files to `/usr/local/kong/include` and ordered by priority.
  [#8914](https://github.com/Kong/kong/pull/8914)
- Fixed an issue that cause unexpected 404 error on creating/updating configs with invalid options
  [#8831](https://github.com/Kong/kong/pull/8831)
- Fixed an issue that causes crashes when calling some PDK APIs
  [#8604](https://github.com/Kong/kong/pull/8604)
- Fixed an issue that cause crashes when go PDK calls return arrays
  [#8891](https://github.com/Kong/kong/pull/8891)
- Plugin servers now shutdowns gracefully when Kong exits
  [#8923](https://github.com/Kong/kong/pull/8923)
- CLI now prompts with `[y/n]` instead of `[Y/n]`, as it does not take `y` as default
  [#9114](https://github.com/Kong/kong/pull/9114)
- Improved the error message when Kong cannot connect to Cassandra on init
  [#8847](https://github.com/Kong/kong/pull/8847)
- Fixed an issue where Vault Subschema wasn't loaded in `off` strategy
  [#9174](https://github.com/Kong/kong/pull/9174)
- The Schema now runs select transformations before process_auto_fields
  [#9049](https://github.com/Kong/kong/pull/9049)
- Fixed an issue where Kong would use too many timers to keep track of upstreams when `worker_consistency`=`eventual`
  [#8694](https://github.com/Kong/kong/pull/8694),
  [#8858](https://github.com/Kong/kong/pull/8858)
- Fixed an issue where it wasn't possible to set target status using only a hostname for targets set only by their hostname
  [#8797](https://github.com/Kong/kong/pull/8797)
- Fixed pagination issue when getting to the second page while iterationg over a foreign key field using the DAO
  [#9255](https://github.com/Kong/kong/pull/9255)
- Fixed an issue where cache entries of some entities were not being properly invalidated after a cascade delete
  [#9261](https://github.com/Kong/kong/pull/9261)
- Running `kong start` when Kong is already running will no longer clobber
  the existing `.kong_env` file [#9254](https://github.com/Kong/kong/pull/9254)


#### Admin API

- Support HTTP/2 when requesting `/status`
  [#8690](https://github.com/Kong/kong/pull/8690)

#### Plugins

- Plugins with colliding priorities have now deterministic sorting based on their name
  [#8957](https://github.com/Kong/kong/pull/8957)
- External Plugins: better handling of the logging when a plugin instance loses the instances_id in an event handler
  [#8652](https://github.com/Kong/kong/pull/8652)
- **ACME**: `auth_method` default value is set to `token`
  [#8565](https://github.com/Kong/kong/pull/8565)
- **ACME**: Added cache for `domains_matcher`
  [#9048](https://github.com/Kong/kong/pull/9048)
- **syslog**: `conf.facility` default value is now set to `user`
  [#8564](https://github.com/Kong/kong/pull/8564)
- **AWS-Lambda**: Removed `proxy_scheme` field from schema
  [#8566](https://github.com/Kong/kong/pull/8566)
- **AWS-Lambda**: Change path from request_uri to upstream_uri, fix uri can not follow the rule defined in the request-transformer configuration
  [#9058](https://github.com/Kong/kong/pull/9058) [#9129](https://github.com/Kong/kong/pull/9129)
- **hmac-auth**: Removed deprecated signature format using `ngx.var.uri`
  [#8558](https://github.com/Kong/kong/pull/8558)
- Remove deprecated `blacklist`/`whitelist` config fields from bot-detection, ip-restriction and ACL plugins.
  [#8560](https://github.com/Kong/kong/pull/8560)
- **Zipkin**: Correct the balancer spans' duration to include the connection time
  from Nginx to the upstream.
  [#8848](https://github.com/Kong/kong/pull/8848)
- **Zipkin**: Correct the calculation of the header filter start time
  [#9230](https://github.com/Kong/kong/pull/9230)
- **Zipkin**: Compatibility with the latest Jaeger header spec, which makes `parent_id` optional
  [#8352](https://github.com/Kong/kong/pull/8352)
- **LDAP-Auth**: Refactored ASN.1 parser using OpenSSL API through FFI.
  [#8663](https://github.com/Kong/kong/pull/8663)
- **Rate-Limiting** and **Response-ratelimiting**: Fix a disordered behaviour caused by `pairs` function
  which may cause Postgres DEADLOCK problem [#8968](https://github.com/Kong/kong/pull/8968)
- **Response-rate-Limiting**: Fix a disordered behaviour caused by `pairs` function
  which may cause Postgres DEADLOCK problem [#8968](https://github.com/Kong/kong/pull/8968)
- **gRPC gateway**: Fix the handling of boolean fields from URI arguments
  [#9180](https://github.com/Kong/kong/pull/9180)
- **Serverless Functions**: Fix problem that could result in a crash
  [#9269](https://github.com/Kong/kong/pull/9269)
- **Azure-functions**: Support working without dummy service
  [#9177](https://github.com/Kong/kong/pull/9177)


#### Clustering

- The cluster listener now uses the value of `admin_error_log` for its log file
  instead of `proxy_error_log` [#8583](https://github.com/Kong/kong/pull/8583)
- Fixed a typo in some business logic that checks the Kong role before setting a
  value in cache at startup [#9060](https://github.com/Kong/kong/pull/9060)
- Fixed DP get zero size config while service with plugin-enabled route is disabled
  [#8816](https://github.com/Kong/kong/pull/8816)
- Localize `config_version` to avoid a race condition from the new yielding config loading code
  [#8188](https://github.com/Kong/kong/pull/8818)

#### PDK

- `kong.response.get_source()` now return an error instead of an exit when plugin throws
  runtime exception on access phase [#8599](https://github.com/Kong/kong/pull/8599)
- `kong.tools.uri.normalize()` now does escaping of reserved and unreserved characters more correctly
  [#8140](https://github.com/Kong/kong/pull/8140)

## Previous releases

Please see [CHANGELOG-OLD.md](CHANGELOG-OLD.md) file for < 3.0 releases.

[Back to TOC](#table-of-contents)

[3.3.0]: https://github.com/Kong/kong/compare/3.2.0...3.3.0
[3.2.0]: https://github.com/Kong/kong/compare/3.1.0...3.2.0
[3.1.0]: https://github.com/Kong/kong/compare/3.0.1...3.1.0
[3.0.1]: https://github.com/Kong/kong/compare/3.0.0...3.0.1
[3.0.0]: https://github.com/Kong/kong/compare/2.8.1...3.0.0
