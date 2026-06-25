#!/usr/bin/perl
use strict;
use warnings;
use Mojolicious::Lite -signatures;
use DBI;
use DBD::SQLite;
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use DateTime;
use Mojo::UserAgent;
use File::Path qw(make_path);
use File::Spec;
use Mojo::Util qw(url_escape);
use POSIX qw(strftime);
use Net::SMTP;
use MIME::Base64;

my %CURRENCY_CONFIG = (
    USD => { rate => 1.00, symbol => '$' },
    EUR => { rate => 0.92, symbol => 'EUR ' },
    GBP => { rate => 0.79, symbol => 'GBP ' },
    INR => { rate => 83.00, symbol => 'INR ' },
);

my %LANGUAGE_CONFIG = (
    en => 'English',
    hi => 'Hindi',
    es => 'Spanish',
);

my %I18N = (
    en => {
        home => 'Home',
        products => 'Products',
        cart => 'Cart',
        checkout => 'Checkout',
        login => 'Login',
        logout => 'Logout',
        register => 'Register',
        language => 'Language',
        currency => 'Currency',
        payment_page => 'Payment Page',
        pay_now => 'Pay Now',
        order_confirmed => 'Order confirmed successfully',
        order_confirmation_subject => 'Order Confirmation',
        shipping_details => 'Shipping Details',
    },
    hi => {
        home => 'होम',
        products => 'उत्पाद',
        cart => 'कार्ट',
        checkout => 'चेकआउट',
        login => 'लॉगिन',
        logout => 'लॉगआउट',
        register => 'रजिस्टर',
        language => 'भाषा',
        currency => 'मुद्रा',
        payment_page => 'भुगतान पेज',
        pay_now => 'अभी भुगतान करें',
        order_confirmed => 'ऑर्डर सफलतापूर्वक पुष्टि किया गया',
        order_confirmation_subject => 'ऑर्डर पुष्टि',
        shipping_details => 'शिपिंग विवरण',
    },
    es => {
        home => 'Inicio',
        products => 'Productos',
        cart => 'Carrito',
        checkout => 'Pagar',
        login => 'Iniciar sesión',
        logout => 'Cerrar sesión',
        register => 'Registrarse',
        language => 'Idioma',
        currency => 'Moneda',
        payment_page => 'Página de Pago',
        pay_now => 'Pagar Ahora',
        order_confirmed => 'Pedido confirmado correctamente',
        order_confirmation_subject => 'Confirmación de Pedido',
        shipping_details => 'Detalles de Envío',
    },
);

=head1 NAME

app.pl - VGAG BUSINESS SUITE Ecommerce Web Application

=head1 DESCRIPTION

A complete ecommerce platform for VGAG BUSINESS SUITE built with Mojolicious framework featuring:
- Product catalog
- Shopping cart
- User authentication
- Order management
- Admin panel

=head1 SETUP

cpan Mojolicious
cpan DBD::SQLite
cpan JSON::PP
perl app.pl daemon -l http://*:3000

=cut

# Database initialization
sub init_db {
    my $db = DBI->connect('dbi:SQLite:ecommerce.db', '', '', {
        RaiseError => 1,
        AutoCommit => 1
    });

    # Users table
    $db->do(q{
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            email TEXT UNIQUE NOT NULL,
            password TEXT NOT NULL,
            full_name TEXT,
            phone TEXT,
            address TEXT,
            city TEXT,
            postal_code TEXT,
            is_admin INTEGER DEFAULT 0,
            role TEXT DEFAULT 'customer',
            is_active INTEGER DEFAULT 1,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    });

    my %user_columns = map { $_->{name} => 1 } @{ $db->selectall_arrayref('PRAGMA table_info(users)', { Slice => {} }) };
    my @user_alters = (
        [role => "ALTER TABLE users ADD COLUMN role TEXT DEFAULT 'customer'"],
        [is_active => "ALTER TABLE users ADD COLUMN is_active INTEGER DEFAULT 1"],
    );
    for my $alter (@user_alters) {
        my ($column, $statement) = @$alter;
        next if $user_columns{$column};
        eval { $db->do($statement) };
        if ($@) {
            die $@ unless $@ =~ /duplicate column name/i;
        }
    }
    $db->do("UPDATE users SET role = 'admin' WHERE is_admin = 1 AND (role IS NULL OR role = '' OR role = 'customer')");
    $db->do("UPDATE users SET role = 'customer' WHERE role IS NULL OR role = ''");

    # Products table
    $db->do(q{
        CREATE TABLE IF NOT EXISTS products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            description TEXT,
            price REAL NOT NULL,
            cost_price REAL DEFAULT 0,
            stock INTEGER DEFAULT 0,
            gst_rate REAL DEFAULT 18,
            hsn_code TEXT DEFAULT '0000',
            category TEXT,
            image_url TEXT,
            sku TEXT UNIQUE,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    });

    my %product_columns = map { $_->{name} => 1 } @{ $db->selectall_arrayref('PRAGMA table_info(products)', { Slice => {} }) };
    my @product_alters = (
        [cost_price => "ALTER TABLE products ADD COLUMN cost_price REAL DEFAULT 0"],
        [gst_rate => "ALTER TABLE products ADD COLUMN gst_rate REAL DEFAULT 18"],
        [hsn_code => "ALTER TABLE products ADD COLUMN hsn_code TEXT DEFAULT '0000'"],
    );
    for my $alter (@product_alters) {
        my ($column, $statement) = @$alter;
        $db->do($statement) unless $product_columns{$column};
    }

    # Cart table
    $db->do(q{
        CREATE TABLE IF NOT EXISTS cart_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            product_id INTEGER NOT NULL,
            quantity INTEGER NOT NULL,
            added_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
            FOREIGN KEY(product_id) REFERENCES products(id) ON DELETE CASCADE
        )
    });

    # Orders table
    $db->do(q{
        CREATE TABLE IF NOT EXISTS orders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            total_price REAL NOT NULL,
            status TEXT DEFAULT 'pending',
            shipping_address TEXT,
            shipping_name TEXT,
            shipping_phone TEXT,
            shipping_city TEXT,
            shipping_postal_code TEXT,
            shipping_country TEXT,
            payment_method TEXT,
            payment_reference TEXT,
            payment_status TEXT DEFAULT 'pending',
            currency TEXT DEFAULT 'USD',
            language TEXT DEFAULT 'en',
            tracking_number TEXT,
            confirmation_email_status TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
        )
    });

    my %order_columns = map { $_->{name} => 1 } @{ $db->selectall_arrayref('PRAGMA table_info(orders)', { Slice => {} }) };
    my @order_alters = (
        [shipping_name => "ALTER TABLE orders ADD COLUMN shipping_name TEXT"],
        [shipping_phone => "ALTER TABLE orders ADD COLUMN shipping_phone TEXT"],
        [shipping_city => "ALTER TABLE orders ADD COLUMN shipping_city TEXT"],
        [shipping_postal_code => "ALTER TABLE orders ADD COLUMN shipping_postal_code TEXT"],
        [shipping_country => "ALTER TABLE orders ADD COLUMN shipping_country TEXT"],
        [payment_reference => "ALTER TABLE orders ADD COLUMN payment_reference TEXT"],
        [payment_status => "ALTER TABLE orders ADD COLUMN payment_status TEXT DEFAULT 'pending'"],
        [currency => "ALTER TABLE orders ADD COLUMN currency TEXT DEFAULT 'USD'"],
        [language => "ALTER TABLE orders ADD COLUMN language TEXT DEFAULT 'en'"],
        [tracking_number => "ALTER TABLE orders ADD COLUMN tracking_number TEXT"],
        [confirmation_email_status => "ALTER TABLE orders ADD COLUMN confirmation_email_status TEXT"],
    );
    for my $alter (@order_alters) {
        my ($column, $statement) = @$alter;
        $db->do($statement) unless $order_columns{$column};
    }

    # Order items table
    $db->do(q{
        CREATE TABLE IF NOT EXISTS order_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            order_id INTEGER NOT NULL,
            product_id INTEGER NOT NULL,
            product_name_snapshot TEXT,
            hsn_code TEXT,
            quantity INTEGER NOT NULL,
            price REAL NOT NULL,
            unit_cost REAL DEFAULT 0,
            gst_rate REAL DEFAULT 0,
            taxable_amount REAL DEFAULT 0,
            tax_amount REAL DEFAULT 0,
            line_total REAL DEFAULT 0,
            FOREIGN KEY(order_id) REFERENCES orders(id) ON DELETE CASCADE,
            FOREIGN KEY(product_id) REFERENCES products(id)
        )
    });

    my %order_item_columns = map { $_->{name} => 1 } @{ $db->selectall_arrayref('PRAGMA table_info(order_items)', { Slice => {} }) };
    my @order_item_alters = (
        [product_name_snapshot => "ALTER TABLE order_items ADD COLUMN product_name_snapshot TEXT"],
        [hsn_code => "ALTER TABLE order_items ADD COLUMN hsn_code TEXT"],
        [unit_cost => "ALTER TABLE order_items ADD COLUMN unit_cost REAL DEFAULT 0"],
        [gst_rate => "ALTER TABLE order_items ADD COLUMN gst_rate REAL DEFAULT 0"],
        [taxable_amount => "ALTER TABLE order_items ADD COLUMN taxable_amount REAL DEFAULT 0"],
        [tax_amount => "ALTER TABLE order_items ADD COLUMN tax_amount REAL DEFAULT 0"],
        [line_total => "ALTER TABLE order_items ADD COLUMN line_total REAL DEFAULT 0"],
    );
    for my $alter (@order_item_alters) {
        my ($column, $statement) = @$alter;
        $db->do($statement) unless $order_item_columns{$column};
    }

    $db->do(q{
        CREATE TABLE IF NOT EXISTS app_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    });

    $db->do(q{
        CREATE TABLE IF NOT EXISTS reel_jobs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            product_id INTEGER NOT NULL,
            caption TEXT,
            reel_url TEXT,
            local_video_path TEXT,
            status TEXT DEFAULT 'pending',
            meta_creation_id TEXT,
            meta_media_id TEXT,
            error_message TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(product_id) REFERENCES products(id)
        )
    });

    $db->do(q{
        CREATE TABLE IF NOT EXISTS partner_page_submissions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            partner_key TEXT NOT NULL,
            section_key TEXT NOT NULL,
            page_title TEXT NOT NULL,
            full_name TEXT NOT NULL,
            business_name TEXT,
            email TEXT NOT NULL,
            phone TEXT,
            subject TEXT,
            project_type TEXT,
            timeline TEXT,
            budget TEXT,
            details TEXT,
            file_path TEXT,
            original_filename TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    });

    $db->do(q{
        CREATE TABLE IF NOT EXISTS login_otp_challenges (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            otp_hash TEXT NOT NULL,
            email_status TEXT,
            sms_status TEXT,
            attempts INTEGER DEFAULT 0,
            expires_at DATETIME NOT NULL,
            consumed_at DATETIME,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
        )
    });

    $db->do(q{
        CREATE TABLE IF NOT EXISTS slack_connection_requests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            full_name TEXT NOT NULL,
            email TEXT NOT NULL,
            phone TEXT,
            slack_email TEXT,
            team_role TEXT,
            preferred_channel TEXT,
            notes TEXT,
            status TEXT DEFAULT 'requested',
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
        )
    });

    return $db;
}

my $db = init_db();

# Helpers
helper db => sub { return $db };
helper ua => sub { state $ua = Mojo::UserAgent->new(max_redirects => 3); return $ua };

helper get_setting => sub ($c, $key, $default = '') {
    my ($value) = $db->selectrow_array('SELECT value FROM app_settings WHERE key = ?', undef, $key);
    return defined $value ? $value : $default;
};

