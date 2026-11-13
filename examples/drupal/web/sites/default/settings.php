<?php

/**
 * @file
 * Settings of the example site: what is the same in every deployment. What
 * differs (database, salt, hosts, Redis) comes from the container environment
 * in settings.container.php.
 *
 * The file is complete and read-only in the image: drush site:install and the
 * installer leave it alone because the database, the salt and the config sync
 * directory are already set.
 */

declare(strict_types=1);

$databases = [];

$settings['config_sync_directory'] = '../config/sync';
$settings['file_private_path'] = dirname(DRUPAL_ROOT) . '/private';
$settings['file_temp_path'] = '/tmp';
$settings['update_free_access'] = FALSE;
$settings['entity_update_batch_size'] = 50;
$settings['entity_update_backup'] = TRUE;
$settings['file_scan_ignore_directories'] = ['node_modules', 'bower_components'];
$settings['container_yamls'][] = $app_root . '/' . $site_path . '/services.yml';

// sites/default is read-only: chmod on it would only log an error.
$settings['skip_permissions_hardening'] = TRUE;

require __DIR__ . '/settings.container.php';
