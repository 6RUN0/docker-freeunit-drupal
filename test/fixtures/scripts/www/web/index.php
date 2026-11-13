<?php

// Front controller of the scripts test site: /health answers 500 unless the
// request carries X-Forwarded-Proto: https, /slow takes 5 s, any other path
// reports what the worker sees.
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
if ($path === '/health') {
    if (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') !== 'https') {
        http_response_code(500);
    }
    echo 'health';
    return;
}
if ($path === '/slow') {
    sleep(5);
    echo 'slow';
    return;
}
echo 'fd-index uri=', $_SERVER['REQUEST_URI'] ?? '',
    ' env=', var_export(getenv('FD_PROBE'), true),
    ' sendmail=', ini_get('sendmail_path'),
    ' body=', strlen((string) file_get_contents('php://input')), "\n";
