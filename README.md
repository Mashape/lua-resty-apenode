[![][kong-logo]][kong-url]

![Stars](https://img.shields.io/github/stars/Kong/kong?style=flat-square) ![GitHub commit activity](https://img.shields.io/github/commit-activity/m/Kong/kong?style=flat-square) ![Docker Pulls](https://img.shields.io/docker/pulls/_/kong?style=flat-square) [![Build Status][badge-action-image]][badge-action-url] ![Version](https://img.shields.io/github/v/release/Kong/kong?color=green&label=Version&style=flat-square)  ![License](https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square)  ![Twitter Follow](https://img.shields.io/twitter/follow/thekonginc?style=social)


**Kong** or **Kong API Gateway** is a cloud-native, platform-agnostic, scalable API Gateway distinguished for its high performance and extensibility via plugins. It also provides advanced AI capabilities with multi-LLM support.

By providing functionality for proxying, routing, load balancing, health checking, authentication (and [more](#features)), Kong serves as the central layer for orchestrating microservices or conventional API traffic with ease.

Kong runs natively on Kubernetes thanks to its official [Kubernetes Ingress Controller](https://github.com/Kong/kubernetes-ingress-controller).

---

[Installation](https://konghq.com/install/#kong-community) | [Documentation](https://docs.konghq.com) | [Discussions](https://github.com/Kong/kong/discussions) | [Forum](https://discuss.konghq.com) | [Blog](https://konghq.com/blog) | [Builds][kong-master-builds] | [Cloud Hosted Kong](https://konghq.com/kong-konnect/)

---

## Getting Started

If you prefer to use a cloud-hosted Kong, you can [sign up for a free trial of Kong Konnect](https://konghq.com/products/kong-konnect/register?utm_medium=Referral&utm_source=Github&utm_campaign=kong-gateway&utm_content=konnect-promo-in-gateway&utm_term=get-started) and get started in minutes. If not, you can follow the instructions below to get started with Kong on your own infrastructure.

Let’s test drive Kong by adding authentication to an API in under 5 minutes.

We suggest using the docker-compose distribution via the instructions below, but there is also a [docker installation](https://docs.konghq.com/gateway/latest/install/docker/#install-kong-gateway-in-db-less-mode) procedure if you’d prefer to run the Kong API Gateway in DB-less mode.

Whether you’re running in the cloud, on bare metal, or using containers, you can find every supported distribution on our [official installation](https://konghq.com/install/#kong-community) page.

1) To start, clone the Docker repository and navigate to the compose folder.
```cmd
  $ git clone https://github.com/Kong/docker-kong
  $ cd docker-kong/compose/
```

2) Start the Gateway stack using:
```cmd
  $ KONG_DATABASE=postgres docker-compose --profile database up
```

The Gateway is now available on the following ports on localhost:

- `:8000` - send traffic to your service via Kong
- `:8001` - configure Kong using Admin API or via [decK](https://github.com/kong/deck)
- `:8002` - access Kong's management Web UI ([Kong Manager](https://github.com/Kong/kong-manager)) on [localhost:8002](http://localhost:8002)

Next, follow the [quick start guide](https://docs.konghq.com/gateway-oss/latest/getting-started/configuring-a-service/
) to tour the Gateway features.

## Features

By centralizing common API functionality across all your organization's services, the Kong API Gateway creates more freedom for engineering teams to focus on the challenges that matter most.

The top Kong features include:
- Advanced routing, load balancing, health checking - all configurable via a RESTful admin API or declarative configuration.
- Authentication and authorization for APIs using methods like JWT, basic auth, OAuth, ACLs and more.
- Proxy, SSL/TLS termination, and connectivity support for L4 or L7 traffic.
- Plugins for enforcing traffic controls, rate limiting, req/res transformations, logging, monitoring and including a plugin developer hub.
- Plugins for AI traffic to support multi-LLM implementations and no-code AI use cases, with advanced AI prompt engineering, AI observability, AI security and more.
- Sophisticated deployment models like Declarative Databaseless Deployment and Hybrid Deployment (control plane/data plane separation) without any vendor lock-in.
- Native [ingress controller](https://github.com/Kong/kubernetes-ingress-controller) support for serving Kubernetes.

[![][kong-benefits]][kong-url]

### Plugin Hub
Plugins provide advanced functionality that extends the use of the Gateway. Many of the Kong Inc. and community-developed plugins like AWS Lambda, Correlation ID, and Response Transformer are showcased at the [Plugin Hub](https://docs.konghq.com/hub/).

Contribute to the Plugin Hub and ensure your next innovative idea is published and available to the broader community!

## Contributing

We ❤️ pull requests, and we’re continually working hard to make it as easy as possible for developers to contribute. Before beginning development with the Kong API Gateway, please familiarize yourself with the following developer resources:
- Community Pledge ([COMMUNITY_PLEDGE.md](COMMUNITY_PLEDGE.md)) for our pledge to interact with you, the open source community.
- Contributor Guide ([CONTRIBUTING.md](CONTRIBUTING.md)) to learn about how to contribute to Kong.
- Development Guide ([DEVELOPER.md](DEVELOPER.md)): Setting up your development environment.
- [CODE_OF_CONDUCT](CODE_OF_CONDUCT.md) and [COPYRIGHT](COPYRIGHT)

Use the [Plugin Development Guide](https://docs.konghq.com/latest/plugin-development/) for building new and creative plugins, or browse the online version of Kong's source code documentation in the [Plugin Development Kit (PDK) Reference](https://docs.konghq.com/latest/pdk/). Developers can build plugins in [Lua](https://docs.konghq.com/gateway/latest/plugin-development/), [Go](https://docs.konghq.com/gateway-oss/latest/external-plugins/#developing-go-plugins) or [JavaScript](https://docs.konghq.com/gateway-oss/latest/external-plugins/#developing-javascript-plugins).

## Releases

Please see the [Changelog](CHANGELOG.md) for more details about a given release. The [SemVer Specification](https://semver.org) is followed when versioning Gateway releases.

## Join the Community

- Check out the [docs](https://docs.konghq.com/)
- Join the [Kong discussions forum](https://github.com/Kong/kong/discussions)
- Join the Kong discussions at the Kong Nation forum: [https://discuss.konghq.com/](https://discuss.konghq.com/)
- Join our [Community Slack](http://kongcommunity.slack.com/)
- Read up on the latest happenings at our [blog](https://konghq.com/blog/)
- Follow us on [X](https://x.com/thekonginc)
- Subscribe to our [YouTube channel](https://www.youtube.com/c/KongInc/videos)
- Visit our [homepage](https://konghq.com/) to learn more

## Konnect Cloud

Kong Inc. offers commercial subscriptions that enhance the Kong API Gateway in a variety of ways. Customers of Kong's [Konnect Cloud](https://konghq.com/kong-konnect/) subscription take advantage of additional gateway functionality, commercial support, and access to Kong's managed (SaaS) control plane platform. The Konnect Cloud platform features include real-time analytics, a service catalog, developer portals, and so much more! [Get started](https://konghq.com/products/kong-konnect/register?utm_medium=Referral&utm_source=Github&utm_campaign=kong-gateway&utm_content=konnect-promo-in-gateway&utm_term=get-started) with Konnect Cloud.

## License

```
Copyright 2016-2025 Kong Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

[kong-url]: https://konghq.com/
[kong-logo]: https://konghq.com/wp-content/uploads/2018/05/kong-logo-github-readme.png
[kong-benefits]: https://konghq.com/wp-content/uploads/2018/05/kong-benefits-github-readme.png
[kong-master-builds]: https://hub.docker.com/r/kong/kong/tags
[badge-action-url]: https://github.com/Kong/kong/actions
[badge-action-image]: https://github.com/Kong/kong/workflows/Build%20&%20Test/badge.svg

[busted]: https://github.com/Olivine-Labs/busted
[luacheck]: https://github.com/mpeterv/luacheck
