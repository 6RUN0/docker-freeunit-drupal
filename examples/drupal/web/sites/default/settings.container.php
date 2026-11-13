<?php

/**
 * @file
 * Deployment settings from the container environment (SITE_*).
 *
 * Unit workers and drush see the container environment through getenv()
 * only: $_ENV and $_SERVER do not carry it. Secrets are files (compose
 * secrets), named by the *_FILE variables. A missing value throws: a site
 * that runs on a default database password or an empty salt is worse than
 * one that does not start.
 */

declare(strict_types=1);

use Symfony\Component\HttpFoundation\Request;

$site_env = static function (string $name, ?string $default = NULL): string {
  $value = getenv($name);
  if ($value === FALSE || $value === '') {
    if ($default === NULL) {
      throw new \RuntimeException("$name is not set");
    }
    return $default;
  }
  return $value;
};

$site_secret = static function (string $name) use ($site_env): string {
  $path = $site_env($name);
  $value = is_readable($path) ? file_get_contents($path) : FALSE;
  if ($value === FALSE) {
    throw new \RuntimeException("$name: cannot read $path");
  }
  $value = trim($value);
  if ($value === '') {
    throw new \RuntimeException("$name: $path is empty");
  }
  return $value;
};

$site_flag = static function (string $name) use ($site_env): bool {
  $value = $site_env($name, '0');
  if ($value !== '0' && $value !== '1') {
    throw new \RuntimeException("$name must be empty, 0 or 1, got '$value'");
  }
  return $value === '1';
};

$settings['hash_salt'] = $site_secret('SITE_HASH_SALT_FILE');

$databases['default']['default'] = [
  'driver' => 'mysql',
  'namespace' => 'Drupal\\mysql\\Driver\\Database\\mysql',
  'autoload' => 'core/modules/mysql/src/Driver/Database/mysql/',
  'host' => $site_env('SITE_DB_HOST'),
  'port' => $site_env('SITE_DB_PORT', '3306'),
  'database' => $site_env('SITE_DB_NAME'),
  'username' => $site_env('SITE_DB_USER'),
  'password' => $site_secret('SITE_DB_PASSWORD_FILE'),
  'prefix' => '',
  'collation' => 'utf8mb4_general_ci',
  'isolation_level' => 'READ COMMITTED',
];

$settings['trusted_host_patterns'] = preg_split('/\s+/', $site_env('SITE_TRUSTED_HOST_PATTERNS', '^localhost$'), -1, PREG_SPLIT_NO_EMPTY);

// Every request reaches Unit through Varnish, which sets X-Forwarded-For to
// the address of its client and drops the other forwarding headers. Trusting
// only that header from only the Varnish addresses keeps a client from
// choosing its own IP (flood control, bans) or host. gethostbyname() would
// return the name itself on a failed lookup and make every visitor the same
// address, hence gethostbynamel() and the exception. drush does not take
// requests, so the CLI does not depend on Varnish being up.
if (PHP_SAPI !== 'cli') {
  $site_proxy_host = $site_env('SITE_REVERSE_PROXY_HOST', 'varnish');
  $site_proxy_addresses = gethostbynamel($site_proxy_host);
  if ($site_proxy_addresses === FALSE || $site_proxy_addresses === []) {
    throw new \RuntimeException("reverse proxy host \"$site_proxy_host\" does not resolve");
  }
  $settings['reverse_proxy'] = TRUE;
  $settings['reverse_proxy_addresses'] = $site_proxy_addresses;
  $settings['reverse_proxy_trusted_headers'] = Request::HEADER_X_FORWARDED_FOR;
}

// The redis module must be installed before the flag is set: its services
// do not exist before.
if ($site_flag('SITE_REDIS_ENABLE')) {
  $settings['redis.connection']['interface'] = 'PhpRedis';
  $settings['redis.connection']['host'] = $site_env('SITE_REDIS_HOST');
  $settings['redis.connection']['port'] = (int) $site_env('SITE_REDIS_PORT', '6379');
  $settings['redis.connection']['password'] = $site_secret('SITE_REDIS_PASSWORD_FILE');
  $settings['cache']['default'] = 'cache.backend.redis';
  $settings['container_yamls'][] = 'modules/contrib/redis/example.services.yml';
}
