<?php

namespace Cleantalk\BbPressChecker;

class CleantalkBbPressChecker
{
    private $page_title = 'CleanTalk bbPress topic scanner';

    private $page_slug = 'bbPress_spam';

    private $apbct;

    private $list_table;

    public function __construct()
    {
        global $apbct;
        $this->apbct = $apbct;

        // jQueryUI
        wp_enqueue_script( 'jqueryui', plugins_url('/cleantalk-spam-protect/js/jquery-ui.min.js'), array('jquery'), '1.12.1' );
        wp_enqueue_style ( 'jqueryui_css', plugins_url('/cleantalk-spam-protect/css/jquery-ui.min.css'), array(), '1.21.1', 'all' );
        wp_enqueue_style ( 'jqueryui_theme_css', plugins_url('/cleantalk-spam-protect/css/jquery-ui.theme.min.css'), array(), '1.21.1', 'all' );

        wp_enqueue_script( 'ct_bbpress_checkspam',  plugins_url('/cleantalk-bbpress-spam-scanner/js/cleantalk-bbpress-checkspam.js'), array( 'jquery', 'jqueryui' ), APBCT_VERSION );
        wp_localize_script( 'ct_bbpress_checkspam', 'ctBbpressCheck', array(
            'ct_ajax_nonce'               => wp_create_nonce('ct_secret_nonce'),
            'ct_prev_accurate'            => !empty($prev_check['accurate']) ? true                : false,
            'ct_prev_from'                => !empty($prev_check['from'])     ? $prev_check['from'] : false,
            'ct_prev_till'                => !empty($prev_check['till'])     ? $prev_check['till'] : false,
            'ct_timeout_confirm'          => __('Failed from timeout. Going to check topics again.', 'cleantalk-spam-protect'),
            'ct_confirm_trash_all'        => __('Trash all spam topics from the list?', 'cleantalk-spam-protect'),
            'ct_confirm_spam_all'         => __('Mark as spam all topics from the list?', 'cleantalk-spam-protect'),
            'ct_comments_added_after'     => __('topics', 'cleantalk-spam-protect'),
            'ct_status_string'            => __('Checked %s, found %s spam topics and %s bad topics (without IP or email).', 'cleantalk-spam-protect'),
            'ct_status_string_warning'    => '<p>'.__('Please do backup of WordPress database before delete any accounts!', 'cleantalk-spam-protect').'</p>',
            'start'                       => !empty($_COOKIE['ct_topics_start_check']) ? true : false,
        ));

        // Common CSS
        wp_enqueue_style ( 'cleantalk_admin_css_settings_page', plugins_url('/cleantalk-spam-protect/css/cleantalk-spam-check.min.css'), array( 'jqueryui_css' ), APBCT_VERSION, 'all' );

    }

    private static function get_count_text()
    {
        $topics = get_posts( array(
            'numberposts' => -1,
            'post_type'   => 'topic',
        ) );

        if( count( $topics ) ) {
            $text = sprintf( esc_html__ ('Total count of bbPress topics: %s.', 'cleantalk-bbpress-scan' ), count( $topics ) );
        } else {
            $text = esc_html__( 'No bbPress topics.', 'cleantalk-bbpress-scan' );
        }

        return $text;

    }

    public function getCurrentScanPage()
    {
        $this->list_table = new CleantalkBbPressListTable();

        $this->getCurrentScanPanel( $this );
        echo '<form action="" method="POST">';
        $this->list_table->display();
        echo '</form>';
    }

    public function getApbct()
    {
        return $this->apbct;
    }

    public function getPageTitle()
    {
        return $this->page_title;
    }

    private function getCurrentScanPanel( CleantalkBbPressChecker $spam_checker )
    {
        ?>

        <!-- Count -->
        <h3 id="ct_checking_count"><?php echo $spam_checker::get_count_text() ; ?></h3>

        <!-- Main info -->
        <h3 id="ct_checking_status"><?php echo $spam_checker::ct_ajax_info(true) ; ?></h3>

        <!-- Check options -->
        <div class="ct_to_hide" id="ct_check_params_wrapper">
            <button class="button ct_check_params_elem" id="ct_check_spam_button" <?php echo !$this->apbct->data['moderate'] ? 'disabled="disabled"' : ''; ?>><?php _e("Start check", 'cleantalk-spam-protect'); ?></button>
            <?php if(!empty($_COOKIE['ct_paused_'.$this->page_slug.'_check'])) { ?><button class="button ct_check_params_elem" id="ct_proceed_check_button"><?php _e("Continue check", 'cleantalk-spam-protect'); ?></button><?php } ?>
            <p class="ct_check_params_desc"><?php _e("The plugin will check all $this->page_slug against blacklists database and show you senders that have spam activity on other websites.", 'cleantalk-spam-protect'); ?></p>
            <br />
            <?php apbct_admin__badge__get_premium(); ?>
        </div>

        <!-- Cooling notice -->
        <h3 id="ct_cooling_notice"></h3>

        <!-- Preloader and working message -->
        <div id="ct_preloader">
            <img src="<?php echo APBCT_URL_PATH . '/inc/images/preloader.gif'; ?>" alt="Cleantalk preloader" />
        </div>
        <div id="ct_working_message">
            <?php _e("Please wait for a while. CleanTalk is checking all $this->page_slug via blacklist database at cleantalk.org. You will have option to delete found spam $this->page_slug after plugin finish.", 'cleantalk-spam-protect'); ?>
        </div>

        <!-- Pause button -->
        <button class="button" id="ct_pause">Pause check</button>
        <?php
    }

