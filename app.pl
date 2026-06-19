#!/usr/bin/perl
use strict;
use warnings;
use Mojolicious::Lite -signatures;
use DBI;
use DBD::SQLite;
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use DateTime;

=head1 NAME

app.pl - Perl-based Ecommerce Web Application

=head1 DESCRIPTION

A complete ecommerce platform built with Mojolicious framework featuring:
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
            payment_method TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
        )
    });

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

# Shopping Cart Routes

# View cart
get '/cart' => sub ($c) {
    return $c->require_auth or return;
    
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
    return $c->require_auth or return;
    
    my $user = $c->get_session_user;
    my $product_id = $c->param('product_id');
    my $quantity = $c->param('quantity') || 1;
    
    # Check if product exists
    my $p_stmt = $db->prepare('SELECT id FROM products WHERE id = ?');
    $p_stmt->execute($product_id);
    return $c->render(json => {error => 'Product not found'}, status => 404) unless $p_stmt->fetchrow;
    
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
    
    $c->render(json => {success => 1});
};

# Remove from cart
post '/cart/remove/:id' => sub ($c) {
    return $c->require_auth or return;
    
    my $user = $c->get_session_user;
    my $item_id = $c->param('id');
    
    $db->do('DELETE FROM cart_items WHERE id = ? AND user_id = ?', undef, $item_id, $user->{id});
    
    $c->render(json => {success => 1});
};

# Checkout
post '/checkout' => sub ($c) {
    return $c->require_auth or return;
    
    my $user = $c->get_session_user;
    my $shipping_address = $c->param('shipping_address');
    my $payment_method = $c->param('payment_method');
    
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
    
    # Create order
    my $order_stmt = $db->prepare(q{
        INSERT INTO orders (user_id, total_price, shipping_address, payment_method, status)
        VALUES (?, ?, ?, ?, 'pending')
    });
    $order_stmt->execute($user->{id}, $total, $shipping_address, $payment_method);
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
        $db->do(q{
            INSERT INTO order_items (order_id, product_id, quantity, price)
            VALUES (?, ?, ?, ?)
        }, undef, $order_id, $item->{product_id}, $item->{quantity}, $item->{price});
    }
    
    # Clear cart
    $db->do('DELETE FROM cart_items WHERE user_id = ?', undef, $user->{id});
    
    $c->redirect_to("/order/$order_id");
};

# View order
get '/order/:id' => sub ($c) {
    return $c->require_auth or return;
    
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
    return $c->require_admin or return;
    
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
    return $c->require_admin or return;
    
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
    return $c->require_admin or return;
    $c->render(template => 'admin_product_form');
};

# Add product
post '/admin/product' => sub ($c) {
    return $c->require_admin or return;
    
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
    return $c->require_admin or return;
    
    my $id = $c->param('id');
    my $stmt = $db->prepare('SELECT * FROM products WHERE id = ?');
    $stmt->execute($id);
    my $product = $stmt->fetchrow_hashref;
    
    $c->render(template => 'admin_product_form', product => $product);
};

# Update product
post '/admin/product/:id' => sub ($c) {
    return $c->require_admin or return;
    
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
    return $c->require_admin or return;
    
    my $id = $c->param('id');
    $db->do('DELETE FROM products WHERE id = ?', undef, $id);
    
    $c->render(json => {success => 1});
};

# Manage orders
get '/admin/orders' => sub ($c) {
    return $c->require_admin or return;
    
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
    return $c->require_admin or return;
    
    my $id = $c->param('id');
    my $status = $c->param('status');
    
    $db->do('UPDATE orders SET status = ? WHERE id = ?', undef, $status, $id);
    
    $c->render(json => {success => 1});
};

app->secrets(['perl-ecommerce-secret-key']);
app->start;
