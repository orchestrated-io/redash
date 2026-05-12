import json
import logging

from flask import Blueprint, flash, redirect, request, url_for
from saml2 import BINDING_HTTP_POST, BINDING_HTTP_REDIRECT, entity
from saml2.client import Saml2Client
from saml2.config import Config as Saml2Config
from saml2.saml import NAMEID_FORMAT_TRANSIENT
from saml2.sigver import get_xmlsec_binary

from redash import settings
from redash.authentication import (
    create_and_login_user,
    logout_and_redirect_to_index,
)
from redash.authentication.org_resolving import current_org
from redash.handlers.base import org_scoped_rule
from redash.utils import mustache_render

logger = logging.getLogger("saml_auth")
blueprint = Blueprint("saml_auth", __name__)


def _saml_http_request_summary():
    """Safe request metadata for logs (no form secrets)."""
    return {
        "method": request.method,
        "path": request.path,
        "query_string": request.query_string.decode("utf-8", errors="replace")[:500]
        if getattr(request, "query_string", None)
        else "",
        "content_type": request.content_type,
        "content_length": request.content_length,
        "remote_addr": request.remote_addr,
        "X-Forwarded-For": request.headers.get("X-Forwarded-For"),
        "X-Real-IP": request.headers.get("X-Real-IP"),
        "user_agent": (request.headers.get("User-Agent") or "")[:300],
    }


def _saml_form_summary():
    """Form shape for ACS debugging; does not log raw SAMLResponse."""
    keys = list(request.form.keys())
    saml = request.form.get("SAMLResponse")
    relay = request.form.get("RelayState")
    return {
        "form_keys": keys,
        "saml_response_present": saml is not None,
        "saml_response_len": len(saml) if saml else 0,
        "relay_state_present": relay is not None,
        "relay_state_len": len(relay) if relay else 0,
    }


def _org_saml_public_settings(org):
    """Non-secret SAML org settings for correlation."""
    return {
        "org_slug": org.slug,
        "auth_saml_enabled": org.get_setting("auth_saml_enabled"),
        "auth_saml_type": org.get_setting("auth_saml_type"),
        "auth_saml_entity_id_configured": bool(org.get_setting("auth_saml_entity_id")),
        "auth_saml_metadata_url_configured": bool(org.get_setting("auth_saml_metadata_url")),
        "auth_saml_sso_url_configured": bool(org.get_setting("auth_saml_sso_url")),
        "auth_saml_sp_settings_configured": bool(org.get_setting("auth_saml_sp_settings")),
    }


def _log_saml_exception(where, exc, **extra):
    """Structured ERROR log with traceback and request/org context."""
    payload = {
        "where": where,
        "exc_type": type(exc).__name__,
        "exc_msg": str(exc),
        "http": _saml_http_request_summary(),
        **extra,
    }
    logger.error("SAML diagnostic failure | %s", json.dumps(payload, default=str), exc_info=exc)


inline_metadata_template = """<?xml version="1.0" encoding="UTF-8"?><md:EntityDescriptor entityID="{{entity_id}}" xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata"><md:IDPSSODescriptor WantAuthnRequestsSigned="false" protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol"><md:KeyDescriptor use="signing"><ds:KeyInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><ds:X509Data><ds:X509Certificate>{{x509_cert}}</ds:X509Certificate></ds:X509Data></ds:KeyInfo></md:KeyDescriptor><md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="{{sso_url}}"/><md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="{{sso_url}}"/></md:IDPSSODescriptor></md:EntityDescriptor>"""


