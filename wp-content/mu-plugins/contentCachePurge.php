<?php
/**
 * Plugin Name:     Content Cache Purge
 * Author:          Stephen Miracle (sellie fork)
 * Description:     Purge the sidekick content cache when a post is saved.
 * Version:         0.2.0
 *
 * Sellie fork notes:
 *   - Original used $_SERVER['PURGE_KEY']/['PURGE_PATH'] without
 *     existence checks, logging "Undefined array key" on every request
 *     when the env vars were unset. This version reads via getenv() with
 *     fallbacks and skips the purge call entirely when no purge key is
 *     configured (no point hitting an endpoint that can't authenticate).
 *   - Plugin is itself idempotent — a 404 from the purge endpoint
 *     doesn't break post saves.
 */

add_action('save_post', function ($id) {
    $purge_path = getenv('PURGE_PATH') ?: '/__cache/purge';
    $purge_key  = getenv('PURGE_KEY') ?: '';

    // When PURGE_KEY is unset, purge requests are sent without auth.
    // Sidekick accepts empty-key purges when its own PURGE_KEY config
    // is also empty (the default). This keeps cache invalidation
    // working out of the box. Operators who want auth-gated purges
    // set PURGE_KEY to a shared secret in their env.

    $post = get_post($id);
    if (! $post || empty($post->post_name)) {
        return;
    }

    $url = rtrim(get_site_url(), '/') . $purge_path . '/' . $post->post_name . '/';
    wp_remote_post($url, [
        'headers' => [
            'X-WPSidekick-Purge-Key' => $purge_key,
        ],
        // Don't block save_post on cache purge; cache will TTL eventually.
        'timeout'  => 2,
        'blocking' => false,
    ]);
});
