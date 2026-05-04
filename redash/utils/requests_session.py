import ipaddress
import socket
from urllib.parse import urlparse

import requests

from redash import settings


class UnacceptableAddressException(requests.RequestException):
    """Raised when a URL resolves to a non-public address and blocking is enabled."""


def _assert_public_http_url(url: str) -> None:
    """Block SSRF to private/reserved addresses (http/https only)."""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise UnacceptableAddressException(f"Only http(s) URLs are allowed, got scheme {parsed.scheme!r}")
    host = parsed.hostname
    if not host:
        raise UnacceptableAddressException("URL has no host")

    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        addr = None

    if addr is not None:
        if not addr.is_global:
            raise UnacceptableAddressException(f"Address {addr} is not a global unicast address")
        return

    try:
        infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    except OSError as exc:
        raise UnacceptableAddressException(f"Could not resolve host {host!r}: {exc}") from exc

    ips = []
    for family, _, _, _, sockaddr in infos:
        if family == socket.AF_INET:
            ips.append(ipaddress.ip_address(sockaddr[0]))
        elif family == socket.AF_INET6:
            ips.append(ipaddress.ip_address(sockaddr[0]))

    if not ips:
        raise UnacceptableAddressException(f"No IP addresses resolved for host {host!r}")

    for ip in ips:
        if not ip.is_global:
            raise UnacceptableAddressException(f"Host {host!r} resolves to non-public address {ip}")


# Exposed as `requests` so callers can use HTTPError, RequestException, get(), etc.
requests_or_advocate = requests


class ConfiguredSession(requests.Session):
    def request(self, method, url, *args, **kwargs):
        if settings.ENFORCE_PRIVATE_ADDRESS_BLOCK:
            _assert_public_http_url(url)
        if not settings.REQUESTS_ALLOW_REDIRECTS:
            kwargs["allow_redirects"] = False
        return super().request(method, url, *args, **kwargs)


requests_session = ConfiguredSession()
