vcl 4.1;

import reqwest;

# A plain backend resolves "unit" once, when the VCL loads; the reqwest client
# resolves it per connection, so a recreated unit with another address is
# found without restarting Varnish. Its probe sends Host unit:8080 and cannot
# set another, which trusted_host_patterns rejects: it asks a static file.
probe unit_probe {
    .url = "/core/misc/drupal.js";
    .interval = 5s;
    .timeout = 5s;
    .window = 3;
    .threshold = 2;
    .initial = 1;
}

backend default none;

sub vcl_init {
    # follow = 0: redirects go to the client. No auto_*: Varnish handles the
    # encodings itself. No timeout: the client has only a limit on the whole
    # request, body included, which would cut long uploads and downloads;
    # Unit bounds PHP (limits.timeout of the image template, 60 s).
    new unit = reqwest.client(
        base_url = "http://unit:8080",
        follow = 0,
        auto_gzip = false,
        auto_deflate = false,
        auto_brotli = false,
        connect_timeout = 5s,
        probe = unit_probe);
}

include "common.vcl";