def get_saml_client(org):
    """
    Return SAML configuration.

    The configuration is a hash for use by saml2.config.Config
    """

    saml_type = org.get_setting("auth_saml_type")
    entity_id = org.get_setting("auth_saml_entity_id")
    sso_url = org.get_setting("auth_saml_sso_url")
    x509_cert = org.get_setting("auth_saml_x509_cert")
    metadata_url = org.get_setting("auth_saml_metadata_url")
    sp_settings = org.get_setting("auth_saml_sp_settings")

    if settings.SAML_SCHEME_OVERRIDE:
        acs_url = url_for(
            "saml_auth.idp_initiated",
            org_slug=org.slug,
            _external=True,
            _scheme=settings.SAML_SCHEME_OVERRIDE,
        )
    else:
        acs_url = url_for("saml_auth.idp_initiated", org_slug=org.slug, _external=True)

    saml_settings = {
        "metadata": {"remote": [{"url": metadata_url}]},
        "service": {
            "sp": {
                "endpoints": {
                    "assertion_consumer_service": [
                        (acs_url, BINDING_HTTP_REDIRECT),
                        (acs_url, BINDING_HTTP_POST),
                    ]
                },
                # Don't verify that the incoming requests originate from us via
                # the built-in cache for authn request ids in pysaml2
                "allow_unsolicited": True,
                # Don't sign authn requests, since signed requests only make
                # sense in a situation where you control both the SP and IdP
                "authn_requests_signed": False,
                "logout_requests_signed": True,
                "want_assertions_signed": True,
                "want_response_signed": False,
            }
        },
    }

    if settings.SAML_ENCRYPTION_ENABLED:
        encryption_dict = {
            "xmlsec_binary": get_xmlsec_binary(),
            "encryption_keypairs": [
                {
                    "key_file": settings.SAML_ENCRYPTION_PEM_PATH,
                    "cert_file": settings.SAML_ENCRYPTION_CERT_PATH,
                }
            ],
        }
        saml_settings.update(encryption_dict)

    if saml_type is not None and saml_type == "static":
        metadata_inline = mustache_render(
            inline_metadata_template,
            entity_id=entity_id,
            x509_cert=x509_cert,
            sso_url=sso_url,
        )

        saml_settings["metadata"] = {"inline": [metadata_inline]}

    if entity_id is not None and entity_id != "":
        saml_settings["entityid"] = entity_id

    if sp_settings:
        import json

        saml_settings["service"]["sp"].update(json.loads(sp_settings))

    sp_config = Saml2Config()
    sp_config.load(saml_settings)
    sp_config.allow_unknown_attributes = True
    saml_client = Saml2Client(config=sp_config)

    return saml_client


@blueprint.route(org_scoped_rule("/saml/callback"), methods=["POST"])
def idp_initiated(org_slug=None):
    if not current_org.get_setting("auth_saml_enabled"):
        logger.error("SAML Login is not enabled")
        return redirect(url_for("redash.index", org_slug=org_slug))

    logger.info(
        "SAML ACS POST received | org=%s | %s | %s",
        org_slug,
        json.dumps(_org_saml_public_settings(current_org), default=str),
        json.dumps({**_saml_http_request_summary(), "form": _saml_form_summary()}, default=str),
    )

    try:
        saml_client = get_saml_client(current_org)
    except Exception as e:
        acs_url = (
            url_for(
                "saml_auth.idp_initiated",
                org_slug=org_slug,
                _external=True,
                _scheme=settings.SAML_SCHEME_OVERRIDE,
            )
            if settings.SAML_SCHEME_OVERRIDE
            else url_for("saml_auth.idp_initiated", org_slug=org_slug, _external=True)
        )
        _log_saml_exception(
            "get_saml_client",
            e,
            org=_org_saml_public_settings(current_org),
            assertion_consumer_service_url=acs_url,
        )
        flash("SAML login failed. Please try again later.")
        return redirect(url_for("redash.login", org_slug=org_slug))

    try:
        saml_response_b64 = request.form["SAMLResponse"]
    except KeyError as e:
        _log_saml_exception(
            "missing_SAMLResponse",
            e,
            org=_org_saml_public_settings(current_org),
            form=_saml_form_summary(),
        )
        flash("SAML login failed. Please try again later.")
        return redirect(url_for("redash.login", org_slug=org_slug))

    try:
        authn_response = saml_client.parse_authn_request_response(saml_response_b64, entity.BINDING_HTTP_POST)
    except Exception as e:
        _log_saml_exception(
            "parse_authn_request_response",
            e,
            org=_org_saml_public_settings(current_org),
            form=_saml_form_summary(),
        )
        flash("SAML login failed. Please try again later.")
        return redirect(url_for("redash.login", org_slug=org_slug))

    try:
        authn_response.get_identity()
        user_info = authn_response.get_subject()
        email = user_info.text
        ava = getattr(authn_response, "ava", None) or {}
        ava_keys = list(ava.keys())
        name = "%s %s" % (
            authn_response.ava["FirstName"][0],
            authn_response.ava["LastName"][0],
        )
    except Exception as e:
        ava = getattr(authn_response, "ava", None) or {}
        _log_saml_exception(
            "extract_identity_or_name_from_assertion",
            e,
            org=_org_saml_public_settings(current_org),
            ava_keys=list(ava.keys()),
            has_name_id=bool(getattr(authn_response, "name_id", None)),
        )
        flash("SAML login failed. Please try again later.")
        return redirect(url_for("redash.login", org_slug=org_slug))

    # This is what as known as "Just In Time (JIT) provisioning".
    # What that means is that, if a user in a SAML assertion
    # isn't in the user store, we create that user first, then log them in
    try:
        user = create_and_login_user(current_org, name, email)
    except Exception as e:
        _log_saml_exception(
            "create_and_login_user",
            e,
            org=_org_saml_public_settings(current_org),
            email=email,
            name=name,
            ava_keys=ava_keys,
        )
        flash("SAML login failed. Please try again later.")
        return redirect(url_for("redash.login", org_slug=org_slug))

    if user is None:
        logger.error(
            "SAML login rejected: create_and_login_user returned None | org=%s email=%s ava_keys=%s",
            org_slug,
            email,
            ava_keys,
        )
        return logout_and_redirect_to_index()

    if "RedashGroups" in authn_response.ava:
        group_names = authn_response.ava.get("RedashGroups")
        try:
            user.update_group_assignments(group_names)
        except Exception as e:
            _log_saml_exception(
                "update_group_assignments",
                e,
                org=_org_saml_public_settings(current_org),
                email=email,
                group_raw_type=type(group_names).__name__,
            )
            flash("SAML login failed. Please try again later.")
            return redirect(url_for("redash.login", org_slug=org_slug))

    url = url_for("redash.index", org_slug=org_slug)
    logger.info(
        "SAML login success, redirecting to app | org=%s email=%s ava_keys=%s",
        org_slug,
        email,
        ava_keys,
    )
    return redirect(url)


