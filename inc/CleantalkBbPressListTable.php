<?php

namespace Cleantalk\BbPressChecker;

class CleantalkBbPressListTable extends \Cleantalk\ApbctWP\CleantalkListTable
{

    protected $apbct;

    function __construct(){

        parent::__construct(array(
            'singular' => 'spam',
            'plural'   => 'spam'
        ));

        $this->bulk_actions_handler();

        $this->row_actions_handler();

        $this->prepare_items();

        global $apbct;
        $this->apbct = $apbct;

    }


    /**
     * The main method to get data for the table
     */
    function prepare_items() {

        $columns = $this->get_columns();
        $this->_column_headers = array( $columns, array(), array() );

        //$per_page_option = get_current_screen()->get_option( 'per_page', 'option' );
        //$per_page = get_user_meta( get_current_user_id(), $per_page_option, true );
        //if( ! $per_page ) {
            $per_page = 10;
        //}

        $scanned_topics = $this->getSpamNow();

        $this->set_pagination_args( array(
            'total_items' => count( $scanned_topics ),
            'per_page'    => $per_page,
        ) );

        $current_page = (int) $this->get_pagenum();

        $scanned_topics_to_show = array_slice( $scanned_topics, ( ( $current_page - 1 ) * $per_page ), $per_page );

        foreach( $scanned_topics_to_show as $topic ) {

            $this->items[] = array(
                'ct_id' => $topic->ID,
                'ct_author'   => $topic->post_author,
                'ct_topic'  => $topic->post_title,
                'ct_forum' => get_the_title( get_post_meta( $topic->ID, '_bbp_forum_id', true ) ),
                'ct_created' => $topic->post_date,
            );

        }

    }

    // Set columns
    function get_columns(){
        return array(
            'cb'             => '<input type="checkbox" />',
            'ct_author'      => esc_html__( 'Author', 'cleantalk-spam-protect'),
            'ct_topic'     => esc_html__( 'Topic', 'cleantalk-spam-protect'),
            'ct_forum'     => esc_html__( 'Forum', 'cleantalk-spam-protect'),
            'ct_created' => esc_html__( 'Created', 'cleantalk-spam-protect'),
        );
    }

    // CheckBox column
    function column_cb( $item ){
        echo '<input type="checkbox" name="spamids[]" id="cb-select-'. $item['ct_id'] .'" value="'. $item['ct_id'] .'" />';
    }

    // Author (first) column
    function column_ct_author( $item ) {

        $column_content = '';
        if( function_exists( 'bbp_get_topic_author_email' ) ) {
            $email = bbp_get_topic_author_email( $item['ct_id'] );
        } else {
            $email = get_the_author_meta( 'user_email', $item['ct_author'] );
        }
        $ip = get_post_meta( $item['ct_id'], '_bbp_author_ip', true );

        // Avatar, nickname
        if( function_exists( 'bbp_topic_author_display_name' ) ) {
            $column_content .= '<strong>'. bbp_topic_author_display_name( $item['ct_id'] ) . '</strong>';
            $column_content .= '<br /><br />';
        }

        // Email
        if( ! empty( $email ) ){
            $column_content .= "<a href='mailto:$email'>$email</a>"
                .( ! $this->apbct->white_label
                    ? "<a href='https://cleantalk.org/blacklists/$email' target='_blank'>"
                    ."&nbsp;<img src='" . APBCT_URL_PATH . "/inc/images/new_window.gif' alt='Ico: open in new window' border='0' style='float:none' />"
                    ."</a>"
                    : '');
        } else {
            $column_content .= esc_html__( 'No email', 'cleantalk-spam-protect');
        }

        $column_content .= '<br/>';

        // IP
        if( ! empty( $ip ) ) {
            $column_content .= "<a href='edit-comments.php?s=$ip&mode=detail'>$ip</a>"
                .( ! $this->apbct->white_label
                    ?"<a href='https://cleantalk.org/blacklists/$ip ' target='_blank'>"
                    ."&nbsp;<img src='" . APBCT_URL_PATH . "/inc/images/new_window.gif' alt='Ico: open in new window' border='0' style='float:none' />"
                    ."</a>"
                    : '');
        }else
            $column_content .= esc_html__( 'No IP adress', 'cleantalk-spam-protect');

        return $column_content;

    }

    // Topic column
    function column_ct_topic( $item ){

        $id = $item['ct_id'];
        $column_content = '';

        $column_content .= '<div class="column-topic">';

        $column_content .= '<p>' . $item['ct_topic'] . '</p>';

        $column_content .= '</div>';

        $actions = array(
            'trash'     => sprintf(
            	'<a href="?page=%s&action=%s&spam=%s">Trash</a>',
	            sanitize_title( $_REQUEST['page'], 'ct_bbpress_check_spam' ),
	            'trash',
	            $id
            ),
        );

        return sprintf( '%1$s %2$s', $column_content, $this->row_actions( $actions ) );

    }

    // Forum column
    function column_ct_forum( $item ) {
        return $item['ct_forum'];
    }

    // Forum column
    function column_ct_created( $item ) {
        return $item['ct_created'];
    }

    function get_bulk_actions() {
        $actions = array(
            'trash'     => esc_html__( 'Move to trash', 'cleantalk-spam-protect' ),
        );
        return $actions;
    }

    function bulk_actions_handler() {

        if( empty($_POST['spamids']) || empty($_POST['_wpnonce']) ) return;

        if ( ! $action = $this->current_action() ) return;

        if( ! wp_verify_nonce( $_POST['_wpnonce'], 'bulk-' . $this->_args['plural'] ) )
            wp_die('nonce error');

        if( 'trash' == $action ) {
            $this->moveToTrash( $_POST['spamids'] );
        }

    }

    function row_actions_handler() {

        if( empty($_GET['action']) ) return;

        if( $_GET['action'] == 'trash' ) {

            $id = filter_input( INPUT_GET, 'spam', FILTER_SANITIZE_NUMBER_INT );
            $this->moveToTrash( array( $id ) );

        }

    }

    function no_items() {
        esc_html_e( 'No spam topics found.', 'cleantalk-spam-protect');
    }

    private function moveToTrash( $ids ) {

        if( ! empty( $ids ) ) {
            foreach ( $ids as $id) {
                delete_post_meta( sanitize_key( $id ), 'ct_marked_as_spam' );
                wp_trash_post( sanitize_key( $id ) );
            }
        }

    }

    private function getSpamNow()
    {
        // Spam Topics
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
            )
        );
        $spam_topics = new \WP_Query($params_spam);
        return $spam_topics->get_posts();
    }

}