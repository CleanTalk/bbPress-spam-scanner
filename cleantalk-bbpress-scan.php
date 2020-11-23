<?php
/*
  Plugin Name: CleanTalk bbPress spam scanner
  Plugin URI: https://cleantalk.org
  Description: Check existing bbPress topics for spam and move to trash all found spam.
  Version: 1.0.0
  Author: СleanTalk <welcome@cleantalk.org>
  Author URI: https://cleantalk.org
  Text Domain: cleantalk-bbpress-scan
  Domain Path: /i18n
*/

// If this file is called directly, abort.
if ( ! defined( 'WPINC' ) ) {
    die;
}

/**
 * Check if cleantalk-spam-protect and bbpress are active
 **/
if (
    in_array( 'cleantalk-spam-protect/cleantalk.php', apply_filters( 'active_plugins', get_option( 'active_plugins' ) ) ) &&
    in_array( 'bbpress/bbpress.php', apply_filters( 'active_plugins', get_option( 'active_plugins' ) ) )
) {

    require_once ABSPATH . 'wp-content/plugins/cleantalk-spam-protect/lib/autoloader.php';
    require_once 'inc/CleantalkBbPressScanner.php';
    require_once 'inc/CleantalkBbPressChecker.php';
    require_once 'inc/CleantalkBbPressListTable.php';

    add_action( 'admin_menu', 'ct_bbpress_find_spam_page' );
    function ct_bbpress_find_spam_page() {
        $bbpress_check_spam  = add_comments_page(
            __( "Check bbPress for spam", 'cleantalk-spam-protect'),
            __( "Find bbPress spam", 'cleantalk-spam-protect'),
            'activate_plugins',
            'ct_bbpress_check_spam',  array( '\Cleantalk\BbPressChecker\CleantalkBbPressScanner', 'showFindSpamPage' )
        );
        // @ToDo uncomment this after implementing right submenu position
        //remove_submenu_page( 'edit-comments.php', 'ct_bbpress_check_spam' );
    }

    // Ajax actions
    add_action( 'wp_ajax_ajax_bbpress_scan_clear_topics',      array( '\Cleantalk\BbPressChecker\CleantalkBbPressChecker', 'ct_ajax_clear_topics' ) );
    add_action( 'wp_ajax_ajax_bbpress_scan_check_topics',      array( '\Cleantalk\BbPressChecker\CleantalkBbPressChecker', 'ct_ajax_check_topics' ) );
    add_action( 'wp_ajax_ajax_bbpress_scan_info_topics',       array( '\Cleantalk\BbPressChecker\CleantalkBbPressChecker', 'ct_ajax_info' ) );

} else {

    // @ToDO we have to display a notice about cleantalk plugin required

}