helper set_setting => sub ($c, $key, $value) {
    $db->do(q{
        INSERT INTO app_settings (key, value, updated_at)
        VALUES (?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP
    }, undef, $key, $value // '');
};

helper otp_settings => sub ($c) {
    my $expiry = $c->get_setting('otp_expiry_minutes', 10);
    $expiry = 10 unless defined $expiry && $expiry =~ /^\d+$/;
    $expiry = 3 if $expiry < 3;
    $expiry = 30 if $expiry > 30;

    return {
        expiry_minutes => $expiry,
        email_subject => $c->get_setting('otp_email_subject', 'VGAG BUSINESS SUITE login OTP'),
        sms_gateway_url_template => $c->get_setting('sms_gateway_url_template', ''),
        sms_sender_id => $c->get_setting('sms_sender_id', ''),
        sms_api_key => $c->get_setting('sms_api_key', ''),
    };
};

helper send_sms => sub ($c, $phone, $message) {
    my $config = $c->otp_settings;
    my $template = $config->{sms_gateway_url_template} // '';
    return { success => 0, configured => 0, status => 'not configured by admin' } unless $template;

    my %replacements = (
        '{phone}' => url_escape($phone // ''),
        '{message}' => url_escape($message // ''),
        '{sender_id}' => url_escape($config->{sms_sender_id} // ''),
        '{api_key}' => url_escape($config->{sms_api_key} // ''),
    );

    my $url = $template;
    for my $token (keys %replacements) {
        my $value = $replacements{$token};
        $url =~ s/\Q$token\E/$value/g;
    }

    my $res = $c->ua->get($url)->result;
    return { success => 1, status => 'sent_via_sms_gateway' } if $res->is_success;
    return { success => 0, error => $res->body || $res->message || 'SMS delivery failed' };
};

helper send_login_otp_email => sub ($c, $user, $otp_code) {
    my $subject = $c->otp_settings->{email_subject};
    my $body = <<"EMAIL";
Hello @{[$user->{username} // 'User']},

Your VGAG BUSINESS SUITE one-time password is: $otp_code

This code expires in @{[$c->otp_settings->{expiry_minutes}]} minutes.
If you did not try to log in, please ignore this message.

EMAIL

    my $email_dir = File::Spec->catdir('.', 'emails');
    make_path($email_dir) unless -d $email_dir;
    my $file = File::Spec->catfile(
        $email_dir,
        sprintf('login_otp_%s_%s.txt', ($user->{username} // 'user'), strftime('%Y%m%d%H%M%S', gmtime()))
    );
    open my $fh, '>', $file or die "Unable to write OTP email file: $file";
    print {$fh} "To: $user->{email}\n";
    print {$fh} "Subject: $subject\n\n";
    print {$fh} $body;
    close $fh;

    my $smtp_result = $c->send_email($user->{email}, $subject, $body);
    return { success => 1, status => "sent_via_smtp; backup_saved:$file" } if $smtp_result->{success};

    return { success => 1, status => "smtp_failed_backup_saved:$file" };
};

helper create_login_otp_challenge => sub ($c, $user) {
    my $otp_code = sprintf('%06d', int(rand(1_000_000)));
    my $otp_hash = sha256_hex($otp_code);
    my $expires_at = strftime('%Y-%m-%d %H:%M:%S', gmtime(time + ($c->otp_settings->{expiry_minutes} * 60)));

    my $email_result = $c->send_login_otp_email($user, $otp_code);
    my $email_status = $email_result->{status} // ('failed: ' . ($email_result->{error} // 'unknown'));

    my $sms_status = 'not_requested';
    if ($user->{phone}) {
        my $sms_message = "VGAG BUSINESS SUITE login OTP: $otp_code. Valid for " . $c->otp_settings->{expiry_minutes} . " minutes.";
        my $sms_result = $c->send_sms($user->{phone}, $sms_message);
        $sms_status = $sms_result->{status}
            // ($sms_result->{success} ? 'sent_via_sms_gateway' : 'delivery unavailable');
    }
    else {
        $sms_status = 'phone number missing';
    }

    $db->do(
        q{UPDATE login_otp_challenges SET consumed_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE user_id = ? AND consumed_at IS NULL},
        undef,
        $user->{id}
    );
    $db->do(q{
        INSERT INTO login_otp_challenges (user_id, otp_hash, email_status, sms_status, expires_at, updated_at)
        VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
    }, undef, $user->{id}, $otp_hash, $email_status, $sms_status, $expires_at);

    my $challenge_id = $db->last_insert_id(undef, undef, 'login_otp_challenges', undef);
    return {
        challenge_id => $challenge_id,
        email_status => $email_status,
        sms_status => $sms_status,
        expires_at => $expires_at,
    };
};

helper current_login_otp_challenge => sub ($c) {
    my $challenge_id = $c->session('pending_otp_challenge_id');
    return unless $challenge_id;

    return $db->selectrow_hashref(q{
        SELECT loc.*, u.username, u.email, u.phone, u.full_name
        FROM login_otp_challenges loc
        JOIN users u ON u.id = loc.user_id
        WHERE loc.id = ?
    }, undef, $challenge_id);
};

helper slack_connect_config => sub ($c) {
    return {
        workspace_name => $c->get_setting('slack_workspace_name', 'VGAG BUSINESS SUITE'),
        workspace_url => $c->get_setting('slack_workspace_url', 'https://app.slack.com/client'),
        invite_url => $c->get_setting('slack_invite_url', ''),
        channel_name => $c->get_setting('slack_channel_name', '#general'),
        channel_url => $c->get_setting('slack_channel_url', ''),
        help_text => $c->get_setting(
            'slack_help_text',
            'Use Slack to stay connected with the VGAG BUSINESS SUITE team for collaboration, updates, and delivery coordination.'
        ),
        download_url => 'https://slack.com/downloads',
    };
};

helper partner_section_config => sub ($c, $section) {
    my %sections = (
        'website-demo' => { name => 'WEBSITE DEMO', description => 'Review the website demo and navigation flow for Sree Physio Therapists.' },
        'brand-assets' => { name => 'BRAND ASSETS', description => 'Access approved logos, fonts, color palettes, and brand media resources.' },
        'testimonials' => { name => 'TESTIMONIALS', description => 'Showcase client feedback, recovery stories, and partner success narratives.' },
        'videos' => {
            name => 'VIDEOS',
            description => 'Upload demo videos, treatment walkthroughs, patient education clips, and branded media assets.',
            upload_label => 'Upload Video Files',
            upload_accept => 'video/*,.mp4,.mov,.avi,.mkv,.webm'
        },
        'products' => { name => 'PRODUCTS', description => 'Browse physiotherapy products, kits, and recommended treatment support items.' },
        'team' => { name => 'TEAM', description => 'Meet therapists, support staff, and specialist care contributors.' },
        'social-media-links' => { name => 'SOCIAL MEDIA LINKS', description => 'Find official social media channels, pages, and engagement handles.' },
        'agreements' => { name => 'AGREEMENTS', description => 'Review legal agreements, partner contracts, and compliance documents.' },
        'payment-terms' => { name => 'PAYMENT TERMS', description => 'Review billing cycles, accepted payment modes, invoicing terms, and settlement timelines.' },
        'contract-terms' => { name => 'CONTRACT TERMS', description => 'Understand contract scope, tenure, obligations, renewals, and termination clauses.' },
        'business-info' => { name => 'BUSINESS INFO (GST/MSME ETC)', description => 'Access business registration, GST details, MSME information, and statutory references.' },
        'profit-sharing-agreement' => { name => 'PROFIT SHARING AGREEMENT', description => 'Review revenue-sharing structure, allocation rules, and partner payout terms.' },
        'services' => { name => 'SERVICES', description => 'Explore physiotherapy and allied healthcare services offered by Sree Physio Therapists.' },
        'book-an-appointment' => { name => 'BOOK AN APPOINTMENT', description => 'Schedule appointments for consultation, treatment plans, and therapy sessions.' },
        'projects' => { name => 'PROJECTS', description => 'Track project scope, milestones, delivery planning, and implementation ownership.' },
        'phase1' => { name => 'PHASE1', description => 'Manage first-phase planning, requirements capture, approvals, and foundational setup.' },
        'phase2' => { name => 'PHASE2', description => 'Track second-phase execution, asset readiness, coordination tasks, and implementation progress.' },
        'phase3' => { name => 'PHASE3', description => 'Finalize launch readiness, validation, go-live coordination, and post-launch action items.' },
        'golive-date' => { name => 'GOLIVE DATE', description => 'Track launch milestones and final go-live readiness timelines.' },
        'open-issues' => { name => 'OPEN ISSUES', description => 'Monitor pending items, blockers, and action points before release.' },
        'workflow' => { name => 'WORKFLOW', description => 'Understand operational workflow from intake to therapy delivery and follow-up.' },
        'shopify-store' => { name => 'SHOPIFY STORE', description => 'Plan Shopify storefront setup, catalog readiness, themes, integrations, and launch needs.' },
        'whatsapp-catalogue' => { name => 'WHATSAPP CATALOGUE', description => 'Prepare WhatsApp catalogue structure, product listings, assets, and messaging content.' },
        'whatsapp-business-api' => { name => 'WHATSAPP BUSINESS API', description => 'Track API onboarding, templates, provider setup, automations, and delivery workflows.' },
        'meta-verified' => { name => 'META VERIFIED', description => 'Manage verification readiness, brand identity requirements, and account support needs.' },
        'monetization' => { name => 'MONETIZATION', description => 'Review monetization channels, offers, packages, revenue flows, and scaling opportunities.' },
    );
    return $sections{$section};
};

hook before_dispatch => sub ($c) {
    $c->session(lang => 'en') unless $c->session('lang');
    $c->session(currency => 'USD') unless $c->session('currency');

    my $path = $c->req->url->path->to_string;
    return if $path =~ m{^/(login|register|otp/verify|otp/resend|favicon\.ico)$};

    if ($c->session('pending_otp_challenge_id') && !$c->session('user_id')) {
        return $c->redirect_to('/otp/verify');
    }

    return if $c->session('user_id');
    return if $path =~ m{^/(css|js|images|uploads|reels)/};

    $c->redirect_to('/login');
};

helper languages => sub { return \%LANGUAGE_CONFIG };
helper currencies => sub { return \%CURRENCY_CONFIG };

helper current_language => sub ($c) {
    my $lang = lc($c->session('lang') // 'en');
    return $LANGUAGE_CONFIG{$lang} ? $lang : 'en';
};

helper current_currency => sub ($c) {
    my $currency = uc($c->session('currency') // 'USD');
    return $CURRENCY_CONFIG{$currency} ? $currency : 'USD';
};

helper t => sub ($c, $key) {
    my $lang = $c->current_language;
    return $I18N{$lang}{$key} // $I18N{en}{$key} // $key;
};

helper convert_from_usd => sub ($c, $amount, $currency = undef) {
    my $target_currency = $currency ? uc($currency) : $c->current_currency;
    $target_currency = 'USD' unless $CURRENCY_CONFIG{$target_currency};
    return ($amount // 0) * $CURRENCY_CONFIG{$target_currency}{rate};
};

helper convert_currency_amount => sub ($c, $amount, $from_currency, $to_currency) {
    my $from = uc($from_currency // 'USD');
    my $to = uc($to_currency // 'USD');
    $from = 'USD' unless $CURRENCY_CONFIG{$from};
    $to = 'USD' unless $CURRENCY_CONFIG{$to};
    my $usd = ($amount // 0) / $CURRENCY_CONFIG{$from}{rate};
    return $usd * $CURRENCY_CONFIG{$to}{rate};
};

helper format_money => sub ($c, $amount, $currency = undef) {
    my $target_currency = $currency ? uc($currency) : $c->current_currency;
    $target_currency = 'USD' unless $CURRENCY_CONFIG{$target_currency};
    my $symbol = $CURRENCY_CONFIG{$target_currency}{symbol};
    my $numeric = sprintf('%.2f', $amount // 0);
    return $symbol . $numeric;
};

helper display_money => sub ($c, $usd_amount) {
    my $currency = $c->current_currency;
    my $converted = $c->convert_from_usd($usd_amount, $currency);
    return $c->format_money($converted, $currency);
};

helper invoice_number => sub ($c, $order_id) {
    return sprintf('INV-%s-%06d', strftime('%Y%m%d', gmtime()), $order_id);
};

# Shiprocket Integration
helper shiprocket_auth_token => sub ($c) {
    return $c->get_setting('shiprocket_auth_token', '');
};

helper shiprocket_base_url => sub {
    return 'https://apiv2.shiprocket.in/v1/external';
};

helper shiprocket_login => sub ($c, $email, $password) {
    my $url = $c->shiprocket_base_url . '/auth/login';
    my $res = $c->ua->post($url, json => {
        email => $email,
        password => $password
    })->result;
    
    if ($res->is_success) {
        my $data = $res->json;
        if ($data->{token}) {
            $c->set_setting('shiprocket_auth_token', $data->{token});
            $c->set_setting('shiprocket_customer_id', $data->{data}{customer_id} // '');
            return { success => 1, token => $data->{token} };
        }
    }
    return { success => 0, error => $res->message };
};

helper shiprocket_create_shipment => sub ($c, $order_id) {
    my $token = $c->shiprocket_auth_token;
    return { success => 0, error => 'No Shiprocket auth token found' } unless $token;
    
    my $order = $db->selectrow_hashref('SELECT * FROM orders WHERE id = ?', undef, $order_id);
    return { success => 0, error => 'Order not found' } unless $order;
    
    my $items = $db->selectall_arrayref(q{
        SELECT oi.*, p.name FROM order_items oi
        JOIN products p ON oi.product_id = p.id
        WHERE oi.order_id = ?
    }, { Slice => {} }, $order_id);
    
    my @order_items = map { {
        name => $_->{name},
        sku => '',
        units => $_->{quantity},
        selling_price => $_->{price}
    } } @$items;
    
    my $payload = {
        order_id => "ORD-$order_id",
        order_date => $order->{created_at},
        pickup_location_id => 100753,
        channel_id => 1,
        comment => 'Order from VGAG Business Suite',
        billing_customer_name => $order->{shipping_name} // 'Customer',
        billing_email => '',
        billing_phone => $order->{shipping_phone} // '',
        billing_address => $order->{shipping_address} // '',
        billing_city => $order->{shipping_city} // '',
        billing_postal_code => $order->{shipping_postal_code} // '',
        billing_country => $order->{shipping_country} // 'India',
        shipping_is_billing => JSON::PP::true,
        order_items => \@order_items,
        payment_method => 'Prepaid',
        sub_total => $order->{total_price},
        length => 10,
        breadth => 8,
        height => 5,
        weight => 0.5
    };
    
    my $url = $c->shiprocket_base_url . '/orders/create/adhoc';
    my $res = $c->ua->post($url, 
        json => $payload,
        'Authorization' => $token
    )->result;
    
    if ($res->is_success) {
        my $data = $res->json;
        if ($data->{shipment_id}) {
            $db->do(q{
                UPDATE orders SET tracking_number = ? WHERE id = ?
            }, undef, $data->{shipment_id}, $order_id);
            return { success => 1, shipment_id => $data->{shipment_id} };
        }
    }
    return { success => 0, error => $res->message // $res->text };
};

helper shiprocket_get_tracking => sub ($c, $shipment_id) {
    my $token = $c->shiprocket_auth_token;
    return { success => 0, error => 'No auth token' } unless $token;
    
    my $url = $c->shiprocket_base_url . "/shipments/track/shipment/$shipment_id";
    my $res = $c->ua->get($url, 'Authorization' => $token)->result;
    
    if ($res->is_success) {
        my $data = $res->json;
        return { success => 1, tracking => $data->{data} // {} };
    }
    return { success => 0, error => $res->message };
};

helper shiprocket_get_rates => sub ($c, $params) {
    my $token = $c->shiprocket_auth_token;
    return { success => 0, error => 'No auth token' } unless $token;
    
    my $url = $c->shiprocket_base_url . '/courier/assign/predict?' .
        'pickup_postcode=' . ($params->{pickup_postal} // '110001') .
        '&delivery_postcode=' . ($params->{delivery_postal} // '') .
        '&weight=' . ($params->{weight} // 0.5) .
        '&cod=' . ($params->{cod} ? 1 : 0);
    
    my $res = $c->ua->get($url, 'Authorization' => $token)->result;
    
    if ($res->is_success) {
        my $data = $res->json;
        return { success => 1, couriers => $data->{data} // [] };
    }
    return { success => 0, error => $res->message };
};

# Email sending helper
helper send_email => sub ($c, $to, $subject, $body, $html = 0) {
    my $smtp_host = 'localhost';
    my $smtp_port = 25;
    my $from = 'team@vgagbusinesssuite.com';
    
    my $smtp = Net::SMTP->new($smtp_host, Port => $smtp_port, Timeout => 10);
    unless ($smtp) {
        warn "Failed to connect to SMTP server: $!";
        return { success => 0, error => 'SMTP connection failed' };
    }
    
    unless ($smtp->mail($from)) {
        warn "SMTP mail() failed: " . $smtp->message;
        $smtp->quit;
        return { success => 0, error => $smtp->message };
    }
    
    unless ($smtp->to($to)) {
        warn "SMTP to() failed: " . $smtp->message;
        $smtp->quit;
        return { success => 0, error => $smtp->message };
    }
    
    $smtp->data();
    
    my $headers = "From: $from\r\n";
    $headers .= "To: $to\r\n";
    $headers .= "Subject: $subject\r\n";
    
    if ($html) {
        $headers .= "Content-Type: text/html; charset=UTF-8\r\n";
    } else {
        $headers .= "Content-Type: text/plain; charset=UTF-8\r\n";
    }
    $headers .= "\r\n";
    
    $smtp->datasend($headers);
    $smtp->datasend($body);
    $smtp->dataend();
    
    $smtp->quit;
    return { success => 1 };
};

helper gst_split => sub ($c, $gst_amount) {
    my $half = ($gst_amount // 0) / 2;
    return ($half, $half);
};

helper generate_reel_video => sub ($c, $product, $caption) {
    my $model_clip = $c->get_setting('meta_model_clip_path');
    die 'Model clip path is not configured' unless $model_clip;
    die 'Model clip file not found on server' unless -f $model_clip;

    my $product_image = $product->{image_url} // '';
    $product_image =~ s{^/}{};
    my $product_image_path = File::Spec->catfile('.', 'public', $product_image);
    die 'Product image not found for reel generation' unless -f $product_image_path;

    my $reels_dir = File::Spec->catdir('.', 'public', 'reels');
    make_path($reels_dir) unless -d $reels_dir;

    my $filename = sprintf('product-%d-%s.mp4', $product->{id}, strftime('%Y%m%d%H%M%S', gmtime()));
    my $output_path = File::Spec->catfile($reels_dir, $filename);
    my $overlay_text = $product->{name} // 'Featured Product';
    $overlay_text =~ s/["\\]/ /g;

    my @cmd = (
        'ffmpeg', '-y',
        '-i', $model_clip,
        '-i', $product_image_path,
        '-filter_complex',
        "overlay=W-w-30:30,drawtext=text='$overlay_text':fontcolor=white:fontsize=28:box=1:boxcolor=black@0.5:boxborderw=8:x=20:y=H-th-20",
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-shortest',
        $output_path
    );

    my $result = system(@cmd);
    die 'ffmpeg command failed while generating reel video' if $result != 0;

    my $base_url = $c->get_setting('meta_public_base_url');
    die 'Public base URL is not configured' unless $base_url;
    $base_url =~ s{/$}{};
    my $reel_url = $base_url . '/reels/' . $filename;
    return ($output_path, $reel_url);
};

helper create_and_publish_reel => sub ($c, $reel_url, $caption) {
    my $ig_user_id = $c->get_setting('meta_ig_user_id');
    my $access_token = $c->get_setting('meta_access_token');
    die 'Meta IG user ID is not configured' unless $ig_user_id;
    die 'Meta access token is not configured' unless $access_token;

    my $create_tx = $c->ua->post(
        "https://graph.facebook.com/v20.0/$ig_user_id/media" => form => {
            media_type => 'REELS',
            video_url => $reel_url,
            caption => $caption // '',
            access_token => $access_token,
        }
    );
    my $create_res = $create_tx->result;
    die 'Failed to create reel container: ' . ($create_res->body // 'unknown error')
        unless $create_res->is_success;
    my $creation_id = $create_res->json('/id');
    die 'Meta did not return creation id' unless $creation_id;

    sleep 3;

    my $publish_tx = $c->ua->post(
        "https://graph.facebook.com/v20.0/$ig_user_id/media_publish" => form => {
            creation_id => $creation_id,
            access_token => $access_token,
        }
    );
    my $publish_res = $publish_tx->result;
    die 'Failed to publish reel: ' . ($publish_res->body // 'unknown error')
        unless $publish_res->is_success;
    my $media_id = $publish_res->json('/id');
    die 'Meta did not return media id' unless $media_id;

    return ($creation_id, $media_id);
};

helper generate_tracking_number => sub {
    my $stamp = strftime('%Y%m%d%H%M%S', gmtime());
    my $rand = int(rand(9000)) + 1000;
    return "VGAG$stamp$rand";
};

helper send_order_confirmation_email => sub ($c, $user, $order, $items) {
    my $subject = $c->t('order_confirmation_subject') . " #$order->{id}";
    my $line_items = join("\n", map {
        my $line_total = defined $_->{line_total}
            ? $_->{line_total}
            : (($_->{price} // 0) * ($_->{quantity} // 0));
        "- $_->{name} x$_->{quantity} = " . $c->format_money($line_total, $order->{currency})
    } @$items);

    my $body = <<"EMAIL";
Hello $user->{username},

Thank you for your order with VGAG BUSINESS SUITE.
Order ID: $order->{id}
Tracking Number: $order->{tracking_number}
Status: $order->{status}
Payment Status: $order->{payment_status}
Total: @{[$c->format_money($order->{total_price}, $order->{currency})]}

Shipping:
@{[$order->{shipping_name} // '']}
@{[$order->{shipping_phone} // '']}
@{[$order->{shipping_address} // '']}
@{[$order->{shipping_city} // '']} @{[$order->{shipping_postal_code} // '']}
@{[$order->{shipping_country} // '']}

Items:
$line_items

Thank you for shopping with us!
Support: support\@vgagbusinesssuite.com

EMAIL

    # Try SMTP first, fall back to file storage
    my $smtp_result = $c->send_email($user->{email}, $subject, $body);
    if ($smtp_result->{success}) {
        return { status => 'sent_via_smtp' };
    }
    
    # Fall back to file storage
    my $email_dir = File::Spec->catdir('.', 'emails');
    make_path($email_dir) unless -d $email_dir;
    my $file = File::Spec->catfile($email_dir, "order_$order->{id}_confirmation.txt");
    open my $fh, '>', $file or die "Unable to write confirmation email file: $file";
    print {$fh} "To: $user->{email}\n";
    print {$fh} "Subject: $subject\n\n";
    print {$fh} $body;
    close $fh;
    return { status => "saved_to_$file" };
};

helper get_session_user => sub ($c) {
    my $user_id = $c->session('user_id');
    return unless $user_id;
    
    my $stmt = $db->prepare('SELECT * FROM users WHERE id = ?');
    $stmt->execute($user_id);
    return $stmt->fetchrow_hashref;
};

helper normalize_role => sub ($c, $role) {
    my %allowed = map { $_ => 1 } qw(admin manager editor support customer);
    my $normalized = lc($role // 'customer');
    return $allowed{$normalized} ? $normalized : 'customer';
};

helper user_role => sub ($c, $user) {
    return 'customer' unless $user;
    return 'admin' if $user->{is_admin};
    return $c->normalize_role($user->{role});
};

helper has_access => sub ($c, $user, @roles) {
    return 0 unless $user;
    my $current_role = $c->user_role($user);
    my %allowed = map { $c->normalize_role($_) => 1 } @roles;
    return $allowed{$current_role} ? 1 : 0;
};

helper require_auth => sub ($c) {
    unless ($c->session('user_id')) {
        $c->redirect_to('/login');
        return 0;
    }
    my $user = $c->get_session_user;
    unless ($user && ($user->{is_active} // 1)) {
        delete $c->session->{user_id};
        $c->flash(error => 'Account is inactive. Contact administrator.');
        $c->redirect_to('/login');
        return 0;
    }
    return 1;
};

helper require_roles => sub ($c, @roles) {
    my $user = $c->get_session_user;
    unless ($user && ($user->{is_active} // 1) && $c->has_access($user, @roles)) {
        $c->render(text => 'Unauthorized', status => 403);
        return 0;
    }
    return 1;
};

helper require_admin => sub ($c) {
    return $c->require_roles('admin');
};

# Public Routes

# Home page
get '/' => sub ($c) {
    my @products = ();
    my $stmt = $db->prepare('SELECT * FROM products LIMIT 12');
    $stmt->execute;
    while (my $row = $stmt->fetchrow_hashref) {
        push @products, $row;
    }
    $c->render(template => 'index', products => \@products);
};

# Product listing
get '/products' => sub ($c) {
    my $category = $c->param('category');
    my $search = $c->param('search');
    
    my $query = 'SELECT * FROM products WHERE 1=1';
    my @params;
    
    if ($category) {
        $query .= ' AND category = ?';
        push @params, $category;
    }
    
    if ($search) {
        $query .= ' AND (name LIKE ? OR description LIKE ?)';
        push @params, "%$search%", "%$search%";
    }
    
    my @products = ();
    my $stmt = $db->prepare($query);
    $stmt->execute(@params);
    while (my $row = $stmt->fetchrow_hashref) {
        push @products, $row;
    }
    
    $c->render(template => 'products', products => \@products);
};

# Product detail
get '/product/:id' => sub ($c) {
    my $id = $c->param('id');
    my $stmt = $db->prepare('SELECT * FROM products WHERE id = ?');
    $stmt->execute($id);
    my $product = $stmt->fetchrow_hashref;
    
    $c->render(template => 'product_detail', product => $product);
};

# Shop pages
get '/shop' => sub ($c) {
    $c->render(template => 'shop');
};

get '/shop/padma-impex' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'PADMA IMPEX',
        section_description => 'Explore trade, sourcing, and product opportunities under PADMA IMPEX.'
    );
};

get '/shop/vgag-business-solutions' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'VGAG BUSINESS SOLUTIONS',
        section_description => 'Discover consulting, execution, and enterprise support services from VGAG BUSINESS SOLUTIONS.'
    );
};

get '/shop/business-partners' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'BUSINESS PARTNERS',
        section_description => 'Connect with trusted business partners for strategic alliances, collaborations, and growth opportunities.'
    );
};

get '/shop/sree-physio-therapists' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'SREE PHYSIO THERAPISTS',
        section_description => 'Access physiotherapy partner services covering rehabilitation, pain management, mobility care, and wellness programs.'
    );
};

get '/shop/sree-physio-therapists/:section' => sub ($c) {
    my $section = $c->param('section') // '';
    my $selected = $c->partner_section_config($section);
    return $c->reply->not_found unless $selected;

    $c->render(template => 'shop_section',
        section_name => $selected->{name},
        section_description => $selected->{description},
        detail_form => {
            submit_url => "/shop/sree-physio-therapists/$section/submit",
            section_key => $section,
            partner_key => 'sree-physio-therapists',
            upload_label => $selected->{upload_label} // 'Upload Files',
            upload_accept => $selected->{upload_accept} // '',
        }
    );
};

post '/shop/sree-physio-therapists/:section/submit' => sub ($c) {
    my $section = $c->param('section') // '';
    my $selected = $c->partner_section_config($section);
    return $c->reply->not_found unless $selected;

    my $full_name = $c->param('full_name') // '';
    my $email = $c->param('email') // '';
    my $business_name = $c->param('business_name') // '';
    my $phone = $c->param('phone') // '';
    my $subject = $c->param('subject') // '';
    my $project_type = $c->param('project_type') // '';
    my $timeline = $c->param('timeline') // '';
    my $budget = $c->param('budget') // '';
    my $details = $c->param('details') // '';

    unless ($full_name && $email && $details) {
        $c->flash(error => 'Full name, email, and details are required.');
        return $c->redirect_to("/shop/sree-physio-therapists/$section");
    }

    my $stored_relative_path = '';
    my $original_filename = '';
    if (my $upload = $c->req->upload('attachment')) {
        $original_filename = $upload->filename // '';
        if ($original_filename) {
            if (($section eq 'videos') && (($upload->headers->content_type // '') !~ m{^video/}i) && ($original_filename !~ /\.(mp4|mov|avi|mkv|webm)$/i)) {
                $c->flash(error => 'Please upload a valid video file.');
                return $c->redirect_to("/shop/sree-physio-therapists/$section");
            }
            my $safe_name = $original_filename;
            $safe_name =~ s{[^A-Za-z0-9._-]}{_}g;
            my $upload_dir = File::Spec->catdir('.', 'public', 'uploads', 'sree-physio-therapists', $section);
            make_path($upload_dir) unless -d $upload_dir;
            my $stored_name = time . '-' . $safe_name;
            my $target = File::Spec->catfile($upload_dir, $stored_name);
            $upload->move_to($target);
            $stored_relative_path = '/uploads/sree-physio-therapists/' . $section . '/' . $stored_name;
        }
    }

    $db->do(q{
        INSERT INTO partner_page_submissions (
            partner_key, section_key, page_title, full_name, business_name, email, phone,
            subject, project_type, timeline, budget, details, file_path, original_filename
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    }, undef,
        'sree-physio-therapists',
        $section,
        $selected->{name},
        $full_name,
        $business_name,
        $email,
        $phone,
        $subject,
        $project_type,
        $timeline,
        $budget,
        $details,
        $stored_relative_path,
        $original_filename
    );

    $c->flash(success => 'Your details and files were submitted successfully.');
    $c->redirect_to("/shop/sree-physio-therapists/$section");
};

get '/shop/vendors' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'VENDORS',
        section_description => 'Engage with verified vendors for procurement, distribution, and operational collaboration.'
    );
};

get '/shop/suppliers' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'SUPPLIERS',
        section_description => 'Explore supplier network opportunities for sourcing, fulfillment, and scalable supply operations.'
    );
};

get '/shop/auditors' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'AUDITORS',
        section_description => 'Connect with audit partners for compliance, assurance, process review, and governance support.'
    );
};

get '/shop/news' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'NEWS',
        section_description => 'Stay updated with latest announcements, updates, and ecosystem developments.'
    );
};

get '/shop/trends-suggestions' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'TRENDS/SUGGESTIONS',
        section_description => 'Capture market trends, growth suggestions, improvement ideas, and strategic recommendations for the business suite.'
    );
};

get '/shop/delivery-shipping' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'DELIVERY/SHIPPING',
        section_description => 'Track delivery workflows, shipping coverage, fulfillment readiness, dispatch coordination, and customer delivery expectations.'
    );
};

get '/shop/sales-invoices' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'SALES AND INVOICES',
        section_description => 'Review sales operations, invoice planning, billing coordination, collections visibility, and customer commercial records.'
    );
};

get '/shop/reports-profit-loss' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'REPORTS/PROFIT LOSS',
        section_description => 'Access reporting focus areas for profitability, margins, business performance, revenue insights, and operational profit-loss tracking.'
    );
};

get '/shop/affiliates' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'AFFILIATES',
        section_description => 'Join affiliate growth programs for referral partnerships and collaborative market expansion.'
    );
};

get '/shop/franchise' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'FRANCHISE',
        section_description => 'Discover franchise opportunities with structured onboarding, support, and scalable business models.'
    );
};

get '/slack/connect' => sub ($c) {
    $c->require_auth or return;

    my $user = $c->get_session_user;
    my $config = $c->slack_connect_config;
    my @requests = @{ $db->selectall_arrayref(q{
        SELECT *
        FROM slack_connection_requests
        WHERE user_id = ?
        ORDER BY created_at DESC
        LIMIT 10
    }, { Slice => {} }, $user->{id}) };

    $c->render(template => 'slack_connect',
        user => $user,
        config => $config,
        requests => \@requests
    );
};

post '/slack/connect' => sub ($c) {
    $c->require_auth or return;

    my $user = $c->get_session_user;
    my $full_name = $c->param('full_name') // ($user->{full_name} || $user->{username} || '');
    my $email = $c->param('email') // ($user->{email} || '');
    my $phone = $c->param('phone') // ($user->{phone} || '');
    my $slack_email = $c->param('slack_email') // '';
    my $team_role = $c->param('team_role') // '';
    my $preferred_channel = $c->param('preferred_channel') // '';
    my $notes = $c->param('notes') // '';

    unless ($full_name && $email && $email =~ /\@/ && $notes) {
        $c->flash(error => 'Full name, a valid email, and connection notes are required.');
        return $c->redirect_to('/slack/connect');
    }

    $db->do(q{
        INSERT INTO slack_connection_requests (
            user_id, full_name, email, phone, slack_email, team_role, preferred_channel, notes, status, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'requested', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    }, undef,
        $user->{id},
        $full_name,
        $email,
        $phone,
        $slack_email,
        $team_role,
        $preferred_channel,
        $notes
    );

    $c->flash(success => 'Slack connection request submitted.');
    $c->redirect_to('/slack/connect');
};

get '/shop/efbiwff-ngo-section8' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'EFBIWFF (NGO/SECTION8)',
        section_description => 'Learn about EFBIWFF social impact programs, partnerships, and NGO/SECTION8 initiatives.'
    );
};

get '/shop/vgag-partner-dance-studio-all-styles' => sub ($c) {
    my @styles = (
        { slug => 'salsa',   name => 'SALSA' },
        { slug => 'salsa-rueda', name => 'SALSA RUEDA' },
        { slug => 'casino-rueda', name => 'CASINO RUEDA' },
        { slug => 'bachata', name => 'BACHATA' },
        { slug => 'cumbia',  name => 'CUMBIA' },
        { slug => 'nortenos', name => 'NORTENOS' },
        { slug => 'tango',   name => 'TANGO' },
        { slug => 'kizomba', name => 'KIZOMBA' },
        { slug => 'chacha',  name => 'CHACHA' },
        { slug => 'jive',    name => 'JIVE' },
        { slug => 'rumba',   name => 'RUMBA' },
        { slug => 'bolero',  name => 'BOLERO' },
        { slug => 'swing',   name => 'SWING' },
        { slug => 'waltz',   name => 'WALTZ' },
        { slug => 'foxtrot', name => 'FOXTROT' },
        { slug => 'merengue', name => 'MERENGUE' },
        { slug => 'samba',   name => 'SAMBA' },
        { slug => 'zouk',    name => 'ZOUK' },
    );

    $c->render(template => 'dance_styles',
        section_name => 'VGAG PARTNER DANCE STUDIO ALL STYLES',
        section_description => 'Explore partner dance classes across world-famous styles.',
        styles => \@styles
    );
};

get '/shop/vgag-partner-dance-studio-all-styles/:style' => sub ($c) {
    my $style = $c->param('style') // '';

    my %style_details = (
        'salsa'    => { name => 'SALSA',    description => 'High-energy social partner dance with strong Latin rhythm and turn patterns.' },
        'salsa-rueda' => { name => 'SALSA RUEDA', description => 'Group-based circular salsa format with synchronized calls and partner changes.' },
        'casino-rueda' => { name => 'CASINO RUEDA', description => 'Cuban rueda style focused on casino foundations, musicality, and dynamic partner rotations.' },
        'bachata'  => { name => 'BACHATA',  description => 'Romantic partner dance style from the Dominican Republic focused on musical connection.' },
        'cumbia'   => { name => 'CUMBIA',   description => 'Classic Latin social partner dance with relaxed rhythm and traveling step patterns.' },
        'nortenos' => { name => 'NORTENOS', description => 'Regional partner dance expression with strong social roots and lively partner movement.' },
        'tango'    => { name => 'TANGO',    description => 'Expressive close-embrace partner dance with dramatic movement and precision.' },
        'kizomba'  => { name => 'KIZOMBA',  description => 'Smooth partner dance known for grounded steps, flow, and close musical interpretation.' },
        'chacha'   => { name => 'CHACHA',   description => 'Playful Latin partner dance featuring quick footwork and sharp timing accents.' },
        'cha-cha'  => { name => 'CHACHA',   description => 'Playful Latin partner dance featuring quick footwork and sharp timing accents.' },
        'jive'     => { name => 'JIVE',     description => 'Fast-paced swing-influenced partner dance with kicks, triples, and energetic bounce.' },
        'rumba'    => { name => 'RUMBA',    description => 'Expressive Latin partner dance emphasizing timing, hip action, and controlled movement.' },
        'bolero'   => { name => 'BOLERO',   description => 'Slow, lyrical partner dance emphasizing elegance, posture, and smooth transitions.' },
        'swing'    => { name => 'SWING',    description => 'Upbeat partner dance family with bounce, spins, and social-friendly patterns.' },
        'waltz'    => { name => 'WALTZ',    description => 'Classic ballroom partner dance in triple time known for rise-and-fall movement.' },
        'foxtrot'  => { name => 'FOXTROT',  description => 'Elegant ballroom style with continuous gliding motion and smooth travel.' },
        'merengue' => { name => 'MERENGUE', description => 'Accessible social partner dance with simple rhythm and fun rotational steps.' },
        'samba'    => { name => 'SAMBA',    description => 'Dynamic Brazilian-influenced partner dance with bounce action and vibrant energy.' },
        'zouk'     => { name => 'ZOUK',     description => 'Fluid contemporary partner dance known for body movement and musical creativity.' },
    );

    my $selected = $style_details{$style};
    return $c->reply->not_found unless $selected;

    $c->render(template => 'dance_style_detail',
        section_name => 'VGAG PARTNER DANCE STUDIO ALL STYLES',
        style_name => $selected->{name},
        style_description => $selected->{description}
    );
};

get '/shop/vgag-fresh-meals-prep-kit-delivery' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'VGAG Fresh Meals Prep Kit Delivery',
        section_description => 'Explore convenient, chef-curated fresh meal prep kits delivered to your doorstep.'
    );
};

get '/shop/vgag-bike-rentals-airport-shuttles' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'VGAG Bike Rentals and Airport Shuttles',
        section_description => 'Book reliable bike rentals and airport shuttle services for smooth local travel.'
    );
};

get '/shop/vgag-luxury-homestays' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'VGAG Luxury Homestays',
        section_description => 'Discover premium homestay experiences with comfort-focused stays in curated locations.'
    );
};

get '/shop/vgag-expats-network' => sub ($c) {
    $c->render(template => 'shop_section',
        section_name => 'VGAG Expats Network',
        section_description => 'Connect with a trusted expat community for relocation support, networking, and resources.'
    );
};

get '/privacy-policy' => sub ($c) {
    $c->render(template => 'privacy_policy');
};

get '/terms-of-service' => sub ($c) {
    $c->render(template => 'terms_of_service');
};

get '/about' => sub ($c) {
    $c->render(template => 'about');
};

get '/contact' => sub ($c) {
    $c->render(template => 'contact');
};

get '/faq' => sub ($c) {
    $c->render(template => 'faq');
};

get '/shipping' => sub ($c) {
    $c->render(template => 'shipping');
};

get '/shipping-info' => sub ($c) {
    $c->redirect_to('/shipping');
};

get '/returns' => sub ($c) {
    $c->render(template => 'returns');
};

# Authentication Routes

# Register page
get '/register' => sub ($c) {
    $c->render(template => 'register');
};

# Register post
post '/register' => sub ($c) {
    my $username = $c->param('username');
    my $email = $c->param('email');
    my $phone = $c->param('phone');
    my $password = $c->param('password');
    my $confirm = $c->param('confirm_password');
    
    unless ($password eq $confirm) {
        return $c->render(template => 'register', error => 'Passwords do not match');
    }
    
    my $hashed_pwd = sha256_hex($password);
    
    eval {
        my $stmt = $db->prepare(
            'INSERT INTO users (username, email, phone, password, role, is_active) VALUES (?, ?, ?, ?, ?, ?)'
        );
        $stmt->execute($username, $email, $phone, $hashed_pwd, 'customer', 1);
    };
    
    if ($@) {
        return $c->render(template => 'register', error => 'Username or email already exists');
    }
    
    $c->redirect_to('/login');
};

# Login page
get '/login' => sub ($c) {
    $c->render(template => 'login');
};

# Login post
post '/login' => sub ($c) {
    my $username = $c->param('username');
    my $password = $c->param('password');
    
    my $hashed_pwd = sha256_hex($password);
    my $stmt = $db->prepare('SELECT id, username, email, phone, is_active FROM users WHERE username = ? AND password = ?');
    $stmt->execute($username, $hashed_pwd);
    my $user = $stmt->fetchrow_hashref;
    
    unless ($user) {
        return $c->render(template => 'login', error => 'Invalid credentials');
    }
    unless ($user->{is_active}) {
        return $c->render(template => 'login', error => 'Account disabled. Contact administrator.');
    }

    delete $c->session->{user_id};
    my $challenge = $c->create_login_otp_challenge($user);
    $c->session(pending_otp_challenge_id => $challenge->{challenge_id});
    $c->session(pending_otp_user_id => $user->{id});
    $c->flash(success => 'OTP sent. Enter the code to complete login.');
    $c->redirect_to('/otp/verify');
};

get '/otp/verify' => sub ($c) {
    my $challenge = $c->current_login_otp_challenge;
    return $c->redirect_to('/login') unless $challenge;

    if ($challenge->{consumed_at} || $challenge->{expires_at} le strftime('%Y-%m-%d %H:%M:%S', gmtime())) {
        delete $c->session->{pending_otp_challenge_id};
        delete $c->session->{pending_otp_user_id};
        $c->flash(error => 'OTP expired. Please log in again.');
        return $c->redirect_to('/login');
    }

    $c->render(template => 'otp_verify', challenge => $challenge, expiry_minutes => $c->otp_settings->{expiry_minutes});
};

post '/otp/verify' => sub ($c) {
    my $challenge = $c->current_login_otp_challenge;
    return $c->redirect_to('/login') unless $challenge;

    my $otp_code = $c->param('otp_code') // '';
    if ($challenge->{consumed_at} || $challenge->{expires_at} le strftime('%Y-%m-%d %H:%M:%S', gmtime())) {
        delete $c->session->{pending_otp_challenge_id};
        delete $c->session->{pending_otp_user_id};
        $c->flash(error => 'OTP expired. Please log in again.');
        return $c->redirect_to('/login');
    }

    my $expected_hash = sha256_hex($otp_code);
    if ($expected_hash ne ($challenge->{otp_hash} // '')) {
        $db->do(
            'UPDATE login_otp_challenges SET attempts = attempts + 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
            undef,
            $challenge->{id}
        );
        my ($attempts) = $db->selectrow_array('SELECT attempts FROM login_otp_challenges WHERE id = ?', undef, $challenge->{id});
        if (($attempts // 0) >= 5) {
            $db->do(
                'UPDATE login_otp_challenges SET consumed_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
                undef,
                $challenge->{id}
            );
            delete $c->session->{pending_otp_challenge_id};
            delete $c->session->{pending_otp_user_id};
            $c->flash(error => 'Too many invalid OTP attempts. Please log in again.');
            return $c->redirect_to('/login');
        }
        return $c->render(template => 'otp_verify',
            challenge => { %$challenge, attempts => $attempts },
            expiry_minutes => $c->otp_settings->{expiry_minutes},
            error => 'Invalid OTP code'
        );
    }

    $db->do(
        'UPDATE login_otp_challenges SET consumed_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
        undef,
        $challenge->{id}
    );

    $c->session(user_id => $challenge->{user_id});
    delete $c->session->{pending_otp_challenge_id};
    delete $c->session->{pending_otp_user_id};
    $c->flash(success => 'OTP verified successfully.');
    $c->redirect_to('/');
};

post '/otp/resend' => sub ($c) {
    my $user_id = $c->session('pending_otp_user_id');
    return $c->redirect_to('/login') unless $user_id;

    my $user = $db->selectrow_hashref(
        'SELECT id, username, email, phone, is_active FROM users WHERE id = ?',
        undef,
        $user_id
    );
    return $c->redirect_to('/login') unless $user && ($user->{is_active} // 1);

    my $challenge = $c->create_login_otp_challenge($user);
    $c->session(pending_otp_challenge_id => $challenge->{challenge_id});
    $c->flash(success => 'A new OTP has been sent.');
    $c->redirect_to('/otp/verify');
};

# Logout
get '/logout' => sub ($c) {
    delete $c->session->{user_id};
    delete $c->session->{pending_otp_challenge_id};
    delete $c->session->{pending_otp_user_id};
    $c->redirect_to('/login');
};

post '/preferences' => sub ($c) {
    my $lang = lc($c->param('lang') // $c->current_language);
    my $currency = uc($c->param('currency') // $c->current_currency);
    $lang = 'en' unless $LANGUAGE_CONFIG{$lang};
    $currency = 'USD' unless $CURRENCY_CONFIG{$currency};

    $c->session(lang => $lang);
    $c->session(currency => $currency);

    my $return_to = $c->param('return_to') // '/';
    $return_to = '/' unless $return_to =~ m{^/};
    $c->redirect_to($return_to);
};

# Shopping Cart Routes

# View cart
get '/cart' => sub ($c) {
    $c->require_auth or return;
    
    my $user = $c->get_session_user;
    my @cart_items = ();
    my $total = 0;
    
    my $stmt = $db->prepare(q{
        SELECT ci.id, p.id as product_id, p.name, p.price, ci.quantity
        FROM cart_items ci
        JOIN products p ON ci.product_id = p.id
        WHERE ci.user_id = ?
    });
    $stmt->execute($user->{id});
    
    while (my $row = $stmt->fetchrow_hashref) {
        $row->{subtotal} = $row->{price} * $row->{quantity};
        $total += $row->{subtotal};
        push @cart_items, $row;
    }
    
    $c->render(template => 'cart', items => \@cart_items, total => $total);
};

# Add to cart
post '/cart/add' => sub ($c) {
    $c->require_auth or return;
    
    my $user = $c->get_session_user;
    my $product_id = $c->param('product_id');
    my $quantity = $c->param('quantity') || 1;
    my $accept = $c->req->headers->accept // '';
    my $wants_json = $c->req->is_xhr || $accept =~ /json/i;

    if ($quantity !~ /^\d+$/ || $quantity < 1) {
        return $c->render(json => {error => 'Invalid quantity'}, status => 400) if $wants_json;
        $c->flash(error => 'Invalid quantity');
        return $c->redirect_to('/products');
    }
    
    # Check if product exists
    my $p_stmt = $db->prepare('SELECT id, stock FROM products WHERE id = ?');
    $p_stmt->execute($product_id);
    my $product = $p_stmt->fetchrow_hashref;
    unless ($product) {
        return $c->render(json => {error => 'Product not found'}, status => 404) if $wants_json;
        $c->flash(error => 'Product not found');
        return $c->redirect_to('/products');
    }
    
    # Check if already in cart
    my $c_stmt = $db->prepare('SELECT id FROM cart_items WHERE user_id = ? AND product_id = ?');
    $c_stmt->execute($user->{id}, $product_id);
    
    if (my $existing = $c_stmt->fetchrow_hashref) {
        my ($current_quantity) = $db->selectrow_array(
            'SELECT quantity FROM cart_items WHERE id = ?',
            undef, $existing->{id}
        );
        my $new_quantity = ($current_quantity || 0) + $quantity;
        if ($new_quantity > $product->{stock}) {
            return $c->render(json => {error => 'Not enough stock available'}, status => 409) if $wants_json;
            $c->flash(error => 'Not enough stock available');
            return $c->redirect_to('/product/' . $product_id);
        }

        $db->do(
            'UPDATE cart_items SET quantity = quantity + ? WHERE id = ?',
            undef, $quantity, $existing->{id}
        );
    } else {
        if ($quantity > $product->{stock}) {
            return $c->render(json => {error => 'Not enough stock available'}, status => 409) if $wants_json;
            $c->flash(error => 'Not enough stock available');
            return $c->redirect_to('/product/' . $product_id);
        }

        $db->do(
            'INSERT INTO cart_items (user_id, product_id, quantity) VALUES (?, ?, ?)',
            undef, $user->{id}, $product_id, $quantity
        );
    }
    
    if ($wants_json) {
        return $c->render(json => {success => 1});
    }

    $c->flash(success => 'Product added to cart');
    $c->redirect_to('/cart');
};

# Remove from cart
post '/cart/remove/:id' => sub ($c) {
    $c->require_auth or return;
    
    my $user = $c->get_session_user;
    my $item_id = $c->param('id');
    my $accept = $c->req->headers->accept // '';
    my $wants_json = $c->req->is_xhr || $accept =~ /json/i;
    
    $db->do('DELETE FROM cart_items WHERE id = ? AND user_id = ?', undef, $item_id, $user->{id});
    
    if ($wants_json) {
        return $c->render(json => {success => 1});
    }

    $c->flash(success => 'Item removed from cart');
    $c->redirect_to('/cart');
};

# Checkout page
get '/checkout' => sub ($c) {
    $c->require_auth or return;

    my $user = $c->get_session_user;
    my @cart_items = ();
    my $total = 0;

    my $stmt = $db->prepare(q{
        SELECT ci.id, p.id as product_id, p.name, p.price, ci.quantity
        FROM cart_items ci
        JOIN products p ON ci.product_id = p.id
        WHERE ci.user_id = ?
    });
    $stmt->execute($user->{id});

    while (my $row = $stmt->fetchrow_hashref) {
        $row->{subtotal} = $row->{price} * $row->{quantity};
        $total += $row->{subtotal};
        push @cart_items, $row;
    }

    if (!@cart_items) {
        $c->flash(error => 'Your cart is empty');
        return $c->redirect_to('/cart');
    }

    $c->render(template => 'checkout', items => \@cart_items, total => $total, user => $user);
};

# Checkout submit
post '/checkout' => sub ($c) {
    $c->require_auth or return;
    
    my $shipping_name = $c->param('shipping_name');
    my $shipping_phone = $c->param('shipping_phone');
    my $shipping_address = $c->param('shipping_address');
    my $shipping_city = $c->param('shipping_city');
    my $shipping_postal_code = $c->param('shipping_postal_code');
    my $shipping_country = $c->param('shipping_country');

    unless ($shipping_name && $shipping_phone && $shipping_address && $shipping_city && $shipping_postal_code && $shipping_country) {
        $c->flash(error => 'All shipping fields are required');
        return $c->redirect_to('/checkout');
    }

    my $user = $c->get_session_user;
    
    # Get cart total
    my $stmt = $db->prepare(q{
        SELECT SUM(p.price * ci.quantity) as total
        FROM cart_items ci
        JOIN products p ON ci.product_id = p.id
        WHERE ci.user_id = ?
    });
    $stmt->execute($user->{id});
    my $result = $stmt->fetchrow_hashref;
    my $total = $result->{total} || 0;

    if ($total <= 0) {
        $c->flash(error => 'Your cart is empty');
        return $c->redirect_to('/cart');
    }

    my $currency = $c->current_currency;
    my $language = $c->current_language;
    my $tracking_number = $c->generate_tracking_number;

    $c->session(pending_checkout => {
        user_id => $user->{id},
        shipping_name => $shipping_name,
        shipping_phone => $shipping_phone,
        shipping_address => $shipping_address,
        shipping_city => $shipping_city,
        shipping_postal_code => $shipping_postal_code,
        shipping_country => $shipping_country,
        currency => $currency,
        language => $language,
        tracking_number => $tracking_number,
    });

    $c->redirect_to('/payment');
};

# Payment page
get '/payment' => sub ($c) {
    $c->require_auth or return;

    my $user = $c->get_session_user;
    my $pending = $c->session('pending_checkout');
    unless ($pending && $pending->{user_id} && $pending->{user_id} == $user->{id}) {
        $c->flash(error => 'Please complete shipping details before payment');
        return $c->redirect_to('/checkout');
    }

    my $items_stmt = $db->prepare(q{
        SELECT ci.id, p.id as product_id, p.name, p.price, ci.quantity
        FROM cart_items ci
        JOIN products p ON ci.product_id = p.id
        WHERE ci.user_id = ?
    });
    $items_stmt->execute($user->{id});
    my @items;
    my $total = 0;
    while (my $item = $items_stmt->fetchrow_hashref) {
        $item->{subtotal} = $item->{price} * $item->{quantity};
        $total += $item->{subtotal};
        push @items, $item;
    }

    if (!@items) {
        delete $c->session->{pending_checkout};
        $c->flash(error => 'Your cart is empty');
        return $c->redirect_to('/cart');
    }

    my $converted_total = $c->convert_from_usd($total, $pending->{currency});
    $c->render(template => 'payment', pending => $pending, items => \@items, total => $converted_total);
};

# Payment confirmation
post '/payment' => sub ($c) {
    $c->require_auth or return;

    my $user = $c->get_session_user;
    my $pending = $c->session('pending_checkout');
    unless ($pending && $pending->{user_id} && $pending->{user_id} == $user->{id}) {
        $c->flash(error => 'Please complete shipping details before payment');
        return $c->redirect_to('/checkout');
    }

    my $payment_method = $c->param('payment_method') // '';
    my %allowed = map { $_ => 1 } qw(card upi net_banking cash_on_delivery paypal);
    unless ($allowed{$payment_method}) {
        $c->flash(error => 'Select a valid payment method');
        return $c->redirect_to('/payment');
    }

    my $payment_reference = '';
    if ($payment_method eq 'card') {
        my $card_holder = $c->param('card_holder') // '';
        my $card_number = $c->param('card_number') // '';
        my $cvv = $c->param('cvv') // '';
        my $expiry_month = $c->param('expiry_month') // '';
        my $expiry_year = $c->param('expiry_year') // '';
        unless ($card_holder && $card_number =~ /^\d{12,19}$/ && $cvv =~ /^\d{3,4}$/ && $expiry_month =~ /^(0[1-9]|1[0-2])$/ && $expiry_year =~ /^\d{4}$/) {
            $c->flash(error => 'Enter valid card details');
            return $c->redirect_to('/payment');
        }
        $payment_reference = 'CARD-' . substr($card_number, -4);
    } elsif ($payment_method eq 'upi') {
        my $upi_id = $c->param('upi_id') // '';
        unless ($upi_id =~ /^[a-zA-Z0-9.\-_]{2,}@[a-zA-Z]{2,}$/) {
            $c->flash(error => 'Enter a valid UPI ID');
            return $c->redirect_to('/payment');
        }
        $payment_reference = 'UPI-' . $upi_id;
    } elsif ($payment_method eq 'net_banking') {
        my $bank_name = $c->param('bank_name') // '';
        my $account_last4 = $c->param('account_last4') // '';
        unless ($bank_name && $account_last4 =~ /^\d{4}$/) {
            $c->flash(error => 'Enter valid net banking details');
            return $c->redirect_to('/payment');
        }
        $payment_reference = "NB-$bank_name-$account_last4";
    } elsif ($payment_method eq 'paypal') {
        my $paypal_email = $c->param('paypal_email') // '';
        unless ($paypal_email =~ /^[^\s\@]+\@[^\s\@]+\.[^\s\@]+$/) {
            $c->flash(error => 'Enter a valid PayPal email');
            return $c->redirect_to('/payment');
        }
        $payment_reference = "PAYPAL-$paypal_email";
    } else {
        $payment_reference = 'COD';
    }

    my $cart_stmt = $db->prepare(q{
        SELECT ci.id, p.id as product_id, p.price, p.cost_price, p.gst_rate, p.hsn_code, p.name, p.stock, ci.quantity
        FROM cart_items ci
        JOIN products p ON ci.product_id = p.id
        WHERE ci.user_id = ?
    });
    $cart_stmt->execute($user->{id});
    my @items;
    my $sub_total = 0;
    my $gst_total = 0;
    my $grand_total = 0;
    while (my $item = $cart_stmt->fetchrow_hashref) {
        $item->{gst_rate} = defined $item->{gst_rate} ? $item->{gst_rate} : 18;
        $item->{taxable_amount} = $item->{price} * $item->{quantity};
        $item->{tax_amount} = $item->{taxable_amount} * ($item->{gst_rate} / 100);
        $item->{line_total} = $item->{taxable_amount} + $item->{tax_amount};
        $item->{unit_cost} = $item->{cost_price} // 0;
        $sub_total += $item->{taxable_amount};
        $gst_total += $item->{tax_amount};
        $grand_total += $item->{line_total};
        push @items, $item;
    }

    if (!@items || $grand_total <= 0) {
        delete $c->session->{pending_checkout};
        $c->flash(error => 'Your cart is empty');
        return $c->redirect_to('/cart');
    }

    my $converted_total = $c->convert_from_usd($grand_total, $pending->{currency});
    my $order_id;
    eval {
        $db->begin_work;

        my $order_stmt = $db->prepare(q{
            INSERT INTO orders (
                user_id, total_price, status, shipping_address, shipping_name, shipping_phone,
                shipping_city, shipping_postal_code, shipping_country, payment_method, payment_reference,
                payment_status, currency, language, tracking_number, confirmation_email_status
            )
            VALUES (?, ?, 'confirmed', ?, ?, ?, ?, ?, ?, ?, ?, 'paid', ?, ?, ?, 'not_sent')
        });
        $order_stmt->execute(
            $user->{id}, $converted_total,
            $pending->{shipping_address}, $pending->{shipping_name}, $pending->{shipping_phone},
            $pending->{shipping_city}, $pending->{shipping_postal_code}, $pending->{shipping_country},
            $payment_method, $payment_reference,
            $pending->{currency}, $pending->{language}, $pending->{tracking_number}
        );
        $order_id = $db->last_insert_id(undef, undef, 'orders', undef);

        for my $item (@items) {
            if ($item->{quantity} > $item->{stock}) {
                die "Insufficient stock for $item->{name}. Available: $item->{stock}";
            }
        }

        for my $item (@items) {
            my $converted_price = $c->convert_from_usd($item->{price}, $pending->{currency});
            my $converted_cost = $c->convert_from_usd($item->{unit_cost}, $pending->{currency});
            my $converted_taxable = $c->convert_from_usd($item->{taxable_amount}, $pending->{currency});
            my $converted_tax = $c->convert_from_usd($item->{tax_amount}, $pending->{currency});
            my $converted_line_total = $c->convert_from_usd($item->{line_total}, $pending->{currency});
            $item->{line_total} = $converted_line_total;
            $db->do(q{
                INSERT INTO order_items (
                    order_id, product_id, product_name_snapshot, hsn_code, quantity, price,
                    unit_cost, gst_rate, taxable_amount, tax_amount, line_total
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            }, undef,
                $order_id, $item->{product_id}, $item->{name}, ($item->{hsn_code} // '0000'),
                $item->{quantity}, $converted_price, $converted_cost, $item->{gst_rate},
                $converted_taxable, $converted_tax, $converted_line_total
            );

            my $updated = $db->do(
                'UPDATE products SET stock = stock - ? WHERE id = ? AND stock >= ?',
                undef, $item->{quantity}, $item->{product_id}, $item->{quantity}
            );
            if (!$updated) {
                die "Stock changed for $item->{name}. Please review cart and try again.";
            }
        }

        $db->do('DELETE FROM cart_items WHERE user_id = ?', undef, $user->{id});
        $db->commit;
    };

    if ($@) {
        eval { $db->rollback };
        my $error = "$@";
        $error =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*$//;
        $c->flash(error => $error);
        return $c->redirect_to('/cart');
    }

    my $order = {
        id => $order_id,
        status => 'confirmed',
        payment_status => 'paid',
        payment_method => $payment_method,
        total_price => $converted_total,
        tracking_number => $pending->{tracking_number},
        currency => $pending->{currency},
        shipping_name => $pending->{shipping_name},
        shipping_phone => $pending->{shipping_phone},
        shipping_address => $pending->{shipping_address},
        shipping_city => $pending->{shipping_city},
        shipping_postal_code => $pending->{shipping_postal_code},
        shipping_country => $pending->{shipping_country},
    };
    my $email_result = $c->send_order_confirmation_email($user, $order, \@items);

    $db->do(q{
        UPDATE orders
        SET payment_method = ?, payment_status = 'paid', status = 'confirmed',
            payment_reference = ?, confirmation_email_status = ?, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
    }, undef, $payment_method, $payment_reference, $email_result->{status}, $order_id);

    delete $c->session->{pending_checkout};

    $c->flash(success => $c->t('order_confirmed'));
    $c->redirect_to("/order/$order_id");
};

# View order
get '/order/:id' => sub ($c) {
    $c->require_auth or return;
    
    my $user = $c->get_session_user;
    my $order_id = $c->param('id');
    
    my $stmt = $db->prepare('SELECT * FROM orders WHERE id = ? AND user_id = ?');
    $stmt->execute($order_id, $user->{id});
    my $order = $stmt->fetchrow_hashref;
    
    return $c->render(text => 'Order not found', status => 404) unless $order;
    
    my $items_stmt = $db->prepare(q{
        SELECT oi.*, COALESCE(oi.product_name_snapshot, p.name) AS name
        FROM order_items oi
        LEFT JOIN products p ON oi.product_id = p.id
        WHERE oi.order_id = ?
    });
    $items_stmt->execute($order_id);
    my @items;
    while (my $item = $items_stmt->fetchrow_hashref) {
        push @items, $item;
    }
    
    $c->render(template => 'order_detail', order => $order, items => \@items);
};

# Invoice page
get '/invoice/:id' => sub ($c) {
    $c->require_auth or return;

    my $user = $c->get_session_user;
    my $order_id = $c->param('id');
    my $order_stmt = $db->prepare('SELECT * FROM orders WHERE id = ?');
    $order_stmt->execute($order_id);
    my $order = $order_stmt->fetchrow_hashref;
    return $c->render(text => 'Invoice not found', status => 404) unless $order;

    unless ($c->has_access($user, qw(admin manager support)) || $order->{user_id} == $user->{id}) {
        return $c->render(text => 'Unauthorized', status => 403);
    }

    my $items_stmt = $db->prepare(q{
        SELECT oi.*, COALESCE(oi.product_name_snapshot, p.name) AS name
        FROM order_items oi
        LEFT JOIN products p ON oi.product_id = p.id
        WHERE oi.order_id = ?
    });
    $items_stmt->execute($order_id);
    my @items;
    my $taxable_total = 0;
    my $gst_total = 0;
    my $grand_total = 0;
    while (my $item = $items_stmt->fetchrow_hashref) {
        $taxable_total += $item->{taxable_amount} // ($item->{price} * $item->{quantity});
        $gst_total += $item->{tax_amount} // 0;
        $grand_total += $item->{line_total} // ($item->{price} * $item->{quantity});
        push @items, $item;
    }

    my ($cgst_total, $sgst_total) = $c->gst_split($gst_total);
    my $invoice_number = $c->invoice_number($order_id);
    $c->render(template => 'invoice',
        order => $order,
        items => \@items,
        taxable_total => $taxable_total,
        gst_total => $gst_total,
        cgst_total => $cgst_total,
        sgst_total => $sgst_total,
        grand_total => $grand_total,
        invoice_number => $invoice_number
    );
};

# Admin Routes

# Admin dashboard
get '/admin' => sub ($c) {
    $c->require_roles(qw(admin manager editor support)) or return;
    
    my $product_count = $db->selectrow_array('SELECT COUNT(*) FROM products');
    my $order_count = $db->selectrow_array('SELECT COUNT(*) FROM orders');
    my $user_count = $db->selectrow_array('SELECT COUNT(*) FROM users');
    
    $c->render(template => 'admin_dashboard', 
        products => $product_count,
        orders => $order_count,
        users => $user_count,
        paid_orders => $db->selectrow_array("SELECT COUNT(*) FROM orders WHERE payment_status = 'paid'")
    );
};

get '/admin/users' => sub ($c) {
    $c->require_admin or return;

    my @users = @{ $db->selectall_arrayref(q{
        SELECT id, username, email, role, is_admin, is_active, created_at
        FROM users
        ORDER BY id ASC
    }, { Slice => {} }) };

    $c->render(template => 'admin_users', users => \@users);
};

post '/admin/user/:id/role' => sub ($c) {
    $c->require_admin or return;

    my $id = $c->param('id');
    my $role = $c->normalize_role($c->param('role'));
    my $target = $db->selectrow_hashref('SELECT id, is_admin FROM users WHERE id = ?', undef, $id);
    return $c->render(text => 'User not found', status => 404) unless $target;

    if ($target->{is_admin}) {
        $role = 'admin';
    }

    $db->do('UPDATE users SET role = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?', undef, $role, $id);
    $c->flash(success => 'User role updated');
    $c->redirect_to('/admin/users');
};

post '/admin/user/:id/access' => sub ($c) {
    $c->require_admin or return;

    my $id = $c->param('id');
    my $is_active = ($c->param('is_active') // 0) ? 1 : 0;
    my $target = $db->selectrow_hashref('SELECT id, is_admin FROM users WHERE id = ?', undef, $id);
    return $c->render(text => 'User not found', status => 404) unless $target;

    if ($target->{is_admin} && !$is_active) {
        $c->flash(error => 'Admin account cannot be disabled');
        return $c->redirect_to('/admin/users');
    }

    $db->do('UPDATE users SET is_active = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?', undef, $is_active, $id);
    $c->flash(success => 'User access updated');
    $c->redirect_to('/admin/users');
};

get '/admin/reels' => sub ($c) {
    $c->require_roles(qw(admin editor)) or return;

    my @products = @{ $db->selectall_arrayref(
        'SELECT id, name, category, image_url FROM products ORDER BY id DESC LIMIT 100',
        { Slice => {} }
    ) };
    my @jobs = @{ $db->selectall_arrayref(q{
        SELECT rj.*, p.name AS product_name
        FROM reel_jobs rj
        JOIN products p ON p.id = rj.product_id
        ORDER BY rj.created_at DESC
        LIMIT 50
    }, { Slice => {} }) };

    $c->render(template => 'admin_reels',
        products => \@products,
        jobs => \@jobs,
        config => {
            public_base_url => $c->get_setting('meta_public_base_url'),
            ig_user_id => $c->get_setting('meta_ig_user_id'),
            model_clip_path => $c->get_setting('meta_model_clip_path'),
        }
    );
};

post '/admin/reels/config' => sub ($c) {
    $c->require_roles(qw(admin editor)) or return;

    my $public_base_url = $c->param('public_base_url') // '';
    my $ig_user_id = $c->param('ig_user_id') // '';
    my $access_token = $c->param('access_token') // '';
    my $model_clip_path = $c->param('model_clip_path') // '';

    unless ($public_base_url =~ m{^https?://} && $ig_user_id && $access_token && $model_clip_path) {
        $c->flash(error => 'All Meta reel config fields are required');
        return $c->redirect_to('/admin/reels');
    }

    $c->set_setting('meta_public_base_url', $public_base_url);
    $c->set_setting('meta_ig_user_id', $ig_user_id);
    $c->set_setting('meta_access_token', $access_token);
    $c->set_setting('meta_model_clip_path', $model_clip_path);

    $c->flash(success => 'Meta reels configuration saved');
    $c->redirect_to('/admin/reels');
};

post '/admin/reels/run/:product_id' => sub ($c) {
    $c->require_roles(qw(admin editor)) or return;

    my $product_id = $c->param('product_id');
    my $caption = $c->param('caption') // '';
    my $product = $db->selectrow_hashref(
        'SELECT * FROM products WHERE id = ?',
        undef, $product_id
    );
    unless ($product) {
        $c->flash(error => 'Product not found');
        return $c->redirect_to('/admin/reels');
    }

    $caption ||= "Now live: $product->{name} #vgagbusinesssuite #reels";

    $db->do(
        "INSERT INTO reel_jobs (product_id, caption, status, created_at, updated_at) VALUES (?, ?, 'pending', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
        undef, $product_id, $caption
    );
    my $reel_job_id = $db->last_insert_id(undef, undef, 'reel_jobs', undef);

    eval {
        my ($local_video_path, $reel_url) = $c->generate_reel_video($product, $caption);
        $db->do(
            "UPDATE reel_jobs SET local_video_path = ?, reel_url = ?, status = 'generated', updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            undef, $local_video_path, $reel_url, $reel_job_id
        );

        my ($creation_id, $media_id) = $c->create_and_publish_reel($reel_url, $caption);
        $db->do(q{
            UPDATE reel_jobs
            SET status = 'posted', meta_creation_id = ?, meta_media_id = ?, updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
        }, undef, $creation_id, $media_id, $reel_job_id);
    };

    if ($@) {
        my $error = "$@";
        $error =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*$//;
        $db->do(
            "UPDATE reel_jobs SET status = 'failed', error_message = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            undef, $error, $reel_job_id
        );
        $c->flash(error => "Reel automation failed: $error");
        return $c->redirect_to('/admin/reels');
    }

    $c->flash(success => 'Reel generated and posted successfully');
    $c->redirect_to('/admin/reels');
};

# Manage products
get '/admin/products' => sub ($c) {
    $c->require_roles(qw(admin manager editor)) or return;
    
    my @products = ();
    my $stmt = $db->prepare('SELECT * FROM products');
    $stmt->execute;
    while (my $row = $stmt->fetchrow_hashref) {
        push @products, $row;
    }
    
    $c->render(template => 'admin_products', products => \@products);
};

# Add product form
get '/admin/product/add' => sub ($c) {
    $c->require_roles(qw(admin manager editor)) or return;
    $c->render(template => 'admin_product_form');
};

# Add product
post '/admin/product' => sub ($c) {
    $c->require_roles(qw(admin manager editor)) or return;
    
    my $name = $c->param('name');
    my $description = $c->param('description');
    my $price = $c->param('price');
    my $cost_price = $c->param('cost_price') // 0;
    my $stock = $c->param('stock');
    my $gst_rate = $c->param('gst_rate') // 18;
    my $hsn_code = $c->param('hsn_code') // '0000';
    my $category = $c->param('category');
    my $sku = $c->param('sku');
    
    $db->do(q{
        INSERT INTO products (name, description, price, cost_price, stock, gst_rate, hsn_code, category, sku)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    }, undef, $name, $description, $price, $cost_price, $stock, $gst_rate, $hsn_code, $category, $sku);
    
    $c->redirect_to('/admin/products');
};

# Edit product
get '/admin/product/:id/edit' => sub ($c) {
    $c->require_roles(qw(admin manager editor)) or return;
    
    my $id = $c->param('id');
    my $stmt = $db->prepare('SELECT * FROM products WHERE id = ?');
    $stmt->execute($id);
    my $product = $stmt->fetchrow_hashref;
    
    $c->render(template => 'admin_product_form', product => $product);
};

# Update product
post '/admin/product/:id' => sub ($c) {
    $c->require_roles(qw(admin manager editor)) or return;
    
    my $id = $c->param('id');
    my $name = $c->param('name');
    my $description = $c->param('description');
    my $price = $c->param('price');
    my $cost_price = $c->param('cost_price') // 0;
    my $stock = $c->param('stock');
    my $gst_rate = $c->param('gst_rate') // 18;
    my $hsn_code = $c->param('hsn_code') // '0000';
    my $category = $c->param('category');
    
    $db->do(q{
        UPDATE products 
        SET name = ?, description = ?, price = ?, cost_price = ?, stock = ?, gst_rate = ?, hsn_code = ?, category = ?
        WHERE id = ?
    }, undef, $name, $description, $price, $cost_price, $stock, $gst_rate, $hsn_code, $category, $id);
    
    $c->redirect_to('/admin/products');
};

# Delete product
post '/admin/product/:id/delete' => sub ($c) {
    $c->require_roles(qw(admin manager editor)) or return;
    
    my $id = $c->param('id');
    $db->do('DELETE FROM products WHERE id = ?', undef, $id);
    
    $c->render(json => {success => 1});
};

# Manage orders
get '/admin/orders' => sub ($c) {
    $c->require_roles(qw(admin manager support)) or return;
    
    my @orders = ();
    my $stmt = $db->prepare(q{
        SELECT o.*, u.username, u.email
        FROM orders o
        JOIN users u ON o.user_id = u.id
        ORDER BY o.created_at DESC
    });
    $stmt->execute;
    while (my $row = $stmt->fetchrow_hashref) {
        push @orders, $row;
    }
    
    $c->render(template => 'admin_orders', orders => \@orders);
};

# Sales and GST reports
get '/admin/reports' => sub ($c) {
    $c->require_roles(qw(admin manager)) or return;

    my @paid_orders = @{ $db->selectall_arrayref(q{
        SELECT id, total_price, currency, created_at
        FROM orders
        WHERE payment_status = 'paid'
        ORDER BY created_at DESC
    }, { Slice => {} }) };

    my @report_items = @{ $db->selectall_arrayref(q{
        SELECT oi.product_name_snapshot, oi.quantity, oi.unit_cost, oi.taxable_amount, oi.tax_amount, oi.line_total, oi.gst_rate, o.currency, o.created_at
        FROM order_items oi
        JOIN orders o ON oi.order_id = o.id
        WHERE o.payment_status = 'paid'
    }, { Slice => {} }) };

    my $total_sales_inr = 0;
    my $today_sales_inr = 0;
    my $month_sales_inr = 0;
    my %daily_sales_inr;
    for my $order (@paid_orders) {
        my $amount_inr = $c->convert_currency_amount($order->{total_price}, ($order->{currency} // 'INR'), 'INR');
        $total_sales_inr += $amount_inr;

        if ($order->{created_at} =~ /^(\d{4}-\d{2}-\d{2})/) {
            my $day = $1;
            $daily_sales_inr{$day} += $amount_inr;

            my $today = strftime('%Y-%m-%d', localtime());
            my $month = strftime('%Y-%m', localtime());
            $today_sales_inr += $amount_inr if $day eq $today;
            $month_sales_inr += $amount_inr if index($day, $month) == 0;
        }
    }

    my $taxable_sales_inr = 0;
    my $gst_total_inr = 0;
    my $cogs_inr = 0;
    my %top_product_qty;
    for my $item (@report_items) {
        my $from_currency = $item->{currency} // 'INR';
        $taxable_sales_inr += $c->convert_currency_amount($item->{taxable_amount} // 0, $from_currency, 'INR');
        $gst_total_inr += $c->convert_currency_amount($item->{tax_amount} // 0, $from_currency, 'INR');
        $cogs_inr += $c->convert_currency_amount(($item->{unit_cost} // 0) * ($item->{quantity} // 0), $from_currency, 'INR');
        $top_product_qty{$item->{product_name_snapshot} // 'Unknown Product'} += $item->{quantity} // 0;
    }

    my ($cgst_inr, $sgst_inr) = $c->gst_split($gst_total_inr);
    my $gross_profit_inr = $taxable_sales_inr - $cogs_inr;

    my @sales_by_day = map {
        { day => $_, total_inr => $daily_sales_inr{$_} }
    } sort { $b cmp $a } keys %daily_sales_inr;
    @sales_by_day = @sales_by_day[0 .. 29] if @sales_by_day > 30;

    my @top_products = map {
        { name => $_, qty => $top_product_qty{$_} }
    } sort { $top_product_qty{$b} <=> $top_product_qty{$a} } keys %top_product_qty;
    @top_products = @top_products[0 .. 9] if @top_products > 10;

    $c->render(template => 'admin_reports',
        total_sales_inr => $total_sales_inr,
        today_sales_inr => $today_sales_inr,
        month_sales_inr => $month_sales_inr,
        taxable_sales_inr => $taxable_sales_inr,
        gst_total_inr => $gst_total_inr,
        cgst_inr => $cgst_inr,
        sgst_inr => $sgst_inr,
        cogs_inr => $cogs_inr,
        gross_profit_inr => $gross_profit_inr,
        sales_by_day => \@sales_by_day,
        top_products => \@top_products
    );
};

# Update order status
post '/admin/order/:id/status' => sub ($c) {
    $c->require_roles(qw(admin manager support)) or return;
    
    my $id = $c->param('id');
    my $status = $c->param('status');
    
    $db->do('UPDATE orders SET status = ? WHERE id = ?', undef, $status, $id);
    
    $c->render(json => {success => 1});
};

# Shiprocket Admin Settings
get '/admin/otp-settings' => sub ($c) {
    $c->require_roles(qw(admin manager)) or return;

    my $config = $c->otp_settings;
    $c->render(template => 'admin_otp_settings', config => $config);
};

post '/admin/otp-settings' => sub ($c) {
    $c->require_roles(qw(admin manager)) or return;

    my $expiry_minutes = $c->param('expiry_minutes') // 10;
    my $email_subject = $c->param('email_subject') // '';
    my $sms_gateway_url_template = $c->param('sms_gateway_url_template') // '';
    my $sms_sender_id = $c->param('sms_sender_id') // '';
    my $sms_api_key = $c->param('sms_api_key') // '';

    unless ($expiry_minutes =~ /^\d+$/ && $expiry_minutes >= 3 && $expiry_minutes <= 30) {
        $c->flash(error => 'OTP expiry must be between 3 and 30 minutes.');
        return $c->redirect_to('/admin/otp-settings');
    }

    if ($sms_gateway_url_template) {
        for my $required_token (qw({phone} {message})) {
            unless (index($sms_gateway_url_template, $required_token) >= 0) {
                $c->flash(error => 'SMS gateway URL template must include {phone} and {message}.');
                return $c->redirect_to('/admin/otp-settings');
            }
        }
    }

    $c->set_setting('otp_expiry_minutes', $expiry_minutes);
    $c->set_setting('otp_email_subject', $email_subject || 'VGAG BUSINESS SUITE login OTP');
    $c->set_setting('sms_gateway_url_template', $sms_gateway_url_template);
    $c->set_setting('sms_sender_id', $sms_sender_id);
    $c->set_setting('sms_api_key', $sms_api_key);

    $c->flash(success => 'OTP settings saved.');
    $c->redirect_to('/admin/otp-settings');
};

get '/admin/shiprocket' => sub ($c) {
    $c->require_roles(qw(admin manager)) or return;
    
    my $token = $c->shiprocket_auth_token;
    my $customer_id = $c->get_setting('shiprocket_customer_id', '');
    
    $c->render(template => 'admin_shiprocket',
        token => $token ? '***CONFIGURED***' : 'Not configured',
        customer_id => $customer_id
    );
};

post '/admin/shiprocket/login' => sub ($c) {
    $c->require_roles(qw(admin manager)) or return;
    
    my $email = $c->param('email') // '';
    my $password = $c->param('password') // '';
    
    my $result = $c->shiprocket_login($email, $password);
    
    if ($result->{success}) {
        $c->flash(message => 'Shiprocket authenticated successfully!');
    } else {
        $c->flash(error => 'Shiprocket auth failed: ' . $result->{error});
    }
    
    $c->redirect_to('/admin/shiprocket');
};

get '/admin/slack' => sub ($c) {
    $c->require_roles(qw(admin manager support)) or return;

    my $config = $c->slack_connect_config;
    my @requests = @{ $db->selectall_arrayref(q{
        SELECT scr.*, u.username
        FROM slack_connection_requests scr
        LEFT JOIN users u ON u.id = scr.user_id
        ORDER BY scr.created_at DESC
        LIMIT 100
    }, { Slice => {} }) };

    $c->render(template => 'admin_slack',
        config => $config,
        requests => \@requests
    );
};

post '/admin/slack/config' => sub ($c) {
    $c->require_roles(qw(admin manager)) or return;

    my $workspace_name = $c->param('workspace_name') // '';
    my $workspace_url = $c->param('workspace_url') // '';
    my $invite_url = $c->param('invite_url') // '';
    my $channel_name = $c->param('channel_name') // '';
    my $channel_url = $c->param('channel_url') // '';
    my $help_text = $c->param('help_text') // '';

    unless ($workspace_name && $workspace_url =~ m{^https?://}) {
        $c->flash(error => 'Workspace name and a valid workspace URL are required.');
        return $c->redirect_to('/admin/slack');
    }

    for my $optional_url ($invite_url, $channel_url) {
        next unless $optional_url;
        unless ($optional_url =~ m{^https?://}) {
            $c->flash(error => 'Invite and channel URLs must start with http:// or https://');
            return $c->redirect_to('/admin/slack');
        }
    }

    $c->set_setting('slack_workspace_name', $workspace_name);
    $c->set_setting('slack_workspace_url', $workspace_url);
    $c->set_setting('slack_invite_url', $invite_url);
    $c->set_setting('slack_channel_name', $channel_name);
    $c->set_setting('slack_channel_url', $channel_url);
    $c->set_setting('slack_help_text', $help_text);

    $c->flash(success => 'Slack Connect settings saved.');
    $c->redirect_to('/admin/slack');
};

post '/admin/slack/request/:id/status' => sub ($c) {
    $c->require_roles(qw(admin manager support)) or return;

    my $id = $c->param('id');
    my $status = lc($c->param('status') // '');
    my %allowed = map { $_ => 1 } qw(requested invited connected blocked);
    unless ($allowed{$status}) {
        $c->flash(error => 'Invalid Slack request status.');
        return $c->redirect_to('/admin/slack');
    }

    $db->do(
        'UPDATE slack_connection_requests SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
        undef,
        $status,
        $id
    );

    $c->flash(success => 'Slack request status updated.');
    $c->redirect_to('/admin/slack');
};

post '/admin/order/:id/create-shipment' => sub ($c) {
    $c->require_roles(qw(admin manager support)) or return;
    
    my $order_id = $c->param('id');
    my $result = $c->shiprocket_create_shipment($order_id);
    
    if ($result->{success}) {
        $db->do('UPDATE orders SET status = ? WHERE id = ?', undef, 'shipped', $order_id);
        $c->flash(message => 'Shipment created: ' . $result->{shipment_id});
    } else {
        $c->flash(error => 'Shipment creation failed: ' . $result->{error});
    }
    
    $c->redirect_to('/admin/orders');
};

get '/admin/order/:id/tracking' => sub ($c) {
    $c->require_roles(qw(admin manager support)) or return;
    
    my $order_id = $c->param('id');
    my $order = $db->selectrow_hashref('SELECT * FROM orders WHERE id = ?', undef, $order_id);
    
    return $c->render(json => { error => 'Order not found' }) unless $order;
    
    if ($order->{tracking_number}) {
        my $tracking = $c->shiprocket_get_tracking($order->{tracking_number});
        $c->render(json => $tracking);
    } else {
        $c->render(json => { error => 'No shipment created yet' });
    }
};

get '/order/:id/track' => sub ($c) {
    my $id = $c->param('id');
    my $order = $db->selectrow_hashref('SELECT * FROM orders WHERE id = ?', undef, $id);
    
    return $c->redirect_to('/') unless $order;
    
    my $tracking_data = {};
    if ($order->{tracking_number}) {
        my $tracking = $c->shiprocket_get_tracking($order->{tracking_number});
        $tracking_data = $tracking->{tracking} // {};
    }
    
    $c->render(template => 'order_tracking',
        order => $order,
        tracking => $tracking_data
    );
};

app->secrets(['vgag-business-suite-secret-key']);
app->start;
