#
# Shared VCL of the example. The including file defines the probe and the
# reqwest client `unit`, whose backend() serves every request.
#
# There is no front proxy: every forwarding header a client sends is dropped
# and X-Forwarded-For is the client address, so a client cannot pick the IP
# Drupal sees or the host and port of the links it builds. A site behind a TLS
# front adds an ACL for that front and trusts its X-Real-IP and
# X-Forwarded-Proto only (README, "Behind a TLS front").
#

import std;

acl allow_purge {
    "10.0.0.0"/8;
    "172.16.0.0"/12;
    "192.168.0.0"/16;
}

sub vcl_recv {
    set req.backend_hint = unit.backend();

    unset req.http.X-Real-IP;
    unset req.http.X-Forwarded-Host;
    unset req.http.X-Forwarded-Port;
    unset req.http.X-Forwarded-Proto;
    unset req.http.Forwarded;
    set req.http.X-Forwarded-For = client.ip;

    # BAN is accepted on the purge listener only, which compose does not
    # publish; the ACL keeps out a listener exposed by mistake.
    if (local.socket == "purge") {
        if (req.method != "BAN" || !client.ip ~ allow_purge) {
            return (synth(405, "Not allowed."));
        }
        # An empty alternative (a leading, doubled or trailing |) would match
        # every object of the host.
        if (req.http.Cache-Tags !~ "^[A-Za-z0-9_.:-]+(\|[A-Za-z0-9_.:-]+)*$") {
            return (synth(400, "Invalid Cache-Tags."));
        }
        if (req.http.Cache-Host !~ "^[A-Za-z0-9.-]+$") {
            return (synth(400, "Invalid Cache-Host."));
        }
        # While the backend is down Varnish serves stale objects; banning them
        # would turn those hits into errors. The purge queue retries. "Down"
        # is what the probe sees: Unit not answering, not a Drupal error.
        if (!std.healthy(unit.backend())) {
            return (synth(403, "Backend down, refusing BAN to preserve stale cache."));
        }
        # A tag is matched whole and literally: its dots are escaped, the
        # alternatives anchored at the separating spaces.
        if (std.ban("obj.http.X-Host == " + req.http.Cache-Host +
            " && obj.http.X-Drupal-Cache-Tags ~ (^|[[:space:]])(" +
            regsuball(req.http.Cache-Tags, "\.", "\\.") + ")([[:space:]]|$)")) {
            return (synth(200, "Banned."));
        }
        return (synth(400, std.ban_error()));
    }
    if (req.method == "BAN") {
        return (synth(405, "Not allowed."));
    }

    # Drupal checks the host against trusted_host_patterns.
    set req.http.Host = regsub(req.http.Host, ":[0-9]+$", "");

    # httpoxy, https://httpoxy.org/
    unset req.http.proxy;

    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    set req.url = std.querysort(req.url);
    set req.url = regsuball(req.url, "(?<=[?&])(utm_[a-z]+|gclid|fbclid|_gl)=[^&]*&?", "");
    set req.url = regsub(req.url, "[?&]$", "");

    # Static assets are the same for every user; private files
    # (/system/files) depend on the session.
    if (req.http.Cookie && req.url !~ "^/system/files" &&
        req.url ~ "(?i)\.(css|js|jpg|jpeg|png|gif|svg|webp|ico|woff2?|ttf|otf|eot|mp3|mp4|pdf|zip)(\?.*)?$") {
        unset req.http.Cookie;
    }

    # Only the Drupal session cookies (SESS*, SSESS*) and NO_CACHE make a
    # request user-specific; every other cookie is dropped.
    if (req.http.Cookie) {
        set req.http.Cookie = ";" + req.http.Cookie;
        set req.http.Cookie = regsuball(req.http.Cookie, "; +", ";");
        set req.http.Cookie = regsuball(req.http.Cookie, ";(SS?ESS[a-z0-9]+|NO_CACHE)=", "; \1=");
        set req.http.Cookie = regsuball(req.http.Cookie, ";[^ ][^;]*", "");
        set req.http.Cookie = regsuball(req.http.Cookie, "^[; ]+|[; ]+$", "");
        if (req.http.Cookie ~ "^\s*$") {
            unset req.http.Cookie;
        } else {
            return (pass);
        }
    }

    if (req.http.Authorization) {
        return (pass);
    }
}

sub vcl_backend_response {
    # Serve stale for up to a day while the backend is down.
    set beresp.grace = 24h;

    if (beresp.status >= 500) {
        # A background fetch must not replace the stale object with the error.
        if (bereq.is_bgfetch) {
            return (abandon);
        }
        set beresp.ttl = 10s;
        set beresp.uncacheable = true;
        return (deliver);
    }

    # Only a found file: a 404 carries no cache tag, and no ban would lift it.
    if (beresp.status == 200 &&
        bereq.url ~ "\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif)(\?.*)?$") {
        set beresp.ttl = 7d;
        unset beresp.http.Set-Cookie;
    }

    if (beresp.ttl <= 0s || beresp.http.Set-Cookie) {
        set beresp.uncacheable = true;
    }

    # Answers conditional requests with 304 without a backend fetch.
    set beresp.keep = 1h;
    # X-Host is matched by the bans above; both are stripped in vcl_deliver.
    set beresp.http.X-Url = bereq.url;
    set beresp.http.X-Host = bereq.http.host;
}

sub vcl_backend_error {
    if (bereq.is_bgfetch) {
        return (abandon);
    }
    if (bereq.retries < 1) {
        return (retry);
    }
    set beresp.http.Content-Type = "text/html; charset=utf-8";
    set beresp.http.Retry-After = "5";
    synthetic({"<!DOCTYPE html>
<html><head><title>"} + beresp.status + {" "} + beresp.reason + {"</title></head>
<body><h1>"} + beresp.status + {" "} + beresp.reason + {"</h1></body>
</html>"});
    return (deliver);
}

sub vcl_synth {
    set resp.http.Content-Type = "text/html; charset=utf-8";
    if (resp.status >= 500) {
        set resp.http.Retry-After = "5";
    }
    synthetic({"<!DOCTYPE html>
<html><head><title>"} + resp.status + {" "} + resp.reason + {"</title></head>
<body><h1>"} + resp.status + {" "} + resp.reason + {"</h1></body>
</html>"});
    return (deliver);
}

sub vcl_deliver {
    unset resp.http.Server;
    unset resp.http.X-Powered-By;
    unset resp.http.X-Generator;
    unset resp.http.Via;
    unset resp.http.X-Varnish;
    unset resp.http.X-Url;
    unset resp.http.X-Host;
    # The cacheability headers feed the bans from the stored object; the
    # client does not need them.
    unset resp.http.X-Drupal-Cache-Tags;
    unset resp.http.X-Drupal-Cache-Contexts;
    unset resp.http.X-Drupal-Cache-Max-Age;
    unset resp.http.X-Drupal-Dynamic-Cache;
    unset resp.http.X-Drupal-Cache;
    # HTML may be personalised behind the cache: no client cache, unless the
    # backend asked for the stricter no-store.
    if (resp.http.Content-Type ~ "text/html" && resp.http.Cache-Control !~ "no-store") {
        set resp.http.Cache-Control = "private,no-cache";
    }
    if (obj.hits > 0) {
        set resp.http.X-Cache-Status = "HIT";
    } else {
        set resp.http.X-Cache-Status = "MISS";
    }
}
