<?php

namespace Cleantalk\BbPressChecker;

class CleantalkBbPressScanner {

    private $spam_checker;


    public function __construct( CleantalkBbPressChecker $apbct_spam_checker )
    {

        $this->spam_checker = $apbct_spam_checker;
        $this->generatePageHeader();
        $this->spam_checker->getCurrentScanPage();

    }

    public static function showFindSpamPage()
    {

        new self( new CleantalkBbPressChecker() );
        self::closeTags();

    }

    private function generatePageHeader()
    {
        // If access key is unset in
        if( ! apbct_api_key__is_correct() ){
            if( 1 == $this->spam_checker->getApbct()->moderate_ip ){
                echo '<h3>'
                    .sprintf(
                        __('Antispam hosting tariff does not allow you to use this feature. To do so, you need to enter an Access Key in the %splugin settings%s.', 'cleantalk-spam-protect'),
                        '<a href="' . ( is_network_admin() ? 'settings.php?page=cleantalk' : 'options-general.php?page=cleantalk' ).'">',
                        '</a>'
                    )
                    .'</h3>';
            }
            return;
        }

        ?>
        <div class="wrap">
        <h2><img src="<?php echo $this->spam_checker->getApbct()->logo__small__colored; ?>" alt="CleanTalk logo" /> <?php echo $this->spam_checker->getApbct()->plugin_name; ?></h2>
        <a style="color: gray; margin-left: 23px;" href="<?php echo $this->spam_checker->getApbct()->settings_link; ?>"><?php _e('Plugin Settings', 'cleantalk-spam-protect'); ?></a>
        <br />
        <h3><?php echo $this->spam_checker->getPageTitle(); ?></h3>
            <div id="ct_check_content">
        <?php
    }

    private static function closeTags()
    {
        ?>
        </div>
        <?php
    }

}