@blueprint.route(org_scoped_rule("/saml/login"))
def sp_initiated(org_slug=None):
    if not current_org.get_setting("auth_saml_enabled"):
        logger.error("SAML Login is not enabled")
        return redirect(url_for("redash.index", org_slug=org_slug))

    logger.info(
        "SAML SP-initiated login GET | org=%s | %s | %s",
        org_slug,
        json.dumps(_org_saml_public_settings(current_org), default=str),
        json.dumps(_saml_http_request_summary(), default=str),
    )

    try:
        saml_client = get_saml_client(current_org)
    except Exception as e:
        _log_saml_exception(
            "sp_initiated_get_saml_client",
            e,
            org=_org_saml_public_settings(current_org),
        )
        flash("SAML login failed. Please try again later.")
        return redirect(url_for("redash.login", org_slug=org_slug))

    nameid_format = current_org.get_setting("auth_saml_nameid_format")
    if nameid_format is None or nameid_format == "":
        nameid_format = NAMEID_FORMAT_TRANSIENT

    try:
        _, info = saml_client.prepare_for_authenticate(nameid_format=nameid_format)
    except Exception as e:
        _log_saml_exception(
            "prepare_for_authenticate",
            e,
            org=_org_saml_public_settings(current_org),
            nameid_format=nameid_format,
        )
        flash("SAML login failed. Please try again later.")
        return redirect(url_for("redash.login", org_slug=org_slug))

    redirect_url = None
    # Select the IdP URL to send the AuthN request to
    for key, value in info.get("headers") or []:
        if key == "Location":
            redirect_url = value

    if not redirect_url:
        logger.error(
            "SAML SP-initiated: no Location header from prepare_for_authenticate | org=%s info_keys=%s headers=%s",
            org_slug,
            list(info.keys()) if isinstance(info, dict) else None,
            info.get("headers") if isinstance(info, dict) else None,
        )
        flash("SAML login failed. Please try again later.")
        return redirect(url_for("redash.login", org_slug=org_slug))

    logger.info("SAML SP-initiated: redirect 302 to IdP | org=%s idp_location_host=%s", org_slug, redirect_url[:80])
    response = redirect(redirect_url, code=302)

    # NOTE:
    #   I realize I _technically_ don't need to set Cache-Control or Pragma:
    #     https://stackoverflow.com/a/5494469
    #   However, Section 3.2.3.2 of the SAML spec suggests they are set:
    #     http://docs.oasis-open.org/security/saml/v2.0/saml-bindings-2.0-os.pdf
    #   We set those headers here as a "belt and suspenders" approach,
    #   since enterprise environments don't always conform to RFCs
    response.headers["Cache-Control"] = "no-cache, no-store"
    response.headers["Pragma"] = "no-cache"
    return response
