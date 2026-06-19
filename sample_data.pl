#!/usr/bin/perl
use strict;
use warnings;
use DBI;

my $db = DBI->connect('dbi:SQLite:ecommerce.db', '', '', {
    RaiseError => 1,
    AutoCommit => 1
}) or die "Cannot connect to database: $DBI::errstr";

my $insert = $db->prepare(q{
    INSERT INTO products (name, description, price, stock, category, sku)
    VALUES (?, ?, ?, ?, ?, ?)
});

print "Adding sample products...\n";

# Electronics
eval {
    $insert->execute('Laptop Pro', 'High performance laptop with 16GB RAM and 512GB SSD', 1299.99, 10, 'Electronics', 'LAP001');
    print "✓ Added Laptop Pro\n";
};
if ($@) { warn "Duplicate or error: $@" }

eval {
    $insert->execute('Wireless Mouse', 'Ergonomic wireless mouse with 2.4GHz connection', 49.99, 50, 'Accessories', 'MOU001');
    print "✓ Added Wireless Mouse\n";
};
if ($@) { warn "Duplicate or error: $@" }

eval {
    $insert->execute('Mechanical Keyboard', 'RGB mechanical keyboard with Cherry MX switches', 129.99, 30, 'Accessories', 'KEY001');
    print "✓ Added Mechanical Keyboard\n";
};
if ($@) { warn "Duplicate or error: $@" }

eval {
    $insert->execute('4K Monitor', '27 inch 4K UHD monitor with HDR support', 499.99, 15, 'Electronics', 'MON001');
    print "✓ Added 4K Monitor\n";
};
if ($@) { warn "Duplicate or error: $@" }

eval {
    $insert->execute('USB-C Hub', '7-in-1 USB-C hub with HDMI and USB 3.0', 79.99, 25, 'Accessories', 'HUB001');
    print "✓ Added USB-C Hub\n";
};
if ($@) { warn "Duplicate or error: $@" }

# Clothing
eval {
    $insert->execute('Cotton T-Shirt', 'Comfortable 100% cotton t-shirt', 24.99, 100, 'Clothing', 'TSH001');
    print "✓ Added Cotton T-Shirt\n";
};
if ($@) { warn "Duplicate or error: $@" }

eval {
    $insert->execute('Denim Jeans', 'Blue denim jeans with classic fit', 59.99, 75, 'Clothing', 'JEN001');
    print "✓ Added Denim Jeans\n";
};
if ($@) { warn "Duplicate or error: $@" }

eval {
    $insert->execute('Running Shoes', 'Comfortable running shoes with cushioning', 99.99, 40, 'Clothing', 'SHO001');
    print "✓ Added Running Shoes\n";
};
if ($@) { warn "Duplicate or error: $@" }

# Books
eval {
    $insert->execute('Perl Programming', 'Learn Perl programming from basics to advanced', 39.99, 20, 'Books', 'BK001');
    print "✓ Added Perl Programming\n";
};
if ($@) { warn "Duplicate or error: $@" }

eval {
    $insert->execute('Web Development Guide', 'Complete guide to web development', 49.99, 25, 'Books', 'BK002');
    print "✓ Added Web Development Guide\n";
};
if ($@) { warn "Duplicate or error: $@" }

print "\nSample data added successfully!\n";
