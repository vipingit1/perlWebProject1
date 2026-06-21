#!/usr/bin/perl
use strict;
use warnings;
use Mojolicious::Lite -signatures;
use DBI;
use DBD::SQLite;
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use DateTime;
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime);

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

app.pl - VGAG SUITE Ecommerce Web Application

=head1 DESCRIPTION

A complete ecommerce platform for VGAG SUITE built with Mojolicious framework featuring:
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
            stock INTEGER DEFAULT 0,
            category TEXT,
            image_url TEXT,
            sku TEXT UNIQUE,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    });

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
            quantity INTEGER NOT NULL,
            price REAL NOT NULL,
            FOREIGN KEY(order_id) REFERENCES orders(id) ON DELETE CASCADE,
            FOREIGN KEY(product_id) REFERENCES products(id)
        )
    });

    return $db;
}

my $db = init_db();

# Helpers
helper db => sub { return $db };

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

helper generate_tracking_number => sub {
    my $stamp = strftime('%Y%m%d%H%M%S', gmtime());
    my $rand = int(rand(9000)) + 1000;
    return "VGAG$stamp$rand";
};

helper send_order_confirmation_email => sub ($c, $user, $order, $items) {
    my $subject = $c->t('order_confirmation_subject') . " #$order->{id}";
    my $line_items = join("\n", map {
        "- $_->{name} x$_->{quantity} = " . $c->format_money($_->{price} * $_->{quantity}, $order->{currency})
    } @$items);

    my $body = <<"EMAIL";
Hello $user->{username},

Thank you for your order with VGAG SUITE.
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

EMAIL

    my $smtp_host = $ENV{SMTP_HOST} // '';
    if ($smtp_host) {
        require Net::SMTP;
        my $smtp = Net::SMTP->new($smtp_host, Timeout => 20);
        die "Unable to connect SMTP host: $smtp_host" unless $smtp;

        my $from = $ENV{SMTP_FROM} // 'no-reply@vgagsuite.com';
        $smtp->mail($from);
        $smtp->to($user->{email});
        $smtp->data();
        $smtp->datasend("From: $from\n");
        $smtp->datasend("To: $user->{email}\n");
        $smtp->datasend("Subject: $subject\n\n");
        $smtp->datasend($body);
        $smtp->dataend();
        $smtp->quit;
        return { status => 'sent_via_smtp' };
    }

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
    
    # Check if product exists
    my $p_stmt = $db->prepare('SELECT id FROM products WHERE id = ?');
    $p_stmt->execute($product_id);
    unless ($p_stmt->fetchrow) {
        return $c->render(json => {error => 'Product not found'}, status => 404) if $wants_json;
        $c->flash(error => 'Product not found');
        return $c->redirect_to('/products');
    }
    
    # Check if already in cart
    my $c_stmt = $db->prepare('SELECT id FROM cart_items WHERE user_id = ? AND product_id = ?');
    $c_stmt->execute($user->{id}, $product_id);
    
    if (my $existing = $c_stmt->fetchrow_hashref) {
        $db->do(
            'UPDATE cart_items SET quantity = quantity + ? WHERE id = ?',
            undef, $quantity, $existing->{id}
        );
    } else {
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
    
    my $user = $c->get_session_user;
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
    my $converted_total = $c->convert_from_usd($total, $currency);
    
    # Create order
    my $order_stmt = $db->prepare(q{
        INSERT INTO orders (
            user_id, total_price, status, shipping_address, shipping_name, shipping_phone,
            shipping_city, shipping_postal_code, shipping_country, payment_method, payment_status,
            currency, language, tracking_number, confirmation_email_status
        )
        VALUES (?, ?, 'payment_pending', ?, ?, ?, ?, ?, ?, 'pending', 'pending', ?, ?, ?, 'not_sent')
    });
    $order_stmt->execute(
        $user->{id}, $converted_total, $shipping_address, $shipping_name, $shipping_phone,
        $shipping_city, $shipping_postal_code, $shipping_country, $currency, $language, $tracking_number
    );
    my $order_id = $db->last_insert_id(undef, undef, 'orders', undef);
    
    # Get cart items and create order items
    my $cart_stmt = $db->prepare(q{
        SELECT ci.id, p.id as product_id, p.price, ci.quantity
        FROM cart_items ci
        JOIN products p ON ci.product_id = p.id
        WHERE ci.user_id = ?
    });
    $cart_stmt->execute($user->{id});
    
    while (my $item = $cart_stmt->fetchrow_hashref) {
        my $converted_price = $c->convert_from_usd($item->{price}, $currency);
        $db->do(q{
            INSERT INTO order_items (order_id, product_id, quantity, price)
            VALUES (?, ?, ?, ?)
        }, undef, $order_id, $item->{product_id}, $item->{quantity}, $converted_price);
    }
    
    # Clear cart
    $db->do('DELETE FROM cart_items WHERE user_id = ?', undef, $user->{id});
    
    $c->redirect_to("/payment/$order_id");
};

# Payment page
get '/payment/:id' => sub ($c) {
    $c->require_auth or return;

    my $user = $c->get_session_user;
    my $order_id = $c->param('id');
    my $order_stmt = $db->prepare('SELECT * FROM orders WHERE id = ? AND user_id = ?');
    $order_stmt->execute($order_id, $user->{id});
    my $order = $order_stmt->fetchrow_hashref;

    return $c->render(text => 'Order not found', status => 404) unless $order;

    my $items_stmt = $db->prepare(q{
        SELECT oi.*, p.name
        FROM order_items oi
        JOIN products p ON oi.product_id = p.id
        WHERE oi.order_id = ?
    });
    $items_stmt->execute($order_id);
    my @items;
    while (my $item = $items_stmt->fetchrow_hashref) {
        push @items, $item;
    }

    $c->render(template => 'payment', order => $order, items => \@items);
};

# Payment confirmation
post '/payment/:id' => sub ($c) {
    $c->require_auth or return;

    my $user = $c->get_session_user;
    my $order_id = $c->param('id');
    my $payment_method = $c->param('payment_method') // '';
    my %allowed = map { $_ => 1 } qw(card upi net_banking cash_on_delivery paypal);
    unless ($allowed{$payment_method}) {
        $c->flash(error => 'Select a valid payment method');
        return $c->redirect_to("/payment/$order_id");
    }

    my $order_stmt = $db->prepare('SELECT * FROM orders WHERE id = ? AND user_id = ?');
    $order_stmt->execute($order_id, $user->{id});
    my $order = $order_stmt->fetchrow_hashref;
    return $c->render(text => 'Order not found', status => 404) unless $order;

    my $items_stmt = $db->prepare(q{
        SELECT oi.*, p.name
        FROM order_items oi
        JOIN products p ON oi.product_id = p.id
        WHERE oi.order_id = ?
    });
    $items_stmt->execute($order_id);
    my @items;
    while (my $item = $items_stmt->fetchrow_hashref) {
        push @items, $item;
    }

    $order->{payment_method} = $payment_method;
    $order->{payment_status} = 'paid';
    $order->{status} = 'confirmed';
    my $email_result = $c->send_order_confirmation_email($user, $order, \@items);

    $db->do(q{
        UPDATE orders
        SET payment_method = ?, payment_status = 'paid', status = 'confirmed',
            confirmation_email_status = ?, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
    }, undef, $payment_method, $email_result->{status}, $order_id);

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
        SELECT oi.*, p.name
        FROM order_items oi
        JOIN products p ON oi.product_id = p.id
        WHERE oi.order_id = ?
    });
    $items_stmt->execute($order_id);
    my @items;
    while (my $item = $items_stmt->fetchrow_hashref) {
        push @items, $item;
    }
    
    $c->render(template => 'order_detail', order => $order, items => \@items);
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
        users => $user_count
    );
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
    my $stock = $c->param('stock');
    my $category = $c->param('category');
    my $sku = $c->param('sku');
    
    $db->do(q{
        INSERT INTO products (name, description, price, stock, category, sku)
        VALUES (?, ?, ?, ?, ?, ?)
    }, undef, $name, $description, $price, $stock, $category, $sku);
    
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
    my $stock = $c->param('stock');
    my $category = $c->param('category');
    
    $db->do(q{
        UPDATE products 
        SET name = ?, description = ?, price = ?, stock = ?, category = ?
        WHERE id = ?
    }, undef, $name, $description, $price, $stock, $category, $id);
    
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

# Update order status
post '/admin/order/:id/status' => sub ($c) {
    $c->require_admin or return;
    
    my $id = $c->param('id');
    my $status = $c->param('status');
    
    $db->do('UPDATE orders SET status = ? WHERE id = ?', undef, $status, $id);
    
    $c->render(json => {success => 1});
};

app->secrets(['vgag-suite-secret-key']);
app->start;