    public static function ct_ajax_clear_topics(){

        check_ajax_referer( 'ct_secret_nonce', 'security' );

        global $wpdb;
        $wpdb->query("DELETE FROM {$wpdb->postmeta} WHERE meta_key IN ('ct_checked_now')");

        if ( isset($_POST['from']) && isset($_POST['till']) ) {
            if ( preg_match('/[a-zA-Z]{3}\s{1}\d{1,2}\s{1}\d{4}/', $_POST['from'] ) && preg_match('/[a-zA-Z]{3}\s{1}\d{1,2}\s{1}\d{4}/', $_POST['till'] ) ) {

                $from = date('Y-m-d', intval(strtotime($_POST['from']))) . ' 00:00:00';
                $till = date('Y-m-d', intval(strtotime($_POST['till']))) . ' 23:59:59';

                $wpdb->query("DELETE FROM {$wpdb->postmeta} WHERE 
                meta_key IN ('ct_checked','ct_marked_as_spam','ct_bad') 
                AND meta_value >= '{$from}' 
                AND meta_value <= '{$till}';");
                die();

            } else {
                $wpdb->query("DELETE FROM {$wpdb->postmeta} WHERE 
                meta_key IN ('ct_checked','ct_marked_as_spam','ct_bad')");
                die();
            }
        }

    }

    public static function ct_ajax_info( $direct_call )
    {
        if (!$direct_call)
            check_ajax_referer( 'ct_secret_nonce', 'security' );

        // Checked comments
        $params_checked = array(
            'posts_per_page' => -1,
            'post_type'   => 'topic',
            'meta_key' => 'ct_checked_now',
            'orderby' => 'ct_checked_now'
        );
        $checked_topics = new \WP_Query($params_checked);
        $cnt_checked = count( $checked_topics->get_posts() );

        // Spam comments
        $params_spam = array(
            'posts_per_page' => -1,
            'post_type'   => 'topic',
            'meta_query' => array(
                'relation' => 'AND',
                array(
                    'key' => 'ct_marked_as_spam',
                    'compare' => 'EXISTS'
                ),
                array(
                    'key' => 'ct_checked_now',
                    'compare' => 'EXISTS'
                ),
            ),
        );
        $spam_topics = new \WP_Query($params_spam);
        $cnt_spam = count( $spam_topics->get_posts() );

        // Bad comments (without IP and Email)
        $params_bad = array(
            'posts_per_page' => -1,
            'post_type'   => 'topic',
            'meta_query' => array(
                'relation' => 'AND',
                array(
                    'key' => 'ct_bad',
                    'compare' => 'EXISTS'
                ),
                array(
                    'key' => 'ct_checked_now',
                    'compare' => 'EXISTS'
                ),
            ),
        );
        $bad_topics = new \WP_Query($params_bad);
        $cnt_bad = count( $bad_topics->get_posts() );

        $return = array(
            'message'  => '',
            'spam'     => $cnt_spam,
            'checked'  => $cnt_checked,
            'bad'      => $cnt_bad,
        );

        if( ! $direct_call ) {
            $return['message'] .= sprintf (
                esc_html__('Checked %s, found %s spam topics and %s bad topics (without IP or email)', 'cleantalk-spam-protect'),
                $cnt_checked,
                $cnt_spam,
                $cnt_bad
            );
        } else {

            if ( $cnt_checked ) {

                $checked = $checked_topics->get_posts();
                $first_checked = $checked[0];

                $return['message'] .= sprintf (
                    __("Last check %s: checked %s comments, found %s spam comments and %s bad comments (without IP or email).", 'cleantalk-spam-protect'),
                    date( "M j Y", strtotime( get_post_meta( $first_checked->ID, 'ct_checked_now', true ) ) ),
                    $cnt_checked,
                    $cnt_spam,
                    $cnt_bad
                );

            } else {
                // Never checked
                $return['message'] = esc_html__( 'Never checked yet or no new spam.', 'cleantalk-spam-protect');
            }

        }

        $backup_notice = '&nbsp;';
        if ( $cnt_spam > 0 ){
            $backup_notice = __("Please do backup of WordPress database before delete any topics!", 'cleantalk-spam-protect');
        }
        $return['message'] .= "<p>$backup_notice</p>";

        if( $direct_call ){
            return $return['message'];
        }else{
            echo json_encode( $return );
            die();
        }
    }

    public static function ct_ajax_check_topics() {

        check_ajax_referer( 'ct_secret_nonce', 'security' );

        global $apbct;

        $params = array(
            'meta_query' => array(
                'relation' => 'AND',
                array(
                    'key' => 'ct_checked_now',
                    'compare' => 'NOT EXISTS'
                ),
                array(
                    'key' => 'ct_checked',
                    'compare' => 'NOT EXISTS'
                ),
                array(
                    'key' => 'ct_bad',
                    'compare' => 'NOT EXISTS'
                )
            ),
            'post_type'   => 'topic',
            'number' => 100
        );
        $topics_query = new \WP_Query( $params );
        $topics = $topics_query->get_posts();

        $check_result = array(
            'end' => 0,
            'checked' => 0,
            'spam' => 0,
            'bad' => 0,
            'error' => 0
        );

        if( count( $topics ) ) {

            // Checking comments IP/Email. Gathering $data for check.
            $data = array();
            foreach( $topics as $topic ) {

                $curr_ip = get_post_meta($topic->ID, '_bbp_author_ip', true);

                if( function_exists( 'bbp_get_topic_author_email' ) ) {
                    $curr_email = bbp_get_topic_author_email( $topic->ID );
                } else {
                    $curr_email = get_the_author_meta( 'user_email', $topic->post_author );
                }

                // Check for identity
                $curr_ip = preg_match('/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/', $curr_ip) === 1 ? $curr_ip : null;
                $curr_email = preg_match('/^\S+@\S+\.\S+$/', $curr_email) === 1 ? $curr_email : null;

                if (empty($curr_ip) && empty($curr_email)) {
                    $check_result['bad']++;
                    update_post_meta($topic->ID, 'ct_bad', '1');
                    update_post_meta($topic->ID, 'ct_checked', '1');
                    update_post_meta($topic->ID, 'ct_checked_now', '1');
                } else {
                    if (!empty($curr_ip))
                        $data[] = $curr_ip;
                    if (!empty($curr_email))
                        $data[] = $curr_email;
                    // Patch for empty IP/Email

                }
            }

            // Drop if data empty and there's no comments to check
            if( count( $data ) == 0 ){
                if( $_POST['unchecked'] === 0 )
                    $check_result['end'] = 1;
                print json_encode( $check_result );
                die();
            }

            $result = \Cleantalk\ApbctWP\API::methodSpamCheckCms( $apbct->api_key, $data, null );

            if(empty($result['error'])){

                foreach( $topics as $topic ){

                    $mark_spam_ip = false;
                    $mark_spam_email = false;

                    $check_result['checked']++;
                    update_post_meta( $topic->ID,'ct_checked',date("Y-m-d H:m:s") );
                    update_post_meta( $topic->ID, 'ct_checked_now', date("Y-m-d H:m:s"), true );

                    $uip = get_post_meta( $topic->ID, '_bbp_author_ip', true );
                    if( function_exists( 'bbp_get_topic_author_email' ) ) {
                        $uim = bbp_get_topic_author_email( $topic->ID );
                    } else {
                        $uim = get_the_author_meta( 'user_email', $topic->post_author );
                    }

                    if( isset( $result[$uip] ) && $result[$uip]['appears'] == 1 )
                        $mark_spam_ip = true;

                    if( isset($result[$uim] ) && $result[$uim]['appears'] == 1 )
                        $mark_spam_email = true;

                    if ( $mark_spam_ip || $mark_spam_email ){
                        $check_result['spam']++;
                        update_post_meta( $topic->ID,'ct_marked_as_spam','1' );
                    }
                }
                print json_encode($check_result);

            }else{
                $check_result['error'] = 1;
                $check_result['error_message'] = $result['error'];
                echo json_encode($check_result);
            }

        }else{

            $check_result['end'] = 1;
            print json_encode($check_result);

        }

        die;

    }

}