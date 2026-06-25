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
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    });

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

hook before_dispatch => sub ($c) {
    $c->session(lang => 'en') unless $c->session('lang');
    $c->session(currency => 'USD') unless $c->session('currency');
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

helper require_auth => sub ($c) {
    unless ($c->session('user_id')) {
        $c->redirect_to('/login');
        return 0;
    }
    return 1;
};

helper require_admin => sub ($c) {
    my $user = $c->get_session_user;
    unless ($user && $user->{is_admin}) {
        $c->render(text => 'Unauthorized', status => 403);
        return 0;
    }
    return 1;
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
    my $password = $c->param('password');
    my $confirm = $c->param('confirm_password');
    
    unless ($password eq $confirm) {
        return $c->render(template => 'register', error => 'Passwords do not match');
    }
    
    my $hashed_pwd = sha256_hex($password);
    
    eval {
        my $stmt = $db->prepare(
            'INSERT INTO users (username, email, password) VALUES (?, ?, ?)'
        );
        $stmt->execute($username, $email, $hashed_pwd);
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
    my $stmt = $db->prepare('SELECT id FROM users WHERE username = ? AND password = ?');
    $stmt->execute($username, $hashed_pwd);
    my $user = $stmt->fetchrow_hashref;
    
    unless ($user) {
        return $c->render(template => 'login', error => 'Invalid credentials');
    }
    
    $c->session(user_id => $user->{id});
    $c->redirect_to('/');
};

# Logout
get '/logout' => sub ($c) {
    delete $c->session->{user_id};
    $c->redirect_to('/');
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

    unless ($user->{is_admin} || $order->{user_id} == $user->{id}) {
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
    $c->require_admin or return;
    
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

get '/admin/reels' => sub ($c) {
    $c->require_admin or return;

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
    $c->require_admin or return;

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
    $c->require_admin or return;

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
    $c->require_admin or return;
    
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
    $c->require_admin or return;
    $c->render(template => 'admin_product_form');
};

# Add product
post '/admin/product' => sub ($c) {
    $c->require_admin or return;
    
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
    $c->require_admin or return;
    
    my $id = $c->param('id');
    my $stmt = $db->prepare('SELECT * FROM products WHERE id = ?');
    $stmt->execute($id);
    my $product = $stmt->fetchrow_hashref;
    
    $c->render(template => 'admin_product_form', product => $product);
};

# Update product
post '/admin/product/:id' => sub ($c) {
    $c->require_admin or return;
    
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
    $c->require_admin or return;
    
    my $id = $c->param('id');
    $db->do('DELETE FROM products WHERE id = ?', undef, $id);
    
    $c->render(json => {success => 1});
};

# Manage orders
get '/admin/orders' => sub ($c) {
    $c->require_admin or return;
    
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
    $c->require_admin or return;

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
    $c->require_admin or return;
    
    my $id = $c->param('id');
    my $status = $c->param('status');
    
    $db->do('UPDATE orders SET status = ? WHERE id = ?', undef, $status, $id);
    
    $c->render(json => {success => 1});
};

# Shiprocket Admin Settings
get '/admin/shiprocket' => sub ($c) {
    $c->require_admin or return;
    
    my $token = $c->shiprocket_auth_token;
    my $customer_id = $c->get_setting('shiprocket_customer_id', '');
    
    $c->render(template => 'admin_shiprocket',
        token => $token ? '***CONFIGURED***' : 'Not configured',
        customer_id => $customer_id
    );
};

post '/admin/shiprocket/login' => sub ($c) {
    $c->require_admin or return;
    
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

post '/admin/order/:id/create-shipment' => sub ($c) {
    $c->require_admin or return;
    
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
    $c->require_admin or return;
    
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